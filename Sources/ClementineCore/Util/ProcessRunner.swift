import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    /// The last ~64 KB of stderr.
    public var stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs helper processes (ffmpeg, ditto, bsdtar…) without blocking threads,
/// streaming stdout lines to a callback and terminating on task cancellation.
public enum ProcessRunner {
    public static func run(_ executable: URL, _ arguments: [String],
                           currentDirectory: URL? = nil,
                           environment: [String: String]? = nil,
                           onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collector = OutputCollector(onLine: onStdoutLine)
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendOut(data) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendErr(data) }
        }
        let exit = ExitWaiter()
        process.terminationHandler = { _ in exit.signal() }

        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            throw JobFailure("A helper program couldn't be started.",
                             details: "\(executable.path): \(error.localizedDescription)")
        }
        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            process.terminate()
        }
        // Drain whatever is left in the pipes.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if let rest = try? out.fileHandleForReading.readToEnd() { collector.appendOut(rest) }
        if let rest = try? err.fileHandleForReading.readToEnd() { collector.appendErr(rest) }
        collector.flush()
        if Task.isCancelled { throw CancellationError() }
        return ProcessResult(status: process.terminationStatus, stdout: collector.stdout, stderr: collector.stderr)
    }

    /// Runs a tool and throws a readable failure if it exits non-zero.
    @discardableResult
    public static func check(_ executable: URL, _ arguments: [String], failure: String,
                             currentDirectory: URL? = nil) async throws -> ProcessResult {
        let result = try await run(executable, arguments, currentDirectory: currentDirectory)
        guard result.status == 0 else {
            throw JobFailure(failure, details: tail(result.stderrString.isEmpty ? result.stdoutString : result.stderrString))
        }
        return result
    }

    /// Last lines of a log, for error details.
    public static func tail(_ text: String, lines: Int = 25) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}

/// Collects process output (thread-safe) and splits stdout into lines.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var partialLine = Data()
    private let onLine: (@Sendable (String) -> Void)?
    private static let errLimit = 64 * 1024

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func appendOut(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        out.append(data)
        if onLine != nil {
            partialLine.append(data)
            while let nl = partialLine.firstIndex(of: 0x0A) {
                lines.append(String(decoding: partialLine[partialLine.startIndex..<nl], as: UTF8.self))
                partialLine.removeSubrange(partialLine.startIndex...nl)
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func appendErr(_ data: Data) {
        lock.lock()
        err.append(data)
        if err.count > Self.errLimit * 2 { err = Data(err.suffix(Self.errLimit)) }
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let last = partialLine.isEmpty ? nil : String(decoding: partialLine, as: UTF8.self)
        partialLine.removeAll()
        lock.unlock()
        if let last { onLine?(last) }
    }

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return Data(err.suffix(Self.errLimit)) }
}

/// One-shot signal that can be awaited before or after it fires.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        fired = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}
