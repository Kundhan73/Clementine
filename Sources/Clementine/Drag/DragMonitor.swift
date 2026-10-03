import AppKit
import ClementineCore

/// Detects shift-drags of files anywhere on screen without Accessibility
/// permission: a passive global mouse monitor plus the drag pasteboard's
/// change count. Never reads pasteboard *contents* (that happens only inside
/// the wheel's dragging-destination callbacks).
///
/// Cost model: idle = no timers, and only mouse-down is watched (so plain
/// pointer movement never wakes the app); while a button is held, drag/up
/// events are watched and cost at most ~20 cheap change-count reads per
/// second; during a real drag a ~30 Hz timer watches the modifier keys until
/// mouse-up.
@MainActor
final class DragMonitor {
    /// Wheel should appear (nil → mode) / switch mode / disappear.
    var onModeChange: @MainActor (_ old: WheelMode?, _ new: WheelMode?) -> Void = { _, _ in }

    private var monitor: Any?
    /// Drag/up events, only while the button is down.
    private var pressMonitor: Any?
    private var timer: Timer?
    private var baselineChangeCount = 0
    private var mouseIsDown = false
    private var dragConfirmed = false
    private var suppressed = false
    private var lastPasteboardCheck: TimeInterval = 0
    private(set) var mode: WheelMode?

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endDrag()
    }

    private func watchPress(_ on: Bool) {
        if on, pressMonitor == nil {
            pressMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                let type = event.type
                MainActor.assumeIsolated { self?.handle(type) }
            }
        } else if !on, let monitor = pressMonitor {
            pressMonitor = nil
            // Not from inside the monitor's own callback.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { NSEvent.removeMonitor(monitor) }
            }
        }
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            endDrag()
            mouseIsDown = true
            baselineChangeCount = NSPasteboard(name: .drag).changeCount
            watchPress(true)
        case .leftMouseDragged:
            // Fast path: nothing to do once confirmed (the timer takes over)
            // or when the button isn't tracked.
            guard mouseIsDown, !dragConfirmed else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // Check the pasteboard eagerly while a modifier is held, lazily otherwise.
            let interval = NSEvent.modifierFlags.isDisjoint(with: [.shift, .control]) ? 0.05 : 0.016
            guard now - lastPasteboardCheck >= interval else { return }
            lastPasteboardCheck = now
            if NSPasteboard(name: .drag).changeCount != baselineChangeCount {
                confirmDrag()
            }
        case .leftMouseUp:
            endDrag()
        default:
            break
        }
    }

    /// A drag session started by Clementine itself (onboarding practice
    /// file); global monitors don't see our own events.
    func beginOwnDrag() {
        endDrag()
        mouseIsDown = true
        confirmDrag()
    }

    func endOwnDrag() { endDrag() }

    /// The wheel found no files on the drag pasteboard: stay hidden until the
    /// mouse is released.
    func suppressUntilMouseUp() {
        suppressed = true
        setMode(nil)
    }

    private func confirmDrag() {
        dragConfirmed = true
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        // Watchdog: if the button is up we missed the mouse-up; never leave a stuck wheel.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            endDrag()
            return
        }
        setMode(suppressed ? nil : Self.mode(for: NSEvent.modifierFlags, scheme: Preferences.modifierScheme))
    }

    private func endDrag() {
        timer?.invalidate()
        timer = nil
        watchPress(false)
        mouseIsDown = false
        dragConfirmed = false
        suppressed = false
        setMode(nil)
    }

    private func setMode(_ new: WheelMode?) {
        guard new != mode else { return }
        let old = mode
        mode = new
        onModeChange(old, new)
    }

    static func mode(for flags: NSEvent.ModifierFlags, scheme: ModifierScheme) -> WheelMode? {
        let held = flags.intersection([.shift, .control, .option, .command])
        if held == scheme.convertFlags { return .convert }
        if held == scheme.toolsFlags { return .tools }
        return nil
    }
}
