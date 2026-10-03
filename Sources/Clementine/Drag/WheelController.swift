import AppKit
import ClementineCore
import UniformTypeIdentifiers

/// The borderless, non-activating panel that hosts the wheel.
final class WheelPanel: NSPanel {
    /// True in click mode so the wheel can take keyboard focus.
    var allowsKey = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Holds the frosted disc (a masked visual-effect view) under the wheel.
final class WheelContainerView: NSView {
    let backdrop = NSVisualEffectView()
    let wheel = WheelView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        addSubview(backdrop)
        addSubview(wheel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Sizes the disc to the wheel's current layout.
    func layoutDisc() {
        wheel.frame = bounds
        let r = wheel.layout.discRadius
        let rect = NSRect(x: bounds.midX - r, y: bounds.midY - r, width: 2 * r, height: 2 * r).integral
        backdrop.frame = rect
        backdrop.maskImage = NSImage(size: rect.size, flipped: false) { bounds in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            return true
        }
    }

    override func layout() {
        super.layout()
        layoutDisc()
    }
}

/// Shows the wheel (drag or click mode), turns dragged files into chips and
/// reports the user's pick.
@MainActor
final class WheelController: NSObject, WheelViewDelegate {
    /// A chip was picked for these files (promises not yet received).
    var onPick: @MainActor (WheelChip, [InputItem], [NSFilePromiseReceiver]) -> Void = { _, _, _ in }
    /// The drag carries no files: the monitor should stay quiet until mouse-up.
    var onNoFiles: @MainActor () -> Void = {}

    private var panel: WheelPanel?
    private var container: WheelContainerView?
    private(set) var isVisible = false
    private var mode: WheelMode = .convert
    private var items: [InputItem] = []
    private var promises: [NSFilePromiseReceiver] = []
    private var icon: NSImage?
    /// Drag pasteboard change count the cached items belong to.
    private var itemsChangeCount = -1
    private var hideToken = 0

    // MARK: Drag mode

    func show(mode: WheelMode, at point: NSPoint) {
        let changeCount = NSPasteboard(name: .drag).changeCount
        if changeCount != itemsChangeCount {
            items = []
            promises = []
            icon = nil
        }
        self.mode = mode
        present(at: point, clickMode: false)
    }

    func setMode(_ mode: WheelMode) {
        guard isVisible, mode != self.mode else { return }
        self.mode = mode
        refreshChips(animated: true)
    }

    // MARK: Click mode (menu, status-item drop)

    func showForClick(items: [InputItem], at point: NSPoint, mode: WheelMode = .convert) {
        self.items = items
        self.promises = []
        self.icon = Self.icon(for: items)
        self.itemsChangeCount = -1
        self.mode = mode
        present(at: point, clickMode: true)
    }

    // MARK: Presentation

    private func makePanel() -> (WheelPanel, WheelContainerView) {
        if let panel, let container { return (panel, container) }
        let panel = WheelPanel()
        let container = WheelContainerView(frame: panel.contentLayoutRect)
        container.wheel.delegate = self
        panel.contentView = container
        self.panel = panel
        self.container = container
        return (panel, container)
    }

    private func present(at point: NSPoint, clickMode: Bool) {
        let (panel, container) = makePanel()
        hideToken += 1
        let scale = Preferences.wheelSize.scale
        let side = WheelLayout(count: 24, scale: scale, largeChips: true).canvasSide
        // Keep the (typical, one-ring) disc on screen.
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var center = point
        if let visible = screen?.visibleFrame {
            let r = WheelLayout(count: 12, scale: scale).discRadius
            center.x = min(max(center.x, visible.minX + r), visible.maxX - r)
            center.y = min(max(center.y, visible.minY + r), visible.maxY - r)
        }
        panel.allowsKey = clickMode
        panel.setFrame(NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side), display: false)
        container.frame = NSRect(x: 0, y: 0, width: side, height: side)
        container.wheel.clickMode = clickMode
        configureWheel(animated: false)
        panel.alphaValue = 1
        if clickMode {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(container.wheel)
        } else {
            panel.orderFrontRegardless()
        }
        container.wheel.animateIn()
        panel.invalidateShadow()
        isVisible = true
    }

    private func configureWheel(animated: Bool) {
        guard let container else { return }
        let hidden = Preferences.hiddenChips
        let items = self.items
        let chips = items.isEmpty ? [] : WheelContent.chips(for: items, mode: mode) { chip in
            !hidden.contains(chip.key) && Engines.isAvailable(chip, for: items)
        }
        container.wheel.configure(chips: chips, mode: mode, icon: icon, count: items.count,
                                  scale: Preferences.wheelSize.scale, animated: animated)
        container.layoutDisc()
        panel?.invalidateShadow()
    }

    private func refreshChips(animated: Bool) {
        configureWheel(animated: animated)
    }

    func hide(animated: Bool = true) {
        guard isVisible, let panel else { return }
        isVisible = false
        hideToken += 1
        let token = hideToken
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideToken == token else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    // MARK: WheelViewDelegate

    func wheelView(_ view: WheelView, draggingEntered info: NSDraggingInfo) {
        guard items.isEmpty else { return }
        let pasteboard = info.draggingPasteboard
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            items = urls.map(InputItem.inspect)
            promises = []
        } else if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                    as? [NSFilePromiseReceiver], !receivers.isEmpty {
            promises = receivers
            items = receivers.flatMap { receiver in
                receiver.fileTypes.map { uti in
                    InputItem(promisedName: "promised." + (UTType(uti)?.preferredFilenameExtension ?? "data"))
                }
            }
        }
        itemsChangeCount = pasteboard.changeCount
        guard !items.isEmpty else {
            hide(animated: false)
            onNoFiles()
            return
        }
        icon = Self.icon(for: items)
        refreshChips(animated: true)
    }

    func wheelView(_ view: WheelView, didPick chip: WheelChip, info: NSDraggingInfo?) {
        let picked = (items, promises)
        hide(animated: true)
        if view.clickMode { panel?.allowsKey = false }
        onPick(chip, picked.0, picked.1)
    }

    func wheelViewDidCancel(_ view: WheelView) {
        hide(animated: true)
        panel?.allowsKey = false
    }

    static func icon(for items: [InputItem]) -> NSImage? {
        guard let first = items.first else { return nil }
        if FileManager.default.fileExists(atPath: first.url.path) {
            return NSWorkspace.shared.icon(forFile: first.url.path)
        }
        if let ext = first.format?.fileExtension, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return nil
    }

    // MARK: Snapshots

    /// Renders the wheel offscreen (CI snapshots).
    func snapshot(items: [InputItem], mode: WheelMode, hovered: Int?, appearance: NSAppearance) -> NSImage? {
        let scale = Preferences.wheelSize.scale
        let probe = WheelContent.chips(for: items, mode: mode) { Engines.isAvailable($0, for: items) }
        let side = WheelLayout(count: probe.count, scale: scale, largeChips: mode == .tools).canvasSide
        let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wheel.appearance = appearance
        wheel.solidDisc = true
        wheel.configure(chips: probe, mode: mode, icon: Self.icon(for: items), count: items.count, scale: scale, animated: false)
        wheel.setHovered(hovered)
        return wheel.renderImage()
    }
}
