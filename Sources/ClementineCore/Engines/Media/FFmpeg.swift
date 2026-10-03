import Foundation

/// Finds the ffmpeg/ffprobe helpers: Settings override → bundled
/// `Contents/Helpers` → `CLEMENTINE_FFMPEG`/`CLEMENTINE_FFPROBE` (tests).
public enum FFmpegLocator {
    /// Folder containing a user-chosen ffmpeg (Settings → Advanced).
    nonisolated(unsafe) public static var overrideDirectory: URL?

    public static var ffmpeg: URL? { locate("ffmpeg", env: "CLEMENTINE_FFMPEG") }
    public static var ffprobe: URL? { locate("ffprobe", env: "CLEMENTINE_FFPROBE") }
    public static var isAvailable: Bool { ffmpeg != nil && ffprobe != nil }

    private static func locate(_ name: String, env: String) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let dir = overrideDirectory { candidates.append(dir.appendingPathComponent(name)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"))
        if let path = ProcessInfo.processInfo.environment[env], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}

/// Runs ffmpeg with progress reporting.
public enum FFmpegRunner {
    /// Runs `ffmpeg <arguments>` (global flags and progress output are added).
    /// - Parameters:
    ///   - duration: input duration in seconds, for progress.
    ///   - progress: receives 0…1 as encoding advances.
    public static func run(_ arguments: [String], duration: Double?, failure: String = "The conversion failed.",
                           progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let ffmpeg = FFmpegLocator.ffmpeg else {
            throw JobFailure("The audio/video converter (ffmpeg) is missing from this copy of Clementine.")
        }
        let args = ["-nostdin", "-hide_banner", "-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1"] + arguments
        let total = (duration ?? 0) > 0 ? duration! : nil
        let result = try await ProcessRunner.run(ffmpeg, args) { line in
            guard let progress, let total else { return }
            if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                // Both keys are in microseconds (a long-standing ffmpeg quirk).
                if let us = Double(line.split(separator: "=").last ?? "") , us > 0 {
                    progress(min(1, us / 1_000_000 / total))
                }
            } else if line == "progress=end" {
                progress(1)
            }
        }
        guard result.status == 0 else {
            throw JobFailure(failure, details: ProcessRunner.tail(result.stderrString))
        }
    }
}
