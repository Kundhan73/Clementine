import AppKit
import ClementineCore
import UserNotifications

/// Optional notification when a long job finishes (Settings → General, off by
/// default). Clicking it shows the file in Finder.
@MainActor
final class JobNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = JobNotifications()
    /// Jobs shorter than this only get the progress panel.
    static let minimumSeconds: TimeInterval = 20
    private var started: [UUID: Date] = [:]
    private var configured = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.notifyLongJobs) }

    /// Sets the delegate (only once notifications are wanted) and asks for
    /// permission when `ask` is true.
    func apply(ask: Bool = false) {
        guard Self.isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        if !configured {
            center.delegate = self
            configured = true
        }
        if ask { center.requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    func jobStarted(_ job: Job) {
        if started[job.id] == nil { started[job.id] = Date() }
    }

    func forget(_ job: Job) {
        started.removeValue(forKey: job.id)
    }

    func jobFinished(_ job: Job, outputs: [URL], failure: String?) {
        guard let start = started.removeValue(forKey: job.id), Self.isEnabled,
              Date().timeIntervalSince(start) >= Self.minimumSeconds else { return }
        apply()
        let content = UNMutableNotificationContent()
        let name = job.request.inputs.first?.url.lastPathComponent ?? "Your files"
        if let failure {
            content.title = "Couldn't finish \(name)"
            content.body = failure
        } else {
            content.title = outputs.first?.lastPathComponent ?? name
            content.body = outputs.count > 1 ? "\(outputs.count) files are ready." : "Ready."
            content.userInfo = ["paths": outputs.map(\.path)]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        DispatchQueue.main.async {
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
