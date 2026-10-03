import AppKit
import ClementineCore

/// Small non-activating panel at the top-right of the active screen with one
/// row per job. Created on first use and released when empty.
@MainActor
final class HUDController {
    var onReveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var onCancel: @MainActor (Job) -> Void = { $0.cancel() }

    private var panel: NSPanel?
    private var stack: NSStackView?
    private var rows: [UUID: JobRowView] = [:]
    private var order: [UUID] = []
    private static let width: CGFloat = 340
    private static let maxRows = 8

    var isEmpty: Bool { rows.isEmpty }

    /// Adds or refreshes the row for `job`.
    func update(_ job: Job) {
        if case .cancelled = job.state {
            remove(job.id)
            return
        }
        let row: JobRowView
        if let existing = rows[job.id] {
            row = existing
        } else {
            row = JobRowView(job: job)
            row.onReveal = { [weak self] url in self?.onReveal(url) }
            row.onCancel = { [weak self] job in self?.onCancel(job) }
            row.onDismiss = { [weak self] id in self?.remove(id) }
            rows[job.id] = row
            order.append(job.id)
            ensurePanel().addArrangedSubview(row)
            trimOldRows()
        }
        row.refresh()
        relayout()
    }

    func setProgress(_ fraction: Double, for id: UUID) {
        rows[id]?.setProgress(fraction)
    }

    func remove(_ id: UUID) {
        guard let row = rows.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        row.removeFromSuperview()
        if rows.isEmpty {
            panel?.orderOut(nil)
            panel = nil
            stack = nil
        } else {
            relayout()
        }
    }

    private func trimOldRows() {
        while order.count > Self.maxRows,
              let id = order.first(where: { rows[$0]?.isFinished == true }) {
            remove(id)
        }
    }

    private func ensurePanel() -> NSStackView {
        if let stack { return stack }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        panel.contentView = background
        self.panel = panel
        self.stack = stack
        return stack
    }

    private func relayout() {
        guard let panel, let stack else { return }
        stack.layoutSubtreeIfNeeded()
        let height = max(40, stack.fittingSize.height)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: visible.maxX - Self.width - 12, y: visible.maxY - height - 12, width: Self.width, height: height)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
        panel.invalidateShadow()
    }
}

/// One job in the HUD: icon, title, status/progress and an action button.
final class JobRowView: NSView {
    let job: Job
    var onReveal: @MainActor (URL) -> Void = { _ in }
    var onCancel: @MainActor (Job) -> Void = { _ in }
    var onDismiss: @MainActor (UUID) -> Void = { _ in }

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let actionButton = NSButton()
    private let closeButton = NSButton()
    private var hovering = false
    private var dismissScheduled = false
    private var lastProgressUpdate: TimeInterval = 0
    private(set) var isFinished = false

    init(job: Job) {
        self.job = job
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 54))
        translatesAutoresizingMaskIntoConstraints = false

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = NSWorkspace.shared.icon(forFile: job.request.inputs.first?.url.path ?? "/")
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.stringValue = job.title
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = 236
        detail.isSelectable = false
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        for b in [actionButton, closeButton] {
            b.isBordered = false
            b.bezelStyle = .inline
            b.imagePosition = .imageOnly
            b.target = self
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        actionButton.action = #selector(actionPressed)
        closeButton.action = #selector(closePressed)
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")
        closeButton.contentTintColor = .tertiaryLabelColor

        for v in [icon, title, detail, progress, actionButton, closeButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 340),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -6),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            progress.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            progress.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            actionButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func refresh() {
        switch job.state {
        case .queued:
            showProgress(false)
            detail.stringValue = "Waiting…"
            setAction(symbol: nil)
            closeButton.toolTip = "Cancel"
        case .running:
            showProgress(true)
            setProgress(job.progress.fractionCompleted, force: true)
            setAction(symbol: nil)
            closeButton.toolTip = "Cancel"
        case .succeeded(let result):
            isFinished = true
            showProgress(false)
            if let out = result.outputs.first {
                icon.image = NSWorkspace.shared.icon(forFile: out.path)
                var text = result.outputs.count == 1 ? "Saved as \(out.lastPathComponent)" : "Saved \(result.outputs.count) files"
                if let note = result.note { text += " · \(note)" }
                detail.stringValue = text
                setAction(symbol: "magnifyingglass", tip: "Show in Finder")
            } else {
                detail.stringValue = result.text.map { "Found: \($0)" } ?? result.note ?? "Done"
                setAction(symbol: nil)
            }
            detail.textColor = .secondaryLabelColor
            closeButton.toolTip = "Dismiss"
            scheduleDismiss()
        case .failed(let failure):
            isFinished = true
            showProgress(false)
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Failed")
            icon.contentTintColor = .systemOrange
            detail.stringValue = failure.message
            detail.textColor = .labelColor
            setAction(symbol: failure.details == nil ? nil : "info.circle", tip: "Details")
            closeButton.toolTip = "Dismiss"
        case .cancelled:
            isFinished = true
        }
    }

    func setProgress(_ fraction: Double, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || fraction >= 1 || now - lastProgressUpdate > 0.05 else { return }
        lastProgressUpdate = now
        if fraction <= 0.001 {
            if !progress.isIndeterminate {
                progress.isIndeterminate = true
                progress.startAnimation(nil)
            }
        } else {
            if progress.isIndeterminate {
                progress.stopAnimation(nil)
                progress.isIndeterminate = false
            }
            progress.doubleValue = fraction
        }
        if let text = job.detail { detail.stringValue = text }
    }

    private func showProgress(_ show: Bool) {
        progress.isHidden = !show
        detail.isHidden = show && job.detail == nil
        if !show && progress.isIndeterminate { progress.stopAnimation(nil) }
    }

    private var actionSymbol: String?

    private func setAction(symbol: String?, tip: String? = nil) {
        actionSymbol = symbol
        actionButton.isHidden = symbol == nil
        actionButton.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: tip) }
        actionButton.toolTip = tip
    }

    @objc private func actionPressed() {
        switch job.state {
        case .succeeded(let result):
            if let out = result.outputs.first { onReveal(out) }
        case .failed(let failure):
            let alert = NSAlert()
            alert.messageText = failure.message
            alert.informativeText = failure.details ?? ""
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Details")
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(failure.message)\n\(failure.details ?? "")", forType: .string)
            }
        default:
            break
        }
    }

    @objc private func closePressed() {
        if job.state.isFinished {
            onDismiss(job.id)
        } else {
            onCancel(job)
        }
    }

    private func scheduleDismiss() {
        guard !dismissScheduled else { return }
        dismissScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.dismissIfIdle() }
        }
    }

    private func dismissIfIdle() {
        if hovering {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.dismissIfIdle() }
            }
        } else {
            onDismiss(job.id)
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
