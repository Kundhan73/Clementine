import Foundation
#if canImport(Compression)
import Compression
#endif

/// Creates, extracts and repacks archives with the system's ditto, bsdtar,
/// gzip and bzip2 (plus Apple's Compression for .xz).
public enum ArchiveEngine {
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")
    static let bzip2 = URL(fileURLWithPath: "/usr/bin/bzip2")

    /// Sanity limits for extraction (zip bombs).
    public static let maxUnpackedBytes: Int64 = 10 * 1024 * 1024 * 1024
    public static let maxEntries = 200_000

    // MARK: Create

    /// Archives `items` into `archive` (which may already exist as an empty
    /// placeholder). ZIPs never contain AppleDouble/`__MACOSX` entries.
    public static func create(_ items: [URL], as format: Format, at archive: URL) async throws {
        guard !items.isEmpty else { throw JobFailure("There's nothing to archive.") }
        try? FileManager.default.removeItem(at: archive)
        switch format {
        case .zip where items.count == 1:
            try await ProcessRunner.check(ditto, ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent",
                                                 items[0].path, archive.path],
                                          failure: "Couldn't create the ZIP archive.")
        case .zip, .tar, .tgz:
            var args = ["--no-mac-metadata", "--no-xattrs", "--no-fflags"]
            switch format {
            case .zip: args += ["--format", "zip", "-cf"]
            case .tgz: args += ["-czf"]
            default: args += ["-cf"]
            }
            args.append(archive.path)
            for item in items {
                args += ["-C", item.deletingLastPathComponent().path, item.lastPathComponent]
            }
            try await ProcessRunner.check(bsdtar, args, failure: "Couldn't create the \(format.displayName) archive.")
        case .gz:
            guard items.count == 1 else { throw JobFailure("GZIP holds a single file. Use ZIP or TAR.GZ for several.") }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: items[0].path, isDirectory: &isDir), isDir.boolValue {
                throw JobFailure("GZIP holds a single file. Use ZIP or TAR.GZ for folders.")
            }
            let result = try await ProcessRunner.run(gzip, ["-c", "-n", "-6", items[0].path], stdoutFile: archive)
            guard result.status == 0 else {
                throw JobFailure("Couldn't create the GZIP file.", details: ProcessRunner.tail(result.stderrString))
            }
        default:
            throw JobFailure("\(format.displayName) archives can't be created.")
        }
    }

    // MARK: Extract

    /// Extracts `archive` into the (empty) folder `dir`.
    public static func extract(_ archive: URL, format: Format, into dir: URL) async throws {
        let listing = try await ProcessRunner.run(bsdtar, ["-tvf", archive.path])
        if listing.status == 0 {
            let (entries, bytes) = Self.parseListing(listing.stdoutString)
            if entries > maxEntries {
                throw JobFailure("This archive has too many files (\(entries)) to extract safely.")
            }
            if bytes > maxUnpackedBytes {
                throw JobFailure("This archive would unpack to \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)), more than Clementine extracts at once.")
            }
            let result = try await ProcessRunner.run(bsdtar, ["-x", "-f", archive.path, "-C", dir.path, "--no-same-owner"])
            guard result.status == 0 else {
                let details = ProcessRunner.tail(result.stderrString)
                if details.lowercased().contains("passphrase") || details.lowercased().contains("encrypt") {
                    throw JobFailure("This archive is password-protected.", details: details)
                }
                throw JobFailure("Couldn't extract the archive. It may be damaged.", details: details)
            }
            sanitize(dir)
            return
        }
        // Not a container: a single compressed file.
        let name = singleFileName(for: archive)
        let out = dir.appendingPathComponent(name)
        switch format {
        case .gz:
            try await decompress(gzip, archive, to: out)
        case .bz2:
            try await decompress(bzip2, archive, to: out)
        case .xz:
            try decompressXZ(archive, to: out)
        default:
            throw JobFailure("This archive can't be opened. It may be damaged or in an unsupported format.",
                             details: ProcessRunner.tail(listing.stderrString))
        }
    }

    /// Repacks an archive into another format (e.g. RAR → ZIP).
    public static func repack(_ archive: URL, format: Format, as target: Format, at output: URL) async throws {
        let tmp = try TempDirectory(prefix: "clementine-repack")
        defer { tmp.remove() }
        try await extract(archive, format: format, into: tmp.url)
        let items = try FileManager.default.contentsOfDirectory(at: tmp.url, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !items.isEmpty else { throw JobFailure("The archive is empty.") }
        try await create(items, as: target, at: output)
    }

    /// Entry count and total size from `bsdtar -tv` output.
    public static func parseListing(_ text: String) -> (entries: Int, bytes: Int64) {
        var entries = 0
        var bytes: Int64 = 0
        for line in text.split(separator: "\n") where !line.isEmpty {
            entries += 1
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count > 4, let size = Int64(fields[4]) { bytes += size }
        }
        return (entries, bytes)
    }

    /// "notes.txt.gz" → "notes.txt"; "data.gz" → "data".
    static func singleFileName(for archive: URL) -> String {
        let name = archive.lastPathComponent
        let lower = name.lowercased()
        for ext in [".gz", ".gzip", ".bz2", ".xz"] where lower.hasSuffix(ext) && name.count > ext.count {
            return String(name.dropLast(ext.count))
        }
        return name + ".out"
    }

    private static func decompress(_ tool: URL, _ archive: URL, to out: URL) async throws {
        let result = try await ProcessRunner.run(tool, ["-dc", archive.path], stdoutFile: out)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: out)
            throw JobFailure("Couldn't decompress the file. It may be damaged.", details: ProcessRunner.tail(result.stderrString))
        }
    }

    static func decompressXZ(_ archive: URL, to out: URL) throws {
        #if canImport(Compression)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        _ = FileManager.default.createFile(atPath: out.path, contents: nil)
        let output = try FileHandle(forWritingTo: out)
        defer { try? output.close() }
        var written: Int64 = 0
        let filter = try OutputFilter(.decompress, using: .lzma) { data in
            guard let data else { return }
            written += Int64(data.count)
            if written > maxUnpackedBytes { throw JobFailure("The file would unpack to more than Clementine extracts at once.") }
            try output.write(contentsOf: data)
        }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try filter.write(chunk)
        }
        try filter.finalize()
        #else
        throw JobFailure(".xz files can't be opened on this system.")
        #endif
    }

    /// Removes Finder junk and symlinks that point outside the folder.
    static func sanitize(_ dir: URL) {
        let fm = FileManager.default
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        var remove: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == "__MACOSX" || name.hasPrefix("._") {
                remove.append(url)
                if name == "__MACOSX" { walker.skipDescendants() }
                continue
            }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                let target = url.resolvingSymlinksInPath().standardizedFileURL.path
                if !(target == root || target.hasPrefix(root + "/")) { remove.append(url) }
            }
        }
        for url in remove { try? fm.removeItem(at: url) }
    }
}
