import AppKit
import Darwin

/// `--self-test`: launches normally, waits until idle, reports the physical
/// memory footprint and exits non-zero if it exceeds the budget. CI runs this
/// against the bundled app.
@MainActor
enum SelfTest {
    static let idleBudgetMB = 40.0

    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let idle = Footprint.megabytes()
            print(String(format: "selftest: idle_footprint_mb=%.1f budget_mb=%.0f", idle, idleBudgetMB))
            let ok = idle > 0 && idle <= idleBudgetMB
            print("selftest: \(ok ? "PASS" : "FAIL")")
            fflush(stdout)
            exit(ok ? 0 : 1)
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
