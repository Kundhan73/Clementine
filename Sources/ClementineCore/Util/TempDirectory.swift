import Foundation

/// A private temporary folder. Call `remove()` in a `defer` (that also keeps
/// the object alive for the whole scope); deinit cleans up as a backup.
public final class TempDirectory: @unchecked Sendable {
    public let url: URL

    public init(prefix: String = "clementine") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    public func remove() { try? FileManager.default.removeItem(at: url) }

    deinit { remove() }
}
