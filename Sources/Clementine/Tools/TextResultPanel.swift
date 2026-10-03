import AppKit
import ClementineCore

/// Small floating panel near the pointer showing a text result (Read QR):
/// the text, Copy, and Open for web links (shows the full URL; opens only
/// when clicked).
@MainActor
final class TextResultPanel: NSObject, NSWindowDelegate {
    private static var current: TextResultPanel?

    private let panel: NSPanel
    private let text: String

    static func show(title: String, text: String) {
        current?.panel.close()
        let result = TextResultPanel(title: title, text: text)
        current = result
        result.present()
    }

    private init(title: String, text: String) {
        self.text = text
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: true)
        super.init()
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self

        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = true
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = 330
        label.maximumNumberOfLines = 12

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyText))
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        var buttons: [NSView] = [copy]
        if let url = Self.webURL(in: text) {
            let open = NSButton(title: "Open Link", target: self, action: #selector(openLink))
            open.toolTip = url.absoluteString
            buttons.append(open)
        }
        let done = NSButton(title: "Done", target: self, action: #selector(closePanel))
        done.keyEquivalent = "\r"
        buttons.append(done)
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        var rows: [NSView] = [label]
        if let url = Self.webURL(in: text), url.absoluteString != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            let link = NSTextField(wrappingLabelWithString: url.absoluteString)
            link.font = .systemFont(ofSize: 11)
            link.textColor = .secondaryLabelColor
            rows.append(link)
        }
        rows.append(buttonRow)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        panel.contentView = stack
    }

    private func present() {
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: mouse.x + 12, y: mouse.y - frame.height - 12)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    /// The first http(s) URL in the text, if any. Other schemes are never opened.
    static func webURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           url.host != nil {
            return url
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, options: [], range: range) {
            if let url = match.url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                return url
            }
        }
        return nil
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openLink() {
        if let url = Self.webURL(in: text) { NSWorkspace.shared.open(url) }
        closePanel()
    }

    @objc private func closePanel() { panel.close() }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}

/// Opens dialogs and editors for tools that need them (filled in by later
/// milestones). Tools not handled here run instantly with default options.
@MainActor
enum ToolUI {
    static func handles(_ tool: Tool) -> Bool { false }
    static func open(_ tool: Tool, items: [InputItem]) {}
}
