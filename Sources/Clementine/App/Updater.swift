import AppKit
import ClementineCore

/// Manual update check against this repo's GitHub Releases (the app's only
/// network access). Downloads Clementine.zip, verifies it, swaps the bundle
/// and relaunches.
@MainActor
final class Updater {
    static let shared = Updater()
    private var busy = false
    /// System-scheduled daily check (only when enabled in Settings; no timer
    /// of ours runs while idle).
    private var scheduler: NSBackgroundActivityScheduler?

    func applySchedule() {
        scheduler?.invalidate()
        scheduler = nil
        guard UserDefaults.standard.bool(forKey: PrefKey.autoUpdateCheck) else { return }
        let activity = NSBackgroundActivityScheduler(identifier: "\(AppInfo.bundleIdentifier).update-check")
        activity.repeats = true
        activity.interval = 24 * 60 * 60
        activity.tolerance = 2 * 60 * 60
        activity.qualityOfService = .utility
        activity.schedule { completion in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Updater.shared.checkForUpdates(userInitiated: false) }
                completion(.finished)
            }
        }
        scheduler = activity
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True if `a` is a newer dotted version than `b` ("0.10.0" > "0.9.2").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func checkForUpdates(userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let release = try await fetchLatest()
                let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                guard Self.isNewer(latest, than: Self.currentVersion) else {
                    if userInitiated { inform("You're up to date.", "Clementine \(Self.currentVersion) is the latest version.") }
                    return
                }
                guard let asset = release.assets.first(where: { $0.name == "Clementine.zip" }) else {
                    if userInitiated { inform("No download found", "The latest release has no Clementine.zip.") }
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Clementine \(latest) is available"
                let notes = (release.body ?? "").split(separator: "\n").prefix(12).joined(separator: "\n")
                alert.informativeText = "You have \(Self.currentVersion).\n\n\(notes)"
                alert.addButton(withTitle: "Install and Relaunch")
                alert.addButton(withTitle: "Later")
                NSApp.activate()
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await install(from: asset.browser_download_url)
            } catch {
                if userInitiated {
                    inform("Couldn't check for updates", JobFailure.from(error).description)
                }
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Clementine/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw JobFailure("GitHub didn't return the latest release.")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private func install(from url: URL) async throws {
        let (zip, _) = try await URLSession.shared.download(from: url)
        let work = try TempDirectory(prefix: "clementine-update")
        defer { work.remove() }
        let zipURL = work.file("Clementine.zip")
        try FileManager.default.moveItem(at: zip, to: zipURL)
        try await ProcessRunner.check(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zipURL.path, work.url.path],
                                      failure: "The download couldn't be unpacked.")
        let newApp = work.file("Clementine.app")
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == AppInfo.bundleIdentifier else {
            throw JobFailure("The download isn't a Clementine app.")
        }
        try await ProcessRunner.check(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", newApp.path],
                                      failure: "The downloaded app's signature doesn't verify.")
        let current = Bundle.main.bundleURL
        _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
        let path = current.path.replacingOccurrences(of: "'", with: "'\\''")
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open '\(path)'"]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
