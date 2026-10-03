import AppKit
import ClementineCore
import SwiftUI

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, line, arrow, rectangle, ellipse, text, marker
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .marker: return "1.circle.fill"
        }
    }

    var kind: Annotation.Kind? { Annotation.Kind(rawValue: rawValue) }
}

/// Undoable list of annotations plus the current tool settings.
@MainActor
final class AnnotateModel: ObservableObject {
    @Published var annotations: [Annotation] = []
    @Published var tool: AnnotationTool = .arrow
    @Published var color: RGBA = .red
    @Published var size: Double = 4
    @Published var filled = false
    @Published var selected: UUID?
    @Published var pendingTextAt: CGPoint?
    @Published var draftText = ""
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    let imageSize: CGSize

    init(imageSize: CGSize) { self.imageSize = imageSize }

    /// Stroke width in image pixels for the "Size" slider.
    var lineWidth: Double { size * max(1.5, Double(max(imageSize.width, imageSize.height)) / 600) }
    var fontSize: Double { max(14, lineWidth * 6) }

    func commit(_ new: [Annotation]) {
        guard new != annotations else { return }
        undoStack.append(annotations)
        redoStack.removeAll()
        annotations = new
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = last
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    func deleteSelected() {
        guard let selected else { return }
        commit(annotations.filter { $0.id != selected })
        self.selected = nil
    }

    func addText() {
        guard let p = pendingTextAt, !draftText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var a = Annotation(kind: .text, points: [p], color: color, lineWidth: lineWidth)
        a.text = draftText
        a.fontSize = fontSize
        commit(annotations + [a])
        draftText = ""
        pendingTextAt = nil
    }

    var nextMarkerNumber: Int { (annotations.filter { $0.kind == .marker }.map(\.number).max() ?? 0) + 1 }
}

final class AnnotationCanvasView: NSView {
    weak var model: AnnotateModel?
    var preview: CGImage?
    var imageSize: CGSize = .zero
    private var drawing: Annotation?
    private var dragStart: CGPoint?
    private var moving: (index: Int, original: Annotation)?
    private var live: [Annotation]?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var fit: FitGeometry { FitGeometry(imageSize: imageSize, viewSize: bounds.size) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext, let preview, let model else { return }
        let r = fit.rect
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(preview, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: fit.scale, y: fit.scale)
        AnnotationRenderer.draw((live ?? model.annotations) + (drawing.map { [$0] } ?? []), in: ctx)
        ctx.restoreGState()
        if let id = model.selected, let a = (live ?? model.annotations).first(where: { $0.id == id }) {
            let path = NSBezierPath(rect: fit.toView(a.bounds).insetBy(dx: -5, dy: -5))
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        fit.toImage(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model else { return }
        let p = imagePoint(event)
        switch model.tool {
        case .select:
            let hit = model.annotations.lastIndex { $0.bounds.insetBy(dx: -10, dy: -10).contains(p) }
            model.selected = hit.map { model.annotations[$0].id }
            if let hit { moving = (hit, model.annotations[hit]) }
            dragStart = p
        case .text:
            model.pendingTextAt = p
        case .marker:
            var m = Annotation(kind: .marker, points: [p], color: model.color, lineWidth: model.lineWidth)
            m.number = model.nextMarkerNumber
            m.fontSize = model.fontSize
            model.commit(model.annotations + [m])
        default:
            guard let kind = model.tool.kind else { return }
            let width = kind == .highlighter ? model.lineWidth * 4 : model.lineWidth
            var a = Annotation(kind: kind, points: kind == .pen || kind == .highlighter ? [p] : [p, p],
                               color: model.color, lineWidth: width)
            a.filled = model.filled
            drawing = a
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        var p = imagePoint(event)
        if model.tool == .select, let start = dragStart, let moving {
            let dx = p.x - start.x, dy = p.y - start.y
            var moved = moving.original
            moved.points = moved.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            var list = model.annotations
            list[moving.index] = moved
            live = list
        } else if var d = drawing {
            if d.kind == .pen || d.kind == .highlighter {
                d.points.append(p)
            } else {
                if event.modifierFlags.contains(.shift), let first = d.points.first {
                    p = constrained(from: first, to: p, square: d.kind == .rectangle || d.kind == .ellipse)
                }
                d.points[d.points.count - 1] = p
            }
            drawing = d
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        if let d = drawing {
            drawing = nil
            let b = d.bounds
            if d.kind == .pen || d.kind == .highlighter || max(b.width, b.height) > d.lineWidth * 2 {
                model.commit(model.annotations + [d])
            }
        } else if let live {
            model.commit(live)
        }
        live = nil
        moving = nil
        dragStart = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // delete / forward delete
            model?.deleteSelected()
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }

    /// 45° lines and squares/circles with Shift.
    private func constrained(from a: CGPoint, to b: CGPoint, square: Bool) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        if square {
            let s = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -s : s), y: a.y + (dy < 0 ? -s : s))
        }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(dx, dy)
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }
}

struct AnnotationCanvas: NSViewRepresentable {
    @ObservedObject var model: AnnotateModel
    let preview: CGImage

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView()
        view.model = model
        view.preview = preview
        view.imageSize = model.imageSize
        return view
    }

    func updateNSView(_ view: AnnotationCanvasView, context: Context) {
        _ = model.annotations.count
        view.needsDisplay = true
    }
}

struct AnnotateEditor: View {
    let item: InputItem
    let preview: PreviewLoader.Preview
    let close: () -> Void
    @StateObject private var model: AnnotateModel

    init(item: InputItem, preview: PreviewLoader.Preview, annotations: [Annotation] = [], close: @escaping () -> Void) {
        self.item = item
        self.preview = preview
        self.close = close
        let model = AnnotateModel(imageSize: preview.fullSize)
        model.annotations = annotations
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("", selection: $model.tool) {
                    ForEach(AnnotationTool.allCases) { tool in
                        Image(systemName: tool.symbol).help(tool.rawValue.capitalized).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
                Swatches(colors: Swatches.standard, selection: $model.color)
                HStack(spacing: 4) {
                    Image(systemName: "lineweight").foregroundStyle(.secondary)
                    Slider(value: $model.size, in: 1...12).frame(width: 90)
                }
                Toggle("Fill", isOn: $model.filled).toggleStyle(.checkbox)
                Spacer()
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
                Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                    .disabled(model.selected == nil)
            }
            .padding(10)
            AnnotationCanvas(model: model, preview: preview.image)
            EditorBottomBar(note: "Select to move · Delete removes · Shift keeps lines straight",
                            action: "Save", enabled: !model.annotations.isEmpty, cancel: close) {
                ToolUI.export(.annotate, items: [item], options: .annotate(model.annotations))
                close()
            }
        }
        .alert("Add text", isPresented: Binding(get: { model.pendingTextAt != nil }, set: { if !$0 { model.pendingTextAt = nil } })) {
            TextField("Text", text: $model.draftText)
            Button("Add") { model.addText() }
            Button("Cancel", role: .cancel) { model.pendingTextAt = nil }
        }
    }
}
