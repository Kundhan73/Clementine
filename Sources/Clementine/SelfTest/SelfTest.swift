import AppKit
import ClementineCore
import Darwin

/// `--self-test`: launches normally (status item, drag monitor), waits until
/// idle, reports the physical memory footprint, runs one real conversion
/// through the job queue, reports again and exits non-zero on failure or if
/// the idle footprint is over budget. CI runs this against the bundled app.
@MainActor
enum SelfTest {
    static let idleBudgetMB = 40.0
    static let afterJobBudgetMB = 150.0

    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { runChecks() }
        }
    }

    private static func runChecks() {
        let idle = Footprint.megabytes()
        print(String(format: "selftest: idle_footprint_mb=%.1f budget_mb=%.0f", idle, idleBudgetMB))
        print("selftest: ffmpeg=\(FFmpegLocator.ffmpeg?.path ?? "missing")")
        Task { @MainActor in
            var ok = idle > 0 && idle <= idleBudgetMB
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
