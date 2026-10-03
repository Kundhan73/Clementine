import Foundation

/// Creates and unpacks archives with the system's ditto, bsdtar and gzip.
public enum ArchiveEngine {
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")

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
        default:
            throw JobFailure("\(format.displayName) archives can't be created yet.")
        }
    }
}
