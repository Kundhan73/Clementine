import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let selfTest: Bool
    private var statusItem: NSStatusItem?

    init(selfTest: Bool) {
        self.selfTest = selfTest
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.make()
        item.button?.setAccessibilityLabel("Clementine")
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Clementine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        if selfTest { SelfTest.start() }
    }
}
