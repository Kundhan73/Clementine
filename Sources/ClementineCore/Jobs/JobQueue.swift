import Foundation

/// Executes one job. Implemented by `Engines`; tests can inject fakes.
public protocol JobExecuting: Sendable {
    func execute(_ job: Job) async throws -> JobResult
}

/// Runs jobs in lanes with per-lane concurrency limits:
/// images ≤ min(cores-1, 4), media 1 (1–3), documents 2, archives 2.
public actor JobQueue {
    public enum Lane: String, CaseIterable, Sendable {
        case image, media, document, archive
    }

    public static func defaultLimits(mediaJobs: Int = 1) -> [Lane: Int] {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return [.image: max(1, min(cores - 1, 4)), .media: max(1, min(mediaJobs, 3)), .document: 2, .archive: 2]
    }

    private let executor: JobExecuting
    private let onChange: @Sendable (Job) -> Void
    private var limits: [Lane: Int]
    private var running: [Lane: Int] = [:]
    private var waiting: [Lane: [Job]] = [:]

    /// - Parameter onChange: called (on an arbitrary thread) whenever a job
    ///   starts or finishes.
    public init(executor: JobExecuting, limits: [Lane: Int] = JobQueue.defaultLimits(),
                onChange: @escaping @Sendable (Job) -> Void) {
        self.executor = executor
        self.limits = limits
        self.onChange = onChange
    }

    public func setLimit(_ limit: Int, for lane: Lane) {
        limits[lane] = max(1, limit)
        pump(lane)
    }

    /// Number of queued + running jobs.
    public var activeCount: Int {
        running.values.reduce(0, +) + waiting.values.reduce(0) { $0 + $1.count }
    }

    public func submit(_ job: Job) {
        let lane = Self.lane(for: job.request)
        waiting[lane, default: []].append(job)
        pump(lane)
    }

    private func pump(_ lane: Lane) {
        while running[lane, default: 0] < limits[lane, default: 1], var queue = waiting[lane], !queue.isEmpty {
            let job = queue.removeFirst()
            waiting[lane] = queue
            guard job.markRunning() else {
                onChange(job) // cancelled while queued
                continue
            }
            running[lane, default: 0] += 1
            onChange(job)
            let executor = self.executor
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                let state: Job.State
                do {
                    try Task.checkCancellation()
                    state = .succeeded(try await executor.execute(job))
                } catch is CancellationError {
                    state = .cancelled
                } catch {
                    state = job.isCancelled ? .cancelled : .failed(JobFailure.from(error))
                }
                await self?.finish(job, lane: lane, state: state)
            }
            job.attach(task: task)
        }
    }

    private func finish(_ job: Job, lane: Lane, state: Job.State) {
        running[lane, default: 1] -= 1
        job.finish(state)
        onChange(job)
        pump(lane)
    }

    /// Which lane a request runs in.
    public static func lane(for request: JobRequest) -> Lane {
        let first = request.inputs.first
        switch request.operation {
        case .convert(let target):
            switch ConversionMatrix.engine(from: first?.format, kind: first?.kind ?? .other, to: target) {
            case .image?, .imageToPDF?, .imageToSVG?, .imageToDOCX?: return .image
            case .media?: return .media
            case .archive?, .extract?: return .archive
            default: return .document
            }
        case .tool:
            switch first?.kind {
            case .image?: return .image
            case .audio?, .video?: return .media
            default: return .document
            }
        }
    }
}
