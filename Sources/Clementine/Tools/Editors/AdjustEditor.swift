import AppKit
import ClementineCore
import SwiftUI

@MainActor
final class AdjustModel: ObservableObject {
    @Published var params = AdjustParameters() { didSet { render() } }
    @Published var rendered: CGImage?
    @Published var showOriginal = false
    let preview: CGImage
    private let scheduler = RenderScheduler()

    init(preview: CGImage) {
        self.preview = preview
    }

    func render() {
        let params = self.params
        let image = preview
        guard !params.isIdentity else { rendered = nil; return }
        scheduler.schedule({ try? ImageAdjuster.render(params, image: image) }) { [weak self] result in
            self?.rendered = result
        }
    }
}

struct AdjustEditor: View {
    let item: InputItem
    let preview: PreviewLoader.Preview
    let close: () -> Void
    @StateObject private var model: AdjustModel

    init(item: InputItem, preview: PreviewLoader.Preview, close: @escaping () -> Void) {
        self.item = item
        self.preview = preview
        self.close = close
        _model = StateObject(wrappedValue: AdjustModel(preview: preview.image))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GeometryReader { geo in
                    let fit = FitGeometry(imageSize: preview.fullSize, viewSize: geo.size)
                    CanvasImage(image: model.showOriginal ? preview.image : (model.rendered ?? preview.image))
                        .frame(width: fit.rect.width, height: fit.rect.height)
                        .position(x: fit.rect.midX, y: fit.rect.midY)
                }
                .background(Color.black.opacity(0.85))
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        HoldButton(title: "Show Original", pressed: $model.showOriginal)
                        Spacer()
                        Button("Reset All") { model.params = AdjustParameters() }
                            .disabled(model.params.isIdentity)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(AdjustParameters.fields.enumerated()), id: \.offset) { _, field in
                                AdjustSlider(title: field.title, range: field.range,
                                             value: Binding(get: { model.params[keyPath: field.key] },
                                                            set: { model.params[keyPath: field.key] = $0 }))
                            }
                        }
                        .padding(14)
                    }
                }
                .frame(width: 270)
            }
            EditorBottomBar(note: "Double-click a slider's name to reset it", action: "Save", enabled: !model.params.isIdentity,
                            cancel: close) {
                ToolUI.export(.adjust, items: [item], options: .adjust(model.params))
                close()
            }
        }
    }
}

struct AdjustSlider: View {
    let title: String
    let range: ClosedRange<Double>
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.callout)
                    .onTapGesture(count: 2) { value = 0 }
                    .help("Double-click to reset")
                Spacer()
                Text(String(format: value == 0 ? "0" : "%+.2f", value))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

/// A button that is "on" only while held (before/after comparison).
struct HoldButton: View {
    let title: String
    @Binding var pressed: Bool

    var body: some View {
        Text(title)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(pressed ? 0.2 : 0.08)))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false })
    }
}
