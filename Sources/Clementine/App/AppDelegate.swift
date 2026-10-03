import AppKit
import ClementineCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private let selfTest: Bool
    private var status: StatusItemController?
    let dragMonitor = DragMonitor()
    let wheel = WheelController()
    private let services = ServicesProvider()

    init(selfTest: Bool) {
        self.selfTest = selfTest
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        Preferences.applyFFmpegOverride()
        MainMenu.install()
        PromiseReceiver.cleanUp()

        let status = StatusItemController()
        status.onConvertFiles = { [weak self] in self?.chooseFilesToConvert() }
        status.onDropFiles = { [weak self] urls in self?.showWheel(for: urls, at: self?.status?.anchorPoint) }
        status.onTogglePause = { [weak self] in
            Preferences.shiftDragEnabled.toggle()
            self?.applyShiftDragPreference()
        }
        status.onSettings = { SettingsWindowController.shared.show() }
        status.onHowTo = { OnboardingWindowController.shared.show() }
        status.onCheckForUpdates = { Updater.shared.checkForUpdates(userInitiated: true) }
        self.status = status

        dragMonitor.onModeChange = { [weak self] old, new in
            guard let self else { return }
            switch (old, new) {
            case (nil, let mode?): self.wheel.show(mode: mode, at: NSEvent.mouseLocation)
            case (_?, let mode?): self.wheel.setMode(mode)
            case (_?, nil): self.wheel.hide()
            case (nil, nil): break
            }
        }
        wheel.onNoFiles = { [weak self] in self?.dragMonitor.suppressUntilMouseUp() }
        wheel.onPick = { chip, items, promises in
            JobCenter.shared.run(chip, items: items, promises: promises)
        }
        applyShiftDragPreference()
        NSApp.servicesProvider = services

        if selfTest {
            SelfTest.start()
            return
        }
        LoginItem.applyDefaultOnFirstLaunch()
        if !Preferences.onboardingDone {
            OnboardingWindowController.shared.show()
        }
    }

    func applyShiftDragPreference() {
        if Preferences.shiftDragEnabled { dragMonitor.start() } else { dragMonitor.stop() }
    }

    /// "Open With → Clementine" / dropping files on the app icon.
    func application(_ sender: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        showWheel(for: files, at: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    /// Shows the click-mode wheel for files (menu, drop on icon, Services).
    func showWheel(for urls: [URL], at point: NSPoint?, mode: WheelMode = .convert) {
        let items = urls.map(InputItem.inspect)
        wheel.showForClick(items: items, at: point ?? NSEvent.mouseLocation, mode: mode)
    }

    private func chooseFilesToConvert() {
        let panel = NSOpenPanel()
        panel.title = "Convert Files"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let mouse = NSEvent.mouseLocation
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.showWheel(for: urls, at: mouse) }
        }
    }
}

/// Finder Services: "Convert with Clementine…" shows the keyboard-navigable
/// wheel for the selected files.
final class ServicesProvider: NSObject {
    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files were selected." as NSString
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppDelegate.shared?.showWheel(for: urls, at: nil) }
        }
    }
}
