import AppKit
import ClementineCore
import ImageIO
import SwiftUI

/// A resizable editor window hosting a SwiftUI editor. Kept alive while open
/// and released (with its images) when closed.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private static var open: [EditorWindowController] = []
    let window: NSWindow
    private let hosting = NSHostingController(rootView: AnyView(EmptyView()))

    init(title: String, size: NSSize, minSize: NSSize = NSSize(width: 640, height: 460)) {
        // The window decides the size; editors fill whatever they're given.
        hosting.sizingOptions = []
        window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(size)
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init()
        window.delegate = self
    }

    func setContent<V: View>(_ view: V) {
        hosting.rootView = AnyView(view)
    }

    func show() {
        Self.open.append(self)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hosting.rootView = AnyView(EmptyView())
                Self.open.removeAll { $0 === self }
            }
        }
    }
}

/// Downsampled, orientation-corrected previews (full resolution only on export).
enum PreviewLoader {
    struct Preview {
        let image: CGImage
        /// Full-resolution size, orientation applied.
        let fullSize: CGSize
    }

    static func load(_ item: InputItem, maxPixel: Int = 1800) -> Preview? {
        if item.format == .svg {
            guard let decoded = try? ImageCodec.decode(item.url, format: .svg) else { return nil }
            return downsized(decoded.image, maxPixel: maxPixel)
        }
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        let o = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
        let full = o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, max(w, h)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return Preview(image: image, fullSize: full)
    }

    static func downsized(_ image: CGImage, maxPixel: Int) -> Preview {
        let full = CGSize(width: image.width, height: image.height)
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return Preview(image: image, fullSize: full) }
        let s = Double(maxPixel) / Double(longest)
        let small = (try? ImageCodec.scaled(image, width: Int(Double(image.width) * s), height: Int(Double(image.height) * s))) ?? image
        return Preview(image: small, fullSize: full)
    }
}

/// Maps between view points and image pixels for an aspect-fit image.
struct FitGeometry {
    let imageSize: CGSize
    let viewSize: CGSize
    var inset: CGFloat = 16

    var rect: CGRect {
        let avail = CGRect(origin: .zero, size: viewSize).insetBy(dx: inset, dy: inset)
        guard imageSize.width > 0, imageSize.height > 0, avail.width > 0, avail.height > 0 else { return .zero }
        let s = min(avail.width / imageSize.width, avail.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
    }

    /// View points per image pixel.
    var scale: CGFloat { imageSize.width > 0 ? rect.width / imageSize.width : 1 }

    /// Top-left-origin view point → image pixel (clamped).
    func toImage(_ p: CGPoint, clamp: Bool = true) -> CGPoint {
        let r = rect
        var x = (p.x - r.minX) / scale, y = (p.y - r.minY) / scale
        if clamp {
            x = min(max(0, x), imageSize.width)
            y = min(max(0, y), imageSize.height)
        }
        return CGPoint(x: x, y: y)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale)
    }

    func toView(_ r: CGRect) -> CGRect {
        CGRect(origin: toView(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale))
    }
}

/// Bottom bar with a note and Cancel / primary buttons (⎋ / ⏎ / ⌘S).
struct EditorBottomBar: View {
    var note: String = ""
    let action: String
    var enabled = true
    let cancel: () -> Void
    let commit: () -> Void

    var body: some View {
        HStack {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(action, action: commit)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled)
            // ⌘S also saves.
            Button("", action: commit)
                .keyboardShortcut("s", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .disabled(!enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Swatches used by Annotate, Background and Collage.
struct Swatches: View {
    let colors: [RGBA]
    @Binding var selection: RGBA

    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { c in
                Circle()
                    .fill(Color(nsColor: c.nsColor))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.primary.opacity(c == selection ? 0.9 : 0.2), lineWidth: c == selection ? 2 : 1))
                    .onTapGesture { selection = c }
            }
        }
    }

    static let standard: [RGBA] = [.red, .orange, .yellow, .green, .blue, RGBA(0.55, 0.3, 0.85), .black, .white]
}

/// Displays a CGImage at a given rect (SwiftUI).
struct CanvasImage: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
    }
}

/// Renders work off the main thread with simple coalescing: only the latest
/// request's result is delivered.
@MainActor
final class RenderScheduler {
    private var generation = 0
    private let queue = DispatchQueue(label: "Clementine.render", qos: .userInitiated)

    func schedule(_ work: @escaping @Sendable () -> CGImage?, deliver: @escaping @MainActor (CGImage?) -> Void) {
        generation += 1
        let token = generation
        queue.async {
            let image = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard token == self.generation else { return }
                    deliver(image)
                }
            }
        }
    }
}

extension ToolUI {
    /// Opens the editor for an editor tool; returns false if there isn't one.
    static func openEditor(_ tool: Tool, items: [InputItem]) -> Bool {
        guard let first = items.first else { return false }
        switch tool {
        case .crop, .adjust, .annotate, .redact, .background:
            guard first.kind == .image, let preview = PreviewLoader.load(first) else { return false }
            let size = NSSize(width: 980, height: 700)
            let controller = EditorWindowController(title: "\(tool.displayName) — \(first.url.lastPathComponent)", size: size)
            let close: () -> Void = { [weak controller] in controller?.close() }
            switch tool {
            case .crop: controller.setContent(CropEditor(item: first, preview: preview, close: close))
            case .adjust: controller.setContent(AdjustEditor(item: first, preview: preview, close: close))
            case .annotate: controller.setContent(AnnotateEditor(item: first, preview: preview, close: close))
            case .redact: controller.setContent(RedactEditor(item: first, preview: preview, close: close))
            default: controller.setContent(BackgroundEditor(item: first, preview: preview, close: close))
            }
            controller.show()
            return true
        case .collage:
            let controller = EditorWindowController(title: "Collage", size: NSSize(width: 1000, height: 700))
            controller.setContent(CollageEditor(items: items, close: { [weak controller] in controller?.close() }))
            controller.show()
            return true
        case .metadata:
            let controller = EditorWindowController(title: "Metadata — \(first.url.lastPathComponent)",
                                                    size: NSSize(width: 720, height: 620), minSize: NSSize(width: 520, height: 400))
            controller.setContent(MetadataEditor(item: first, close: { [weak controller] in controller?.close() }))
            controller.show()
            return true
        case .organizePDF:
            guard first.kind == .pdf else { return false }
            let controller = EditorWindowController(title: "Organize — \(first.url.lastPathComponent)", size: NSSize(width: 980, height: 720))
            controller.setContent(OrganizePDFEditor(item: first, close: { [weak controller] in controller?.close() }))
            controller.show()
            return true
        default:
            return false
        }
    }

    /// Submits an editor's result as a normal job (HUD, naming, Recent…).
    static func export(_ tool: Tool, items: [InputItem], options: ToolOptions) {
        JobCenter.shared.submit(JobCenter.requests(for: .tool(tool), items: items, outputDirectory: nil, options: options))
    }
}
