import AppKit
import ClementineCore
import SwiftUI

@MainActor
final class RedactModel: ObservableObject {
    @Published var regions: [Redaction] = [] { didSet { render() } }
    @Published var style: Redaction.Style = .blur
    @Published var selected: UUID?
    @Published var rendered: CGImage?
    @Published var search = ""
    @Published var status = ""
    let preview: CGImage
    let fullSize: CGSize
    private let scheduler = RenderScheduler()
    private var undoStack: [[Redaction]] = []

    init(preview: CGImage, fullSize: CGSize) {
        self.preview = preview
        self.fullSize = fullSize
    }

    /// Preview pixels per full-resolution pixel.
    var previewScale: CGFloat { CGFloat(preview.width) / max(1, fullSize.width) }

    func commit(_ new: [Redaction]) {
        undoStack.append(regions)
        regions = new
    }

    func undo() {
        if let last = undoStack.popLast() { regions = last }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func deleteSelected() {
        guard let selected else { return }
        commit(regions.filter { $0.id != selected })
        self.selected = nil
    }

    func render() {
        let s = previewScale
        let scaled = regions.map { r -> Redaction in
            var c = r
            c.rect = CGRect(x: r.rect.minX * s, y: r.rect.minY * s, width: r.rect.width * s, height: r.rect.height * s)
            return c
        }
        let image = preview
        scheduler.schedule({ try? Redactor.render(image, redactions: scaled) }) { [weak self] in self?.rendered = $0 }
    }

    /// Adds regions found on the preview, scaled to full resolution.
    func add(_ previewRects: [CGRect], label: String) {
        let s = previewScale
        let found = previewRects.map { r in
            Redaction(rect: CGRect(x: r.minX / s, y: r.minY / s, width: r.width / s, height: r.height / s), style: style)
        }
        status = found.isEmpty ? "No \(label) found." : "Added \(found.count) \(label)."
        if !found.isEmpty { commit(regions + found) }
    }

    func findFaces() {
        let image = preview
        Task.detached(priority: .userInitiated) {
            let rects = Redactor.faces(in: image)
            await MainActor.run { self.add(rects, label: rects.count == 1 ? "face" : "faces") }
        }
    }

    func findText() {
        let image = preview
        Task.detached(priority: .userInitiated) {
            let rects = Redactor.textLines(in: image).map(\.rect)
            await MainActor.run { self.add(rects, label: "text lines") }
        }
    }

    func findMatches() {
        let image = preview, query = search
        Task.detached(priority: .userInitiated) {
            let rects = Redactor.matches(of: query, in: image)
            await MainActor.run { self.add(rects, label: "matches for “\(query)”") }
        }
    }
}

final class RedactCanvasView: NSView {
    weak var model: RedactModel?
    private var start: CGPoint?
    private var creating: CGRect?
    private var moving: (index: Int, original: CGRect, resize: Bool)?
    private var live: [Redaction]?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var fit: FitGeometry { FitGeometry(imageSize: model?.fullSize ?? .zero, viewSize: bounds.size) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        guard let model, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let image = model.rendered ?? model.preview
        let r = fit.rect
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
        for region in live ?? model.regions {
            let v = fit.toView(region.rect)
            let path = NSBezierPath(rect: v)
            path.lineWidth = region.id == model.selected ? 2 : 1
            (region.id == model.selected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.7)).setStroke()
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.stroke()
            if region.id == model.selected {
                NSColor.controlAccentColor.setFill()
                NSRect(x: v.maxX - 5, y: v.maxY - 5, width: 10, height: 10).fill()
            }
        }
        if let creating {
            let path = NSBezierPath(rect: fit.toView(creating))
            path.lineWidth = 1.5
            NSColor.white.setStroke()
            path.stroke()
        }
    }

    private func point(_ e: NSEvent) -> CGPoint { fit.toImage(convert(e.locationInWindow, from: nil)) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model else { return }
        let p = point(event)
        start = p
        let handle = 12 / max(fit.scale, 0.01)
        if let i = model.regions.lastIndex(where: { $0.rect.insetBy(dx: -handle, dy: -handle).contains(p) }) {
            let r = model.regions[i].rect
            let nearCorner = abs(p.x - r.maxX) < handle && abs(p.y - r.maxY) < handle
            model.selected = model.regions[i].id
            moving = (i, r, nearCorner)
        } else {
            model.selected = nil
            creating = CGRect(origin: p, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let start else { return }
        let p = point(event)
        if let moving {
            var list = model.regions
            if moving.resize {
                list[moving.index].rect = CGRect(x: moving.original.minX, y: moving.original.minY,
                                                 width: max(4, p.x - moving.original.minX), height: max(4, p.y - moving.original.minY))
            } else {
                list[moving.index].rect = moving.original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            }
            live = list
        } else {
            creating = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        if let creating, creating.width > 4, creating.height > 4 {
            let region = Redaction(rect: creating, style: model.style)
            model.commit(model.regions + [region])
            model.selected = region.id
        } else if let live {
            model.commit(live)
        }
        creating = nil
        live = nil
        moving = nil
        start = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            model?.deleteSelected()
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }
}

struct RedactCanvas: NSViewRepresentable {
    @ObservedObject var model: RedactModel

    func makeNSView(context: Context) -> RedactCanvasView {
        let view = RedactCanvasView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Picture. Drag to cover an area.")
        view.model = model
        return view
    }

    func updateNSView(_ view: RedactCanvasView, context: Context) {
        _ = (model.regions.count, model.rendered)
        view.needsDisplay = true
    }
}

struct RedactEditor: View {
    let item: InputItem
    let close: () -> Void
    @StateObject private var model: RedactModel

    init(item: InputItem, preview: PreviewLoader.Preview, regions: [Redaction] = [], close: @escaping () -> Void) {
        self.item = item
        self.close = close
        let model = RedactModel(preview: preview.image, fullSize: preview.fullSize)
        if !regions.isEmpty { model.regions = regions }
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $model.style) {
                    Text("Blur").tag(Redaction.Style.blur)
                    Text("Pixelate").tag(Redaction.Style.pixelate)
                    Text("Solid").tag(Redaction.Style.solid)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                .onChange(of: model.style) { _, style in
                    if let id = model.selected, let i = model.regions.firstIndex(where: { $0.id == id }) {
                        var list = model.regions
                        list[i].style = style
                        model.commit(list)
                    }
                }
                Button("Find Faces") { model.findFaces() }
                Button("Find Text") { model.findText() }
                TextField("Hide words…", text: $model.search)
                    .frame(width: 140)
                    .onSubmit { model.findMatches() }
                Spacer()
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").accessibilityLabel("Undo") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                Button { model.deleteSelected() } label: { Image(systemName: "trash").accessibilityLabel("Delete") }
                    .disabled(model.selected == nil)
            }
            .padding(10)
            RedactCanvas(model: model)
            EditorBottomBar(note: model.status.isEmpty ? "Drag to cover an area · metadata is removed on save" : model.status,
                            action: "Save", enabled: !model.regions.isEmpty, cancel: close) {
                ToolUI.export(.redact, items: [item], options: .redact(model.regions))
                close()
            }
        }
    }
}
