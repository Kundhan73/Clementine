import AppKit
import ClementineCore
import QuartzCore
import UniformTypeIdentifiers

@MainActor
protocol WheelViewDelegate: AnyObject {
    /// A drag entered the wheel: the delegate reads the dragged files here
    /// (the only place the drag pasteboard's contents are read).
    func wheelView(_ view: WheelView, draggingEntered info: NSDraggingInfo)
    /// A chip was chosen (dropped on, or clicked in click mode).
    func wheelView(_ view: WheelView, didPick chip: WheelChip, info: NSDraggingInfo?)
    /// Click mode only: Esc, a click on the hub or outside the chips.
    func wheelViewDidCancel(_ view: WheelView)
}

/// Colours for the wheel, resolved for one appearance.
struct WheelPalette {
    var discFill: CGColor
    var discStroke: CGColor
    var hubFill: CGColor
    var chipFill: CGColor
    var chipStroke: CGColor
    var text: CGColor
    var secondaryText: CGColor
    var accent: CGColor
    var accentText: CGColor

    static func resolve(for appearance: NSAppearance) -> WheelPalette {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var palette = WheelPalette(
            discFill: NSColor(white: dark ? 0.16 : 0.96, alpha: 0.92).cgColor,
            discStroke: NSColor(white: dark ? 1 : 0, alpha: dark ? 0.14 : 0.10).cgColor,
            hubFill: NSColor(white: dark ? 0.30 : 1.0, alpha: dark ? 0.85 : 0.95).cgColor,
            chipFill: NSColor(white: dark ? 0.24 : 1.0, alpha: dark ? 0.92 : 0.88).cgColor,
            chipStroke: NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.09).cgColor,
            text: NSColor(white: dark ? 0.96 : 0.12, alpha: 1).cgColor,
            secondaryText: NSColor(white: dark ? 0.72 : 0.38, alpha: 1).cgColor,
            accent: (dark ? NSColor(srgbRed: 1.0, green: 0.56, blue: 0.14, alpha: 1)
                          : NSColor(srgbRed: 0.95, green: 0.47, blue: 0.05, alpha: 1)).cgColor,
            accentText: NSColor.white.cgColor)
        appearance.performAsCurrentDrawingAppearance {
            palette.text = NSColor.labelColor.cgColor
        }
        return palette
    }
}

/// The wheel: a hub and rings of chips drawn with Core Animation layers (no
/// SwiftUI, nothing redrawn per frame). Also the drop target: hit-tests the
/// pointer by ring and angle, accepts drops only on chips.
final class WheelView: NSView {
    weak var delegate: WheelViewDelegate?
    /// Click mode (menu, status-item drop): chips are clicked, Esc cancels.
    var clickMode = false
    /// Snapshot rendering: draw a solid disc instead of relying on the blur.
    var solidDisc = false {
        didSet { applyPalette() }
    }

    private(set) var chips: [WheelChip] = []
    private(set) var mode: WheelMode = .convert
    private(set) var wheelLayout = WheelLayout(count: 0)
    private(set) var hovered: Int?
    private var scale: CGFloat = 1
    private var fileIcon: NSImage?
    private var fileCount = 0
    private var palette = WheelPalette.resolve(for: NSAppearance(named: .aqua)!)

    private let root = CALayer()
    /// Everything lives in this centred layer so the wheel can scale from its middle.
    private let content = CALayer()
    private var builtSize: CGSize = .zero
    private let disc = CAShapeLayer()
    private let hub = CAShapeLayer()
    private let hubIcon = CALayer()
    private let hubIconBack = CALayer()
    private let badge = CAShapeLayer()
    private let badgeText = CATextLayer()
    private let hubLabel = CATextLayer()
    private var chipLayers: [ChipLayer] = []
    private var trackingArea: NSTrackingArea?

    static var dragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root           // layer-hosting: we own the layer tree
        wantsLayer = true
        root.masksToBounds = false
        root.addSublayer(content)
        for l in [disc, hub, hubIconBack, hubIcon, badge, badgeText, hubLabel] as [CALayer] { content.addSublayer(l) }
        hubIcon.contentsGravity = .resizeAspect
        hubIconBack.contentsGravity = .resizeAspect
        hubIconBack.opacity = 0.55
        for t in [badgeText, hubLabel] {
            t.alignmentMode = .center
            t.isWrapped = true
            t.truncationMode = .end
        }
        registerForDraggedTypes(Self.dragTypes)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Clementine wheel")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { clickMode }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var contentsScale: CGFloat { window?.backingScaleFactor ?? 2 }

    // MARK: Configuration

    /// Sets the chips, mode and hub contents and rebuilds the layers.
    func configure(chips: [WheelChip], mode: WheelMode, icon: NSImage?, count: Int, scale: CGFloat, animated: Bool) {
        self.chips = chips
        self.mode = mode
        self.fileIcon = icon
        self.fileCount = count
        self.scale = scale
        let tools = chips.contains { if case .tool = $0 { return true } else { return false } }
        wheelLayout = WheelLayout(count: chips.count, scale: scale, largeChips: tools)
        hovered = nil
        rebuild()
        if animated { animateIn(chipsOnly: true) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild() }
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        palette = WheelPalette.resolve(for: effectiveAppearance)
        let s = scale
        let c = center
        let scaleFactor = contentsScale
        builtSize = bounds.size
        content.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        content.frame = bounds

        let discR = wheelLayout.discRadius
        disc.frame = bounds
        disc.path = CGPath(ellipseIn: CGRect(x: c.x - discR, y: c.y - discR, width: 2 * discR, height: 2 * discR), transform: nil)
        disc.lineWidth = 1

        let hubR = wheelLayout.hubRadius
        hub.frame = bounds
        hub.path = CGPath(ellipseIn: CGRect(x: c.x - hubR, y: c.y - hubR, width: 2 * hubR, height: 2 * hubR), transform: nil)
        hub.lineWidth = 1

        let iconSide = 34 * s
        let iconCenter = CGPoint(x: c.x, y: c.y + 11 * s)
        hubIcon.frame = CGRect(x: iconCenter.x - iconSide / 2, y: iconCenter.y - iconSide / 2, width: iconSide, height: iconSide)
        hubIconBack.frame = hubIcon.frame.offsetBy(dx: 5 * s, dy: 4 * s)
        let icon = fileIcon ?? NSWorkspace.shared.icon(for: .item)
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: iconSide, height: iconSide)
        hubIcon.contents = sized.layerContents(forContentsScale: scaleFactor)
        hubIconBack.contents = fileCount > 1 ? hubIcon.contents : nil

        let badgeR = 9.5 * s
        let badgeCenter = CGPoint(x: iconCenter.x + iconSide * 0.42, y: iconCenter.y + iconSide * 0.36)
        badge.frame = bounds
        badge.path = CGPath(ellipseIn: CGRect(x: badgeCenter.x - badgeR, y: badgeCenter.y - badgeR, width: 2 * badgeR, height: 2 * badgeR), transform: nil)
        badge.isHidden = fileCount < 2
        badgeText.isHidden = fileCount < 2
        badgeText.string = fileCount > 99 ? "99+" : "\(fileCount)"
        badgeText.font = NSFont.systemFont(ofSize: 10 * s, weight: .bold)
        badgeText.fontSize = 10 * s
        badgeText.contentsScale = scaleFactor
        let badgeTextH = 13 * s
        badgeText.frame = CGRect(x: badgeCenter.x - badgeR - 4 * s, y: badgeCenter.y - badgeTextH / 2 - 0.5 * s,
                                 width: 2 * badgeR + 8 * s, height: badgeTextH)

        hubLabel.contentsScale = scaleFactor
        updateHubLabel()

        chipLayers.forEach { $0.removeFromSuperlayer() }
        chipLayers = chips.enumerated().map { i, chip in
            let layer = ChipLayer(chip: chip, radius: wheelLayout.chipRadius, scale: s, contentsScale: scaleFactor)
            let p = wheelLayout.center(of: i)
            layer.position = CGPoint(x: c.x + p.x, y: c.y + p.y)
            content.addSublayer(layer)
            return layer
        }
        applyPalette()
        CATransaction.commit()
        updateTrackingArea()
    }

    private func applyPalette() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.fillColor = solidDisc ? palette.discFill : NSColor.clear.cgColor
        disc.strokeColor = palette.discStroke
        hub.fillColor = palette.hubFill
        hub.strokeColor = palette.chipStroke
        badge.fillColor = palette.accent
        badgeText.foregroundColor = palette.accentText
        hubLabel.foregroundColor = hovered == nil ? palette.secondaryText : palette.text
        for (i, chip) in chipLayers.enumerated() { chip.apply(palette, highlighted: i == hovered) }
        CATransaction.commit()
    }

    private func updateHubLabel() {
        let s = scale
        let text: String
        let font: NSFont
        if let i = hovered, chips.indices.contains(i) {
            text = chips[i].caption
            font = NSFont.systemFont(ofSize: 9.5 * s, weight: .medium)
        } else if chips.isEmpty && fileCount > 0 {
            text = mode == .tools ? "No tools" : "No formats"
            font = NSFont.systemFont(ofSize: 10 * s, weight: .medium)
        } else {
            text = mode == .tools ? "Tools" : "Convert"
            font = NSFont.systemFont(ofSize: 11 * s, weight: .semibold)
        }
        hubLabel.string = text
        hubLabel.font = font
        hubLabel.fontSize = font.pointSize
        let width = 82 * s
        let lineH = ceil(font.ascender - font.descender + font.leading) + 1
        let lines: CGFloat = (text as NSString).size(withAttributes: [.font: font]).width > width ? 2 : 1
        let h = lineH * lines
        let top = center.y - 9 * s
        hubLabel.frame = CGRect(x: center.x - width / 2, y: top - h, width: width, height: h)
        hubLabel.foregroundColor = hovered == nil ? palette.secondaryText : palette.text
    }

    // MARK: Animation

    /// Springs the chips (and hub) in with a small stagger.
    func animateIn(chipsOnly: Bool = false) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = CACurrentMediaTime()
        func pop(_ layer: CALayer, delay: CFTimeInterval, from: CGFloat) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.14
            fade.beginTime = now + delay
            fade.fillMode = .backwards
            layer.add(fade, forKey: "fadeIn")
            guard !reduce else { return }
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = from
            spring.toValue = 1
            spring.mass = 0.8
            spring.stiffness = 320
            spring.damping = 16
            spring.duration = spring.settlingDuration
            spring.beginTime = now + delay
            spring.fillMode = .backwards
            layer.add(spring, forKey: "popIn")
        }
        if !chipsOnly {
            pop(content, delay: 0, from: 0.86)
        }
        for (i, chip) in chipLayers.enumerated() {
            pop(chip, delay: 0.012 * Double(i), from: 0.35)
        }
    }

    // MARK: Hover and hit testing

    func hitTest(windowPoint: NSPoint) -> WheelLayout.Hit {
        let p = convert(windowPoint, from: nil)
        return wheelLayout.hitTest(CGPoint(x: p.x - center.x, y: p.y - center.y))
    }

    func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        let old = hovered
        hovered = index
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        if let old, chipLayers.indices.contains(old) { chipLayers[old].apply(palette, highlighted: false) }
        if let index, chipLayers.indices.contains(index) {
            chipLayers[index].apply(palette, highlighted: true)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateHubLabel()
        CATransaction.commit()
    }

    private func chipIndex(at windowPoint: NSPoint) -> Int? {
        if case .chip(let i) = hitTest(windowPoint: windowPoint), chips.indices.contains(i) { return i }
        return nil
    }

    // MARK: Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        delegate?.wheelView(self, draggingEntered: sender)
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let index = chipIndex(at: sender.draggingLocation)
        setHovered(index)
        return index == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHovered(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        chipIndex(at: sender.draggingLocation) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = chipIndex(at: sender.draggingLocation) else { return false }
        delegate?.wheelView(self, didPick: chips[i], info: sender)
        return true
    }

    // MARK: Click mode

    private func updateTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard clickMode else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard clickMode else { return }
        setHovered(chipIndex(at: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        if clickMode { setHovered(nil) }
    }

    override func mouseUp(with event: NSEvent) {
        guard clickMode else { return }
        if let i = chipIndex(at: event.locationInWindow) {
            delegate?.wheelView(self, didPick: chips[i], info: nil)
        } else {
            delegate?.wheelViewDidCancel(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard clickMode else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53: // Esc
            delegate?.wheelViewDidCancel(self)
        case 36, 76: // Return, Enter
            if let i = hovered, chips.indices.contains(i) { delegate?.wheelView(self, didPick: chips[i], info: nil) }
        case 123, 125: // ← ↓: counter-clockwise
            moveSelection(by: -1)
        case 124, 126: // → ↑: clockwise
            moveSelection(by: 1)
        default:
            super.keyDown(with: event)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !chips.isEmpty else { return }
        let next = ((hovered ?? (delta > 0 ? -1 : 0)) + delta + chips.count) % chips.count
        setHovered(next)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        guard let window else { return nil }
        let c = center
        return chips.enumerated().map { i, chip in
            let p = wheelLayout.center(of: i)
            let r = wheelLayout.chipRadius
            let local = NSRect(x: c.x + p.x - r, y: c.y + p.y - r, width: 2 * r, height: 2 * r)
            let screen = window.convertToScreen(convert(local, to: nil))
            let element = NSAccessibilityElement.element(withRole: .button, frame: screen, label: chip.caption, parent: self)
            return element
        }
    }

    // MARK: Rendering for snapshots

    /// Renders the layer tree into an image (CI snapshots).
    func renderImage(scale factor: CGFloat = 2) -> NSImage? {
        let w = Int(bounds.width * factor), h = Int(bounds.height * factor)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: factor, y: factor)
        root.render(in: ctx)
        guard let image = ctx.makeImage() else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }
}

/// One chip: a circle with a label (formats) or an icon and a label (tools).
final class ChipLayer: CALayer {
    let chip: WheelChip
    private let circle = CAShapeLayer()
    private let title = CATextLayer()
    private let icon = CALayer()
    private let scale: CGFloat
    private let contentsScaleFactor: CGFloat

    init(chip: WheelChip, radius r: CGFloat, scale s: CGFloat, contentsScale: CGFloat) {
        self.chip = chip
        self.scale = s
        self.contentsScaleFactor = contentsScale
        super.init()
        bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        circle.frame = bounds
        circle.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        circle.lineWidth = 1
        addSublayer(circle)
        title.alignmentMode = .center
        title.isWrapped = true
        title.truncationMode = .end
        title.contentsScale = contentsScale
        title.string = chip.title
        addSublayer(title)
        switch chip {
        case .format:
            let font = NSFont.systemFont(ofSize: (chip.title.count > 4 ? 11 : 12.5) * s, weight: .semibold)
            title.font = font
            title.fontSize = font.pointSize
            let h = ceil(font.ascender - font.descender) + 1
            title.frame = CGRect(x: 2 * s, y: r - h / 2 - 0.5 * s, width: 2 * r - 4 * s, height: h)
        case .tool:
            let font = NSFont.systemFont(ofSize: 8.5 * s, weight: .medium)
            title.font = font
            title.fontSize = font.pointSize
            let lineH = ceil(font.ascender - font.descender) + 0.5
            let maxW = 2 * r - 8 * s
            let twoLines = (chip.title as NSString).size(withAttributes: [.font: font]).width > maxW
            let textH = lineH * (twoLines ? 2 : 1)
            let iconSide = (twoLines ? 15 : 17) * s
            let gap = 2 * s
            let total = iconSide + gap + textH
            let bottom = r - total / 2
            title.frame = CGRect(x: 4 * s, y: bottom, width: maxW, height: textH)
            icon.frame = CGRect(x: r - iconSide / 2, y: bottom + textH + gap, width: iconSide, height: iconSide)
            icon.contentsGravity = .resizeAspect
            addSublayer(icon)
        }
        name = chip.key
    }

    override init(layer: Any) {
        let other = layer as! ChipLayer
        chip = other.chip
        scale = other.scale
        contentsScaleFactor = other.contentsScaleFactor
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ palette: WheelPalette, highlighted: Bool) {
        circle.fillColor = highlighted ? palette.accent : palette.chipFill
        circle.strokeColor = highlighted ? palette.accent : palette.chipStroke
        title.foregroundColor = highlighted ? palette.accentText : palette.text
        transform = highlighted ? CATransform3DMakeScale(1.12, 1.12, 1) : CATransform3DIdentity
        zPosition = highlighted ? 1 : 0
        if case .tool(let tool) = chip {
            let color = NSColor(cgColor: highlighted ? palette.accentText : palette.text) ?? .labelColor
            icon.contents = Self.symbol(tool.symbolName, pointSize: icon.bounds.height * 0.8, color: color,
                                        contentsScale: contentsScaleFactor)
        }
    }

    static func symbol(_ name: String, pointSize: CGFloat, color: NSColor, contentsScale: CGFloat) -> Any? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = base.withSymbolConfiguration(config) else { return nil }
        return image.layerContents(forContentsScale: contentsScale)
    }
}
