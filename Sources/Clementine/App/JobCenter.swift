import AppKit
import ClementineCore

/// Builds `Engines` with the current settings for every job, so changes in
/// Settings apply to the next job without restarting.
struct LiveEngines: JobExecuting {
    func execute(_ job: Job) async throws -> JobResult {
        let engines = Engines(settings: Preferences.conversionSettings(), planner: Preferences.outputPlanner())
        return try await engines.execute(job)
    }
}

/// Turns wheel picks into jobs, runs them through the queue and reflects
/// their state in the HUD, Recent menu, sounds and result panels.
@MainActor
final class JobCenter {
    static let shared = JobCenter()

    let hud = HUDController()
    private var queue: JobQueue?
    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var active = Set<UUID>()
    private var activity: NSObjectProtocol?
    private var batchFailed = false

    private func ensureQueue() -> JobQueue {
        if let queue { return queue }
        let limits = JobQueue.defaultLimits(mediaJobs: Preferences.conversionSettings().maxConcurrentMediaJobs)
        let queue = JobQueue(executor: LiveEngines(), limits: limits) { job in
            Task { @MainActor in JobCenter.shared.jobChanged(job) }
        }
        self.queue = queue
        return queue
    }

    /// Runs `chip` for the dragged/chosen files.
    func run(_ chip: WheelChip, items: [InputItem], promises: [NSFilePromiseReceiver] = []) {
        if !promises.isEmpty {
            PromiseReceiver.receive(promises) { [weak self] urls, error in
                guard let self else { return }
                if urls.isEmpty {
                    self.showFailure("The dragged items couldn't be received.", details: error?.localizedDescription)
                    return
                }
                let downloads = Preferences.outputPlanner().downloads
                self.submit(Self.requests(for: chip, items: urls.map(InputItem.inspect), outputDirectory: downloads))
            }
            return
        }
        if case .tool(let tool) = chip, tool.interaction != .instant, ToolUI.handles(tool) {
            ToolUI.open(tool, items: items)
            return
        }
        submit(Self.requests(for: chip, items: items, outputDirectory: nil))
    }

    func submit(_ requests: [JobRequest]) {
        let queue = ensureQueue()
        for request in requests {
            let job = Job(request)
            active.insert(job.id)
            beginActivityIfNeeded()
            hud.update(job)
            Task { await queue.submit(job) }
        }
    }

    /// One job per file, except archives of several files and multi-input tools.
    static func requests(for chip: WheelChip, items: [InputItem], outputDirectory: URL?,
                         options: ToolOptions = .none) -> [JobRequest] {
        switch chip {
        case .format(let target):
            if items.count > 1, target.kind == .archive, target != .extract {
                return [JobRequest(inputs: items, operation: .convert(target), outputDirectory: outputDirectory)]
            }
            return items.map { JobRequest(inputs: [$0], operation: .convert(target), outputDirectory: outputDirectory) }
        case .tool(let tool):
            if [.collage, .createPDF, .mergePDF, .join].contains(tool) {
                return [JobRequest(inputs: items, operation: .tool(tool), options: options, outputDirectory: outputDirectory)]
            }
            return items.map { JobRequest(inputs: [$0], operation: .tool(tool), options: options, outputDirectory: outputDirectory) }
        }
    }

    // MARK: Job events

    func jobChanged(_ job: Job) {
        switch job.state {
        case .queued:
            hud.update(job)
        case .running:
            hud.update(job)
            observeProgress(job)
            JobNotifications.shared.jobStarted(job)
        case .succeeded(let result):
            finish(job)
            hud.update(job)
            JobNotifications.shared.jobFinished(job, outputs: result.outputs, failure: nil)
            if !result.outputs.isEmpty {
                Preferences.addRecent(result.outputs)
                if Preferences.revealInFinder { NSWorkspace.shared.activateFileViewerSelecting(result.outputs) }
            }
            if let text = result.text {
                TextResultPanel.show(title: "Read QR", text: text)
            }
        case .failed(let failure):
            batchFailed = true
            finish(job)
            hud.update(job)
            JobNotifications.shared.jobFinished(job, outputs: [], failure: failure.message)
        case .cancelled:
            finish(job)
            hud.update(job)
            JobNotifications.shared.forget(job)
        }
    }

    private func observeProgress(_ job: Job) {
        guard observations[job.id] == nil else { return }
        let id = job.id
        observations[id] = job.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated { JobCenter.shared.hud.setProgress(fraction, for: id) }
            }
        }
    }

    private func finish(_ job: Job) {
        observations.removeValue(forKey: job.id)?.invalidate()
        guard active.remove(job.id) != nil else { return }
        if active.isEmpty {
            if Preferences.completionSound && !batchFailed {
                let sound = NSSound(named: NSSound.Name("Pop"))
                sound?.volume = 0.35
                sound?.play()
            }
            batchFailed = false
            endActivity()
        }
    }

    private func beginActivityIfNeeded() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Converting files")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func showFailure(_ message: String, details: String?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details ?? ""
        NSApp.activate()
        alert.runModal()
    }
}

/// Receives file promises (Photos, Mail…) into a private folder.
@MainActor
enum PromiseReceiver {
    static let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        q.name = "Clementine.promises"
        return q
    }()

    static func receive(_ receivers: [NSFilePromiseReceiver], completion: @escaping @MainActor ([URL], Error?) -> Void) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clementine/Promises/\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            completion([], error)
            return
        }
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileTypes.count) }
        let collector = PromiseCollector(expected: expected) { urls, error in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(urls, error) } }
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: base, options: [:], operationQueue: queue) { url, error in
                collector.add(error == nil ? url : nil, error: error)
            }
        }
    }

    /// Deletes received promise folders from previous launches.
    static func cleanUp() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clementine/Promises", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}

private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private var lastError: Error?
    private let done: ([URL], Error?) -> Void

    init(expected: Int, done: @escaping ([URL], Error?) -> Void) {
        remaining = expected
        self.done = done
    }

    func add(_ url: URL?, error: Error?) {
        lock.lock()
        if let url { urls.append(url) }
        if let error { lastError = error }
        remaining -= 1
        let finished = remaining == 0
        let result = (urls, lastError)
        lock.unlock()
        if finished { done(result.0, result.1) }
    }
}
