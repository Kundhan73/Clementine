import Foundation

/// What a job does.
public enum JobOperation: Hashable, Sendable {
    case convert(Format)
    case tool(Tool)
}

/// A request to run one operation on one or more inputs.
public struct JobRequest: Sendable {
    public var inputs: [InputItem]
    public var operation: JobOperation
    public var options: ToolOptions
    /// Overrides the planner's folder (e.g. file promises go to Downloads).
    public var outputDirectory: URL?

    public init(inputs: [InputItem], operation: JobOperation, options: ToolOptions = .none, outputDirectory: URL? = nil) {
        self.inputs = inputs
        self.operation = operation
        self.options = options
        self.outputDirectory = outputDirectory
    }

    /// Short human title: "photo.heic → JPG", "3 files → Merge PDF".
    public var title: String {
        let name = inputs.count == 1 ? (inputs.first?.url.lastPathComponent ?? "") : "\(inputs.count) files"
        switch operation {
        case .convert(let f): return "\(name) → \(f.displayName)"
        case .tool(let t): return "\(name) · \(t.displayName)"
        }
    }
}

/// The result of a finished job.
public struct JobResult: Sendable {
    /// Files or folders written.
    public var outputs: [URL]
    /// Extra note for the HUD ("Saved in Downloads: the folder is read-only").
    public var note: String?
    /// Text result (Read QR).
    public var text: String?

    public init(outputs: [URL] = [], note: String? = nil, text: String? = nil) {
        self.outputs = outputs
        self.note = note
        self.text = text
    }
}

/// A failure explained in plain words, with technical details on request.
public struct JobFailure: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var details: String?

    public init(_ message: String, details: String? = nil) {
        self.message = message
        self.details = details
    }

    public var description: String { details.map { "\(message)\n\($0)" } ?? message }

    /// Turns any error into a readable sentence.
    public static func from(_ error: Error) -> JobFailure {
        if let f = error as? JobFailure { return f }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: ns.code) {
            case .fileReadNoSuchFile, .fileNoSuchFile:
                return JobFailure("The file was moved or deleted.", details: ns.localizedDescription)
            case .fileWriteNoPermission, .fileReadNoPermission:
                return JobFailure("Clementine isn't allowed to use that folder.", details: ns.localizedDescription)
            case .fileWriteOutOfSpace:
                return JobFailure("The disk is full.", details: ns.localizedDescription)
            case .fileWriteVolumeReadOnly:
                return JobFailure("The disk is read-only.", details: ns.localizedDescription)
            default: break
            }
        }
        return JobFailure("Something went wrong.", details: "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }
}

/// One unit of work in the queue. Thread-safe.
public final class Job: Identifiable, @unchecked Sendable {
    public enum State: Sendable {
        case queued
        case running
        case succeeded(JobResult)
        case failed(JobFailure)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .queued, .running: return false
            default: return true
            }
        }
    }

    public let id = UUID()
    public let request: JobRequest
    /// 0…1 progress; engines update it, the HUD observes it.
    public let progress: Progress

    private let lock = NSLock()
    private var _state: State = .queued
    private var _task: Task<Void, Never>?
    private var _cancelRequested = false
    private var _detail: String?

    public init(_ request: JobRequest) {
        self.request = request
        progress = Progress(totalUnitCount: 1000)
    }

    public var title: String { request.title }

    public var state: State { sync { _state } }

    public var isCancelled: Bool { sync { _cancelRequested } }

    /// Free-form status line ("Pass 2 of 2", "Page 3 of 10").
    public var detail: String? { sync { _detail } }

    public func setDetail(_ text: String?) { sync { _detail = text } }

    /// Sets progress (0…1). Cheap; call as often as convenient.
    public func report(_ fraction: Double) {
        let units = Int64(max(0, min(1, fraction)) * 1000)
        if units != progress.completedUnitCount { progress.completedUnitCount = units }
    }

    /// Requests cancellation. Returns true if the job was still queued (and is
    /// now cancelled without having run).
    @discardableResult
    public func cancel() -> Bool {
        let (task, wasQueued): (Task<Void, Never>?, Bool) = sync {
            _cancelRequested = true
            if case .queued = _state {
                _state = .cancelled
                return (nil, true)
            }
            return (_task, false)
        }
        task?.cancel()
        return wasQueued
    }

    // MARK: Queue-internal

    func markRunning() -> Bool {
        sync {
            guard !_cancelRequested, case .queued = _state else { return false }
            _state = .running
            return true
        }
    }

    func attach(task: Task<Void, Never>) {
        let cancelNow: Bool = sync {
            _task = task
            return _cancelRequested
        }
        if cancelNow { task.cancel() }
    }

    func finish(_ state: State) {
        sync {
            _state = state
            _task = nil
        }
        if case .succeeded = state { report(1) }
    }

    @inline(__always)
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
