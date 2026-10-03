import Foundation

/// Audio and video conversions through the bundled ffmpeg.
public enum MediaEngine {
    /// Converts one file, trying the planner's attempts in order (stream
    /// copy first, then encoders).
    public static func convert(_ item: InputItem, to target: Format, output: URL, settings: ConversionSettings,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let info = try await MediaProbe.probe(item.url)
        progress(0.01)
        let attempts = try MediaPlanner.plan(source: item.format, info: info, target: target, settings: settings)
        try await run(attempts, input: item.url, output: output, duration: info.duration,
                      failure: "Couldn't convert \(item.url.lastPathComponent) to \(target.displayName).",
                      progress: progress)
    }

    /// Runs attempts until one produces a non-empty output.
    public static func run(_ attempts: [FFmpegAttempt], input: URL, output: URL, duration: Double?, failure: String,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        var lastError: Error = JobFailure(failure)
        for attempt in attempts {
            try Task.checkCancellation()
            do {
                let args = attempt.inputArgs + ["-i", ffmpegPath(input)] + attempt.outputArgs + [ffmpegPath(output)]
                try await FFmpegRunner.run(args, duration: duration, failure: failure, progress: progress)
                let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
                guard size > 0 else { throw JobFailure(failure, details: "ffmpeg wrote an empty file (\(attempt.label))") }
                return
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    /// Paths passed as `file:` URLs so names containing ":" aren't mistaken
    /// for protocols.
    public static func ffmpegPath(_ url: URL) -> String { "file:" + url.path }
}
