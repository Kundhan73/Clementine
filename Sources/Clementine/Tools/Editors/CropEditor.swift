import AppKit
import ClementineCore
import SwiftUI

/// Aspect choices shared by the image and video crop editors.
enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free", original = "Original", square = "1:1", r4x3 = "4:3", r3x2 = "3:2", r16x9 = "16:9",
         r9x16 = "9:16", r4x5 = "4:5"
    var id: String { rawValue }

    func ratio(original size: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return size.width / max(1, size.height)
        case .square: return 1
        case .r4x3: return 4.0 / 3.0
        case .r3x2: return 3.0 / 2.0
        case .r16x9: return 16.0 / 9.0
        case .r9x16: return 9.0 / 16.0
        case .r4x5: return 4.0 / 5.0
        }
    }
}

/// The crop rectangle with handles; works in image pixels (top-left origin).
struct CropOverlay: View {
    @Binding var crop: CGRect
    let geometry: FitGeometry
    let aspect: CGFloat?
    @State private var startRect: CGRect?

    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, body }

    var body: some View {
        let r = geometry.toView(crop)
        ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Path { p in
                p.addRect(geometry.rect)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            // Rule of thirds.
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
            .allowsHitTesting(false)
            Rectangle()
                .path(in: r)
                .stroke(Color.white, lineWidth: 1.5)
                .allowsHitTesting(false)
            // Move by dragging inside.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: max(1, r.width), height: max(1, r.height))
                .offset(x: r.minX, y: r.minY)
                .gesture(drag(.body))
                .onHover { inside in if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() } }
            ForEach(handles, id: \.self) { handle in
                let p = point(for: handle, in: r)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(radius: 1)
                    .offset(x: p.x - 6, y: p.y - 6)
                    .gesture(drag(handle))
            }
        }
    }

    private var handles: [Handle] {
        aspect == nil ? Handle.allCases.filter { $0 != .body } : [.topLeft, .topRight, .bottomRight, .bottomLeft]
    }

    private func point(for h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        case .body: return CGPoint(x: r.midX, y: r.midY)
        }
    }

    private func drag(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = startRect ?? crop
                if startRect == nil { startRect = crop }
                let dx = value.translation.width / geometry.scale, dy = value.translation.height / geometry.scale
                crop = adjusted(start, handle: handle, dx: dx, dy: dy)
            }
            .onEnded { _ in startRect = nil }
    }

    /// New rect for a handle drag, kept inside the image and above a minimum size.
    func adjusted(_ s: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let bounds = CGRect(origin: .zero, size: geometry.imageSize)
        let minSide: CGFloat = 16
        if handle == .body {
            var r = s.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
            r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
            return r
        }
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        switch handle {
        case .topLeft: minX += dx; minY += dy
        case .top: minY += dy
        case .topRight: maxX += dx; minY += dy
        case .right: maxX += dx
        case .bottomRight: maxX += dx; maxY += dy
        case .bottom: maxY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .left: minX += dx
        case .body: break
        }
        minX = max(0, min(minX, maxX - minSide)); maxX = min(bounds.width, max(maxX, minX + minSide))
        minY = max(0, min(minY, maxY - minSide)); maxY = min(bounds.height, max(maxY, minY + minSide))
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let aspect {
            // Keep the ratio, anchored at the opposite corner.
            var w = r.width, h = w / aspect
            if h > r.height { h = r.height; w = h * aspect }
            switch handle {
            case .topLeft: r = CGRect(x: s.maxX - w, y: s.maxY - h, width: w, height: h)
            case .topRight: r = CGRect(x: s.minX, y: s.maxY - h, width: w, height: h)
            case .bottomLeft: r = CGRect(x: s.maxX - w, y: s.minY, width: w, height: h)
            default: r = CGRect(x: s.minX, y: s.minY, width: w, height: h)
            }
            r = r.intersection(bounds)
        }
        return r
    }
}

struct CropEditor: View {
    let item: InputItem
    let preview: PreviewLoader.Preview
    let close: () -> Void
    @State private var crop: CGRect
    @State private var aspect: CropAspect = .free

    init(item: InputItem, preview: PreviewLoader.Preview, close: @escaping () -> Void) {
        self.item = item
        self.preview = preview
        self.close = close
        _crop = State(initialValue: CGRect(origin: .zero, size: preview.fullSize).insetBy(dx: preview.fullSize.width * 0.05,
                                                                                            dy: preview.fullSize.height * 0.05))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Aspect", selection: $aspect) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                .onChange(of: aspect) { _, new in
                    if let ratio = new.ratio(original: preview.fullSize) {
                        crop = ImageCrop.centred(aspect: ratio, in: preview.fullSize)
                    }
                }
                Spacer()
                PixelField(title: "X", value: binding(\.origin.x))
                PixelField(title: "Y", value: binding(\.origin.y))
                PixelField(title: "W", value: binding(\.size.width))
                PixelField(title: "H", value: binding(\.size.height))
                Button("Reset") { crop = CGRect(origin: .zero, size: preview.fullSize) }
            }
            .padding(10)
            GeometryReader { geo in
                let fit = FitGeometry(imageSize: preview.fullSize, viewSize: geo.size)
                ZStack(alignment: .topLeading) {
                    CanvasImage(image: preview.image)
                        .frame(width: fit.rect.width, height: fit.rect.height)
                        .offset(x: fit.rect.minX, y: fit.rect.minY)
                    CropOverlay(crop: $crop, geometry: fit, aspect: aspect.ratio(original: preview.fullSize))
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .background(Color.black.opacity(0.85))
            EditorBottomBar(note: "\(Int(crop.width)) × \(Int(crop.height)) px", action: "Crop", cancel: close) {
                ToolUI.export(.crop, items: [item], options: .crop(crop.integral))
                close()
            }
        }
    }

    private func binding(_ key: WritableKeyPath<CGRect, CGFloat>) -> Binding<Int> {
        Binding(get: { Int(crop[keyPath: key].rounded()) }, set: { v in
            var r = crop
            r[keyPath: key] = CGFloat(max(0, v))
            let clipped = r.intersection(CGRect(origin: .zero, size: preview.fullSize))
            if !clipped.isNull, clipped.width >= 1, clipped.height >= 1 { crop = clipped }
        })
    }
}

/// Small labelled integer field.
struct PixelField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary).font(.caption)
            TextField("", value: $value, format: .number.grouping(.never))
                .frame(width: 58)
                .multilineTextAlignment(.trailing)
        }
    }
}
