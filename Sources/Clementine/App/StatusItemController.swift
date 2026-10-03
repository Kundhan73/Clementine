import AppKit
import ClementineCore

/// The menu-bar item: menu, Recent submenu, and a drop target for files
/// (drop files on the icon to get the wheel without holding Shift).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSWindowDelegate {
    var onConvertFiles: @MainActor () -> Void = {}
    var onDropFiles: @MainActor ([URL]) -> Void = { _ in }
    var onTogglePause: @MainActor () -> Void = {}
    var onSettings: @MainActor () -> Void = {}
    var onHowTo: @MainActor () -> Void = {}
    var onCheckForUpdates: @MainActor () -> Void = {}

    let item: NSStatusItem
    private let menu = NSMenu()
    private let recentMenu = NSMenu(title: "Recent")
    private var pauseItem: NSMenuItem?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = MenuBarIcon.make()
        item.button?.setAccessibilityLabel("Clementine")
        item.button?.toolTip = "Clementine — hold ⇧ while dragging a file"
        buildMenu()
        item.menu = menu
        // The status item's window exists once it's in the menu bar.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.enableDrops() }
        }
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        add("Convert Files…", #selector(convertFiles), key: "o")
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        menu.addItem(recent)
        pauseItem = add("Pause Shift-Drag", #selector(togglePause))
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings), key: ",")
        add("How to Use", #selector(howTo))
        add("Check for Updates…", #selector(checkForUpdates))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Clementine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        pauseItem?.state = Preferences.shiftDragEnabled ? .off : .on
        recentMenu.removeAllItems()
        let recents = Preferences.recentOutputs
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }
        for url in recents {
            let exists = FileManager.default.fileExists(atPath: url.path)
            let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = url
            entry.toolTip = url.path
            entry.isEnabled = exists
            let icon = NSWorkspace.shared.icon(forFile: exists ? url.path : "/")
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            recentMenu.addItem(entry)
        }
        recentMenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Recent", action: #selector(clearRecent), keyEquivalent: "")
        clear.target = self
        recentMenu.addItem(clear)
    }

    @objc private func convertFiles() { onConvertFiles() }
    @objc private func togglePause() { onTogglePause() }
    @objc private func openSettings() { onSettings() }
    @objc private func howTo() { onHowTo() }
    @objc private func checkForUpdates() { onCheckForUpdates() }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func clearRecent() {
        Preferences.defaults.removeObject(forKey: PrefKey.recentOutputs)
    }

    /// Point just under the menu-bar icon (where the wheel pops up for drops).
    var anchorPoint: NSPoint {
        guard let button = item.button, let window = button.window else { return NSEvent.mouseLocation }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return NSPoint(x: frame.midX, y: frame.minY - 150)
    }

    // MARK: Drops on the icon (forwarded by the status bar window to its delegate)

    private func enableDrops() {
        guard let window = item.button?.window else { return }
        window.registerForDraggedTypes([.fileURL])
        window.delegate = self
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !fileURLs(sender).isEmpty
        item.button?.highlight(ok)
        return ok ? .copy : []
    }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    @objc func draggingExited(_ sender: NSDraggingInfo?) {
        item.button?.highlight(false)
    }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onDropFiles(urls) }
        }
        return true
    }
}
