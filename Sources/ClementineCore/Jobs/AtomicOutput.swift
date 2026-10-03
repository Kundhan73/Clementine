import Foundation

/// A file or folder being written: work happens on a hidden temporary item in
/// the destination folder, which is renamed to a free Finder-style name on
/// success (never overwriting anything) and deleted on failure or cancel.
public final class AtomicOutput: @unchecked Sendable {
    public let directory: URL
    public let base: String
    public let suffix: String?
    public let fileExtension: String
    public let isDirectory: Bool
    /// Where the engine writes. Ends with the real extension so tools that pick
    /// a format from the name (ffmpeg) do the right thing.
    public let tempURL: URL
    /// The name the output will most likely get (for display while running).
    public var plannedURL: URL {
        OutputNamer.uniqueURL(in: directory, base: base, suffix: suffix, extension: fileExtension)
    }
    private let lock = NSLock()
    private var finished = false

    /// Reserves a temporary item in `directory`. Throws if the folder isn't
    /// writable (the planner then falls back to Downloads).
    public init(directory: URL, base: String, suffix: String? = nil, extension ext: String,
                isDirectory: Bool = false) throws {
        self.directory = directory
        self.base = base
        self.suffix = suffix
        self.fileExtension = ext
        self.isDirectory = isDirectory
        let token = String(UUID().uuidString.prefix(8))
        let safeBase = String(base.prefix(80))
        let tempName = ".\(safeBase).clementine-\(token)" + (ext.isEmpty || isDirectory ? "" : ".\(ext)")
        tempURL = directory.appendingPathComponent(tempName)
        if isDirectory {
            try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: false)
        } else {
            guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: directory.path])
            }
        }
    }

    /// Moves the finished item to its final, unused name and returns it.
    @discardableResult
    public func commit() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        precondition(!finished, "AtomicOutput committed twice")
        var attempts = 0
        while true {
            let target = OutputNamer.uniqueURL(in: directory, base: base, suffix: suffix, extension: fileExtension)
            do {
                try FileManager.default.moveItem(at: tempURL, to: target)
                finished = true
                return target
            } catch let error as CocoaError where error.code == .fileWriteFileExists && attempts < 50 {
                attempts += 1 // lost a race with another writer; pick the next name
            }
        }
    }

    /// Deletes the temporary item (safe to call more than once, and after commit).
    public func discard() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        try? FileManager.default.removeItem(at: tempURL)
    }

    deinit {
        if !finished { try? FileManager.default.removeItem(at: tempURL) }
    }
}

/// Where outputs go, per Settings → Output.
public enum OutputLocation: Codable, Hashable, Sendable {
    case besideOriginal
    case downloads
    case folder(URL)
}

/// Decides the destination folder for a job and creates its `AtomicOutput`,
/// falling back to ~/Downloads when the preferred folder isn't writable.
public struct OutputPlanner: Sendable {
    public var location: OutputLocation
    public var downloads: URL

    public init(location: OutputLocation = .besideOriginal,
                downloads: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")) {
        self.location = location
        self.downloads = downloads
    }

    public func preferredDirectory(for source: URL) -> URL {
        switch location {
        case .besideOriginal: return source.deletingLastPathComponent()
        case .downloads: return downloads
        case .folder(let url): return url
        }
    }

    /// Returns the output and whether it fell back to Downloads.
    public func makeOutput(for source: URL, base: String? = nil, suffix: String? = nil, extension ext: String,
                           isDirectory: Bool = false) throws -> (AtomicOutput, fellBack: Bool) {
        let base = base ?? OutputNamer.baseName(of: source)
        let preferred = preferredDirectory(for: source)
        do {
            return (try AtomicOutput(directory: preferred, base: base, suffix: suffix, extension: ext,
                                     isDirectory: isDirectory), false)
        } catch {
            guard preferred.standardizedFileURL != downloads.standardizedFileURL else { throw error }
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            return (try AtomicOutput(directory: downloads, base: base, suffix: suffix, extension: ext,
                                     isDirectory: isDirectory), true)
        }
    }
}
