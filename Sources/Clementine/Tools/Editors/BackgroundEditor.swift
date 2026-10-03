import AppKit
import ClementineCore
import SwiftUI

@MainActor
final class BackgroundModel: ObservableObject {
    @Published var style = FrameStyle() { didSet { render() } }
    @Published var rendered: CGImage?
    @Published var error: String?
    let preview: CGImage
    private let scheduler = RenderScheduler()

    init(preview: CGImage) {
        self.preview = preview
        render()
    }

    func render() {
        let style = self.style
        let image = preview
        scheduler.schedule({ try? Framer.render(image, style: style) }) { [weak self] result in
            self?.rendered = result
            self?.error = result == nil && style.removeBackground ? "No subject was found to cut out." : nil
        }
    }

    static let fills: [(String, FrameStyle.Fill)] = [
        ("Sunset", .gradient(RGBA(1.0, 0.62, 0.25), RGBA(0.93, 0.33, 0.45))),
        ("Ocean", .gradient(RGBA(0.2, 0.55, 0.95), RGBA(0.35, 0.85, 0.8))),
        ("Grape", .gradient(RGBA(0.55, 0.35, 0.95), RGBA(0.95, 0.45, 0.75))),
        ("Mint", .gradient(RGBA(0.6, 0.92, 0.7), RGBA(0.2, 0.6, 0.55))),
        ("Night", .gradient(RGBA(0.12, 0.14, 0.22), RGBA(0.32, 0.25, 0.45))),
        ("White", .solid(.white)),
        ("Paper", .solid(RGBA(0.96, 0.94, 0.9))),
        ("Black", .solid(.black)),
        ("Blurred", .blurredSelf),
        ("None", .none),
    ]
}

struct BackgroundEditor: View {
    let item: InputItem
    let preview: PreviewLoader.Preview
    let close: () -> Void
    @StateObject private var model: BackgroundModel

    init(item: InputItem, preview: PreviewLoader.Preview, close: @escaping () -> Void) {
        self.item = item
        self.preview = preview
        self.close = close
        _model = StateObject(wrappedValue: BackgroundModel(preview: preview.image))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GeometryReader { geo in
                    if let image = model.rendered {
                        let fit = FitGeometry(imageSize: CGSize(width: image.width, height: image.height), viewSize: geo.size)
                        ZStack {
                            Checkerboard()
                                .frame(width: fit.rect.width, height: fit.rect.height)
                            CanvasImage(image: image)
                                .frame(width: fit.rect.width, height: fit.rect.height)
                        }
                        .position(x: fit.rect.midX, y: fit.rect.midY)
                    } else {
                        ProgressView().position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                Form {
                    Section("Background") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 5), spacing: 8) {
                            ForEach(Array(BackgroundModel.fills.enumerated()), id: \.offset) { _, entry in
                                FillSwatch(fill: entry.1, selected: model.style.fill == entry.1)
                                    .help(entry.0)
                                    .onTapGesture { model.style.fill = entry.1 }
                            }
                        }
                        Toggle("Cut out the subject", isOn: $model.style.removeBackground)
                            .help("Removes the photo's own background (people, pets, objects)")
                        if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
                    }
                    Section("Frame") {
                        LabeledSlider(title: "Padding", value: $model.style.padding, range: 0...0.4)
                        LabeledSlider(title: "Corners", value: $model.style.cornerRadius, range: 0...0.25)
                        LabeledSlider(title: "Shadow", value: $model.style.shadow, range: 0...1)
                        Picker("Shape", selection: $model.style.aspect) {
                            Text("Original").tag(FrameStyle.Aspect.original)
                            Text("Square").tag(FrameStyle.Aspect.square)
                            Text("4:5 portrait").tag(FrameStyle.Aspect.portrait4x5)
                            Text("16:9 wide").tag(FrameStyle.Aspect.landscape16x9)
                            Text("9:16 story").tag(FrameStyle.Aspect.story9x16)
                            Text("3:2 photo").tag(FrameStyle.Aspect.photo3x2)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 290)
            }
            EditorBottomBar(note: "Saved as PNG", action: "Save", cancel: close) {
                ToolUI.export(.background, items: [item], options: .background(model.style))
                close()
            }
        }
    }
}

struct FillSwatch: View {
    let fill: FrameStyle.Fill
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(style)
            .frame(width: 36, height: 36)
            .overlay {
                switch fill {
                case .none: Image(systemName: "nosign").foregroundStyle(.secondary)
                case .blurredSelf: Image(systemName: "drop.halffull").foregroundStyle(.white)
                default: EmptyView()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                                             lineWidth: selected ? 3 : 1))
    }

    private var style: AnyShapeStyle {
        switch fill {
        case .none: return AnyShapeStyle(Color.primary.opacity(0.05))
        case .solid(let c): return AnyShapeStyle(Color(nsColor: c.nsColor))
        case .gradient(let a, let b):
            return AnyShapeStyle(LinearGradient(colors: [Color(nsColor: a.nsColor), Color(nsColor: b.nsColor)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .blurredSelf: return AnyShapeStyle(Color.gray)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range)
        }
    }
}

/// Transparency checkerboard behind PNG previews.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.25)))
                }
            }
        }
    }
}
