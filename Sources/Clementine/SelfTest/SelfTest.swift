import AppKit
import ClementineCore
import Darwin

/// `--self-test`: launches normally (status item, drag monitor), waits until
/// idle, measures CPU use over 5 idle seconds and the physical memory
/// footprint, runs one real conversion through the job queue, measures again
/// and exits non-zero on failure or if anything is over budget (SPEC §5:
/// 0 % CPU and ≤ 35 MB when idle). CI runs this against the bundled app.
@MainActor
enum SelfTest {
    static let idleBudgetMB = 35.0
    static let idleCPUBudgetPercent = 1.0
    static let afterJobBudgetMB = 150.0

    /// Settle after launch, then measure an idle window this long.
    static let settleSeconds = 6.0, windowSeconds = 10.0

    /// Main run loop wake-ups (diagnostics).
    nonisolated(unsafe) private static var mainWakeups = 0
    nonisolated(unsafe) private static var eventCounts: [UInt: Int] = [:]
    nonisolated(unsafe) private static var phaseResults: [String] = []
    nonisolated(unsafe) private static var extraMonitor: Any?

    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) {
            MainActor.assumeIsolated { measureIdle() }
        }
    }

    /// Idle window in phases: the real drag monitor; no monitor; a
    /// mouse-down-only monitor; and a catch-all monitor that counts which
    /// events arrive at all. Then the normal checks.
    private static func measureIdle() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in
            SelfTest.mainWakeups += 1
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let cpu = cpuSeconds(), wakeups = Footprint.wakeups()
        let phase = windowSeconds / 4
        let monitor = AppDelegate.shared?.dragMonitor
        let wasRunning = monitor?.isRunning ?? false
        phaseResults = []
        func next(_ label: String, then: @escaping @MainActor () -> Void) {
            mainWakeups = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + phase) {
                MainActor.assumeIsolated {
                    SelfTest.phaseResults.append(String(format: "%@ %.1f", label, Double(SelfTest.mainWakeups) / phase))
                    then()
                }
            }
        }
        next("drag monitor") {
            monitor?.stop()
            next("none") {
                extraMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in }
                next("mouse-down only") {
                    if let m = extraMonitor { NSEvent.removeMonitor(m) }
                    extraMonitor = NSEvent.addGlobalMonitorForEvents(matching: .any) { event in
                        let type = event.type.rawValue
                        MainActor.assumeIsolated { SelfTest.eventCounts[type, default: 0] += 1 }
                    }
                    next("catch-all") {
                        if let m = extraMonitor { NSEvent.removeMonitor(m) }
                        extraMonitor = nil
                        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                        if wasRunning { monitor?.start() }
                        let types = eventCounts.sorted { $0.value > $1.value }.prefix(6)
                            .map { "type \($0.key)×\($0.value)" }.joined(separator: ", ")
                        print("::notice title=Idle diagnostics::main run loop wakeups/s: \(phaseResults.joined(separator: " · ")); " +
                              "events seen: \(types.isEmpty ? "none" : types)")
                        let perSecond = Double(Footprint.wakeups() - wakeups) / windowSeconds
                        runChecks(idleCPU: (cpuSeconds() - cpu) / windowSeconds * 100, wakeups: perSecond)
                    }
                }
            }
        }
    }

    /// User + system CPU time this process has used, in seconds.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 +
            Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    private static func runChecks(idleCPU: Double, wakeups: Double) {
        let idle = Footprint.megabytes()
        print(String(format: "selftest: idle_cpu_percent=%.2f budget=%.1f", idleCPU, idleCPUBudgetPercent))
        print(String(format: "selftest: idle_footprint_mb=%.1f budget_mb=%.0f", idle, idleBudgetMB))
        print("selftest: ffmpeg=\(FFmpegLocator.ffmpeg?.path ?? "missing")")
        Task { @MainActor in
            var ok = idle > 0 && idle <= idleBudgetMB && idleCPU <= idleCPUBudgetPercent
            do {
                let output = try await convertSample()
                print("selftest: converted \(output.lastPathComponent)")
            } catch {
                print("selftest: conversion FAILED: \(error)")
                ok = false
            }
            // Let the queue and HUD settle, then measure again.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let after = Footprint.megabytes()
            print(String(format: "selftest: after_job_footprint_mb=%.1f budget_mb=%.0f", after, afterJobBudgetMB))
            if after > afterJobBudgetMB { ok = false }
            print(String(format: "::notice title=Self-test::idle %.1f MB, %.2f%% CPU, %.1f wakeups/s; after a conversion %.1f MB (%@)",
                         idle, idleCPU, wakeups, after, ok ? "PASS" : "FAIL"))
            print("selftest: \(ok ? "PASS" : "FAIL")")
            fflush(stdout)
            exit(ok ? 0 : 1)
        }
    }

    /// PNG → JPG through the same queue and engines the wheel uses.
    private static func convertSample() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("sample.png")
        let image = NSImage(size: NSSize(width: 640, height: 480), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw JobFailure("couldn't make the sample image")
        }
        try data.write(to: png)
        let job = Job(JobRequest(inputs: [InputItem.inspect(png)], operation: .convert(.jpg)))
        let done = AsyncStream<Void> { continuation in
            let queue = JobQueue(executor: LiveEngines()) { job in
                if job.state.isFinished { continuation.finish() }
            }
            Task { await queue.submit(job) }
            continuation.onTermination = { _ in _ = queue }
        }
        for await _ in done {}
        switch job.state {
        case .succeeded(let result):
            guard let out = result.outputs.first, FileManager.default.fileExists(atPath: out.path) else {
                throw JobFailure("no output written")
            }
            return out
        case .failed(let failure):
            throw failure
        default:
            throw JobFailure("job ended as \(job.state)")
        }
    }
}

enum Footprint {
    /// Interrupt + idle wakeups so far (timers and other sources of wakeups).
    static func wakeups() -> UInt64 {
        var info = task_power_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.task_interrupt_wakeups + info.task_platform_idle_wakeups : 0
    }

    /// Physical footprint (what Activity Monitor calls "Memory") in MB.
    static func megabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
