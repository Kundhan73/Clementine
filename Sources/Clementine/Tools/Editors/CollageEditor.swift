import AppKit
import ClementineCore
import SwiftUI

@MainActor
final class CollageModel: ObservableObject {
    @Published var items: [InputItem] { didSet { render() } }
    @Published var style = CollageStyle() { didSet { render() } }
    @Published var rendered: CGImage?
    private var thumbnails: [URL: CGImage] = [:]
    private let scheduler = RenderScheduler()

    init(items: [InputItem]) {
        self.items = items
        for item in items {
            if let p = PreviewLoader.load(item, maxPixel: 700) { thumbnails[item.url] = p.image }
        }
        render()
    }

    func render() {
        var previewStyle = style
        // Same proportions at preview size.
        let factor = 900.0 / Double(style.outputWidth)
        previewStyle.outputWidth = 900
        previewStyle.spacing *= factor
        previewStyle.padding *= factor
        previewStyle.cornerRadius *= factor
        let images = items.compactMap { thumbnails[$0.url] }
        scheduler.schedule({ try? Collage.render(images, style: previewStyle) }) { [weak self] in self?.rendered = $0 }
    }
}

struct CollageEditor: View {
    let close: () -> Void
    @StateObject private var model: CollageModel

    init(items: [InputItem], close: @escaping () -> Void) {
        self.close = close
        _model = StateObject(wrappedValue: CollageModel(items: items))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GeometryReader { geo in
                    if let image = model.rendered {
                        let fit = FitGeometry(imageSize: CGSize(width: image.width, height: image.height), viewSize: geo.size)
                        CanvasImage(image: image)
                            .frame(width: fit.rect.width, height: fit.rect.height)
                            .shadow(radius: 6)
                            .position(x: fit.rect.midX, y: fit.rect.midY)
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                Form {
                    Section("Layout") {
                        Picker("", selection: $model.style.layout) {
                            Text("Grid").tag(CollageStyle.Layout.grid)
                            Text("Row").tag(CollageStyle.Layout.row)
                            Text("Column").tag(CollageStyle.Layout.column)
                            Text("Featured").tag(CollageStyle.Layout.featured)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        LabeledSlider(title: "Spacing", value: $model.style.spacing, range: 0...80)
                        LabeledSlider(title: "Padding", value: $model.style.padding, range: 0...160)
                        LabeledSlider(title: "Corners", value: $model.style.cornerRadius, range: 0...80)
                        Picker("Width", selection: $model.style.outputWidth) {
                            Text("1200 px").tag(1200)
                            Text("2400 px").tag(2400)
                            Text("3600 px").tag(3600)
                        }
                        Swatches(colors: [.white, RGBA(0.96, 0.94, 0.9), RGBA(0.12, 0.12, 0.14), .black, .orange, .blue],
                                 selection: $model.style.background)
                    }
                    Section("Order (drag to reorder)") {
                        OrderList(items: $model.items)
                    }
                }
                .formStyle(.grouped)
                .frame(width: 300)
            }
            EditorBottomBar(note: "\(model.items.count) images → Collage.png", action: "Save", cancel: close) {
                ToolUI.export(.collage, items: model.items, options: .collage(model.style))
                close()
            }
        }
    }
}
