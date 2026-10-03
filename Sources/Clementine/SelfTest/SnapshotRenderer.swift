import AppKit
import ClementineCore
import CoreText
import ImageIO
import SwiftUI

/// `--render-snapshots <dir>`: renders UI pieces offscreen to PNG files so
/// they can be reviewed without a Mac (CI publishes them to the ci-snapshots
/// pre-release).
@MainActor
enum SnapshotRenderer {
    private static var failures = 0
    private static var directory = URL(fileURLWithPath: "snapshots")

    static func run(into dir: URL, media: Bool = false) -> Int32 {
        directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Preferences.registerDefaults()
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

        if media {
            for (suffix, name) in appearances {
                mediaEditors(suffix: suffix, appearance: NSAppearance(named: name)!)
            }
            print("snapshots: \(failures) failure(s)")
            return failures == 0 ? 0 : 1
        }
        for (suffix, name) in appearances {
            let appearance = NSAppearance(named: name)!
            menuBarIcon(suffix: suffix, appearance: appearance)
            wheels(suffix: suffix, appearance: appearance)
            hud(suffix: suffix, appearance: appearance)
            windowContent("settings-general-\(suffix)", SettingsWindowController.makeView(tab: .general), appearance)
            windowContent("settings-output-\(suffix)", SettingsWindowController.makeView(tab: .output), appearance)
            windowContent("settings-quality-\(suffix)", SettingsWindowController.makeView(tab: .quality), appearance)
            windowContent("settings-wheel-\(suffix)", SettingsWindowController.makeView(tab: .wheel), appearance)
            windowContent("settings-about-\(suffix)", SettingsWindowController.makeView(tab: .about), appearance)
            windowContent("onboarding-\(suffix)", OnboardingWindowController.makeView(), appearance)
            dialogs(suffix: suffix, appearance: appearance)
            editors(suffix: suffix, appearance: appearance)
        }
        if let icon = NSApp.applicationIconImage {
            save("app-icon", image: icon, size: NSSize(width: 256, height: 256))
        }
        print("snapshots: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    // MARK: Pieces

    private static func menuBarIcon(suffix: String, appearance: NSAppearance) {
        let bg = appearance.name == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            bg.setFill()
            rect.fill()
            let template = MenuBarIcon.make()
            let tinted = NSImage(size: template.size, flipped: false) { r in
                template.draw(in: r)
                (appearance.name == .darkAqua ? NSColor.white : NSColor.black).set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
            return true
        }
        save("menubar-icon-\(suffix)", image: image, size: NSSize(width: 144, height: 144))
    }

    private static func sampleItems(_ names: [String]) -> [InputItem] {
        names.map { InputItem(url: URL(fileURLWithPath: "/tmp/\($0)"), isDirectory: !$0.contains(".")) }
    }

    private static func wheels(suffix: String, appearance: NSAppearance) {
        let cases: [(String, [String], WheelMode, Int?)] = [
            ("wheel-convert-image", ["photo.heic"], .convert, nil),
            ("wheel-convert-image-hover", ["photo.heic"], .convert, 1),
            ("wheel-convert-multi", ["a.jpg", "b.png", "c.heic"], .convert, nil),
            ("wheel-convert-video", ["clip.mov"], .convert, 2),
            ("wheel-convert-audio", ["song.wav"], .convert, nil),
            ("wheel-convert-pdf", ["report.pdf"], .convert, nil),
            ("wheel-convert-folder", ["Folder"], .convert, nil),
            ("wheel-tools-image", ["photo.jpg"], .tools, 0),
            ("wheel-tools-video", ["clip.mp4"], .tools, 3),
            ("wheel-tools-pdfs", ["a.pdf", "b.pdf"], .tools, nil),
        ]
        for (name, files, mode, hover) in cases {
            let items = sampleItems(files)
            // Show every chip the matrix allows (not just what this build
            // implements) so layouts can be reviewed ahead of the engines.
            let chips = WheelContent.chips(for: items, mode: mode)
            let scale = WheelSize.medium.scale
            let large = mode == .tools
            let side = WheelLayout(count: chips.count, scale: scale, largeChips: large).canvasSide
            let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            wheel.appearance = appearance
            wheel.solidDisc = true
            wheel.configure(chips: chips, mode: mode, icon: WheelController.icon(for: items), count: items.count,
                            scale: scale, animated: false)
            wheel.setHovered(hover)
            guard let image = wheel.renderImage(scale: 2) else {
                print("snapshot: FAILED \(name)-\(suffix)")
                failures += 1
                continue
            }
            save("\(name)-\(suffix)", image: image, size: NSSize(width: side * 2, height: side * 2))
        }
    }

    private static func hud(suffix: String, appearance: NSAppearance) {
        func job(_ name: String, _ target: Format) -> Job {
            Job(JobRequest(inputs: [InputItem(url: URL(fileURLWithPath: "/tmp/\(name)"), isDirectory: false)],
                           operation: .convert(target)))
        }
        let running = job("Holiday video.mov", .mp4)
        running.setPreviewState(.running, progress: 0.42)
        let done = job("photo.heic", .jpg)
        done.setPreviewState(.succeeded(JobResult(outputs: [URL(fileURLWithPath: "/tmp/photo.jpg")])), progress: 1)
        let failed = job("broken.png", .webp)
        failed.setPreviewState(.failed(JobFailure("This image can't be opened. It may be damaged.", details: "x")))
        let queued = job("scan.tiff", .pdf)

        let rows = [running, done, failed, queued].map { j -> JobRowView in
            let row = JobRowView(job: j)
            row.refresh()
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        let container = RoundedBackground()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        windowContent("hud-\(suffix)", container, appearance)
    }

    private static func dialogs(suffix: String, appearance: NSAppearance) {
        let cases: [(Tool, [String])] = [
            (.compress, ["photo.jpg"]), (.resize, ["photo.jpg"]), (.rotate, ["photo.jpg"]),
            (.createPDF, ["a.jpg", "b.png", "c.pdf"]), (.speed, ["clip.mov"]), (.split, ["report.pdf"]),
            (.join, ["one.mp4", "two.mp4"]), (.extractAudio, ["clip.mov"]), (.normalize, ["podcast.mp3"]),
            (.channels, ["song.wav"]), (.visualizer, ["song.mp3"]),
        ]
        for (tool, files) in cases {
            let view = ToolUI.dialog(for: tool, items: sampleItems(files), run: { _, _ in }, cancel: {})
            windowContent("dialog-\(tool.rawValue)-\(suffix)", NSHostingView(rootView: view), appearance)
        }
    }

    // MARK: Editors

    private struct Samples {
        let photo: InputItem
        let photos: [InputItem]
        let pdf: InputItem
    }

    private static var samples: Samples?

    /// Sample files for the editors, generated once per run.
    private static func makeSamples() -> Samples? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-snapshot-samples")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let skies: [(CGFloat, CGFloat, CGFloat)] = [(0.98, 0.62, 0.3), (0.35, 0.62, 0.95), (0.45, 0.8, 0.55), (0.85, 0.45, 0.8)]
        var photos: [InputItem] = []
        for (i, sky) in skies.enumerated() {
            let size = i == 2 ? CGSize(width: 900, height: 1200) : CGSize(width: 1600, height: 1066)
            let url = dir.appendingPathComponent("Sample \(i + 1).jpg")
            guard writeSamplePhoto(to: url, size: size, sky: sky) else { return nil }
            photos.append(InputItem.inspect(url))
        }
        let pdf = dir.appendingPathComponent("Sample.pdf")
        guard writeSamplePDF(to: pdf, pages: 6) else { return nil }
        return Samples(photo: photos[0], photos: photos, pdf: InputItem.inspect(pdf))
    }

    private static func editors(suffix: String, appearance: NSAppearance) {
        if samples == nil { samples = makeSamples() }
        guard let samples, let preview = PreviewLoader.load(samples.photo) else {
            print("snapshot: FAILED editor samples")
            failures += 1
            return
        }
        let full = preview.fullSize
        func host<V: View>(_ name: String, _ view: V, size: NSSize? = nil) {
            windowContent("editor-\(name)-\(suffix)", NSHostingView(rootView: view), appearance,
                          size: size ?? NSSize(width: 980, height: 680), settle: 1.0)
        }
        host("crop", CropEditor(item: samples.photo, preview: preview, close: {}))
        host("adjust", AdjustEditor(item: samples.photo, preview: preview, close: {}))

        let arrow = Annotation(kind: .arrow, points: [CGPoint(x: full.width * 0.2, y: full.height * 0.75),
                                                      CGPoint(x: full.width * 0.45, y: full.height * 0.45)],
                               color: .red, lineWidth: 10)
        let box = Annotation(kind: .rectangle, points: [CGPoint(x: full.width * 0.55, y: full.height * 0.2),
                                                        CGPoint(x: full.width * 0.85, y: full.height * 0.45)],
                             color: .yellow, lineWidth: 8)
        var label = Annotation(kind: .text, points: [CGPoint(x: full.width * 0.08, y: full.height * 0.08)], color: .white, lineWidth: 6)
        label.text = "Look here"
        label.fontSize = 72
        var marker = Annotation(kind: .marker, points: [CGPoint(x: full.width * 0.7, y: full.height * 0.7)], color: .blue, lineWidth: 6)
        marker.fontSize = 48
        host("annotate", AnnotateEditor(item: samples.photo, preview: preview, annotations: [arrow, box, label, marker], close: {}))

        let regions = [
            Redaction(rect: CGRect(x: full.width * 0.1, y: full.height * 0.15, width: full.width * 0.3, height: full.height * 0.25), style: .blur),
            Redaction(rect: CGRect(x: full.width * 0.6, y: full.height * 0.6, width: full.width * 0.25, height: full.height * 0.2), style: .pixelate),
        ]
        host("redact", RedactEditor(item: samples.photo, preview: preview, regions: regions, close: {}))
        host("background", BackgroundEditor(item: samples.photo, preview: preview, close: {}))
        host("collage", CollageEditor(items: samples.photos, close: {}), size: NSSize(width: 1000, height: 700))
        host("metadata", MetadataEditor(item: samples.photo, close: {}), size: NSSize(width: 720, height: 620))
        host("organize", OrganizePDFEditor(item: samples.pdf, close: {}))
    }

    // MARK: Media editors (bundle with ffmpeg)

    private static var mediaSamples: (video: InputItem, audio: InputItem)?

    /// Runs the bundled ffmpeg synchronously (sample files only).
    private static func ffmpeg(_ args: [String]) -> Bool {
        guard let tool = FFmpegLocator.ffmpeg else { return false }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"] + args
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func makeMediaSamples() -> (video: InputItem, audio: InputItem)? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clementine-snapshot-media")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let video = dir.appendingPathComponent("Holiday.mp4"), audio = dir.appendingPathComponent("Interview.m4a")
        let source = ["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=12",
                      "-f", "lavfi", "-i", "sine=frequency=330:duration=12", "-shortest", "-c:a", "aac_at", "-b:a", "128k"]
        guard ffmpeg(source + ["-c:v", "h264_videotoolbox", "-b:v", "4M", "-allow_sw", "1", "-pix_fmt", "yuv420p", video.path])
            || ffmpeg(source + ["-c:v", "mpeg4", "-q:v", "3", video.path]) else { return nil }
        guard ffmpeg(["-f", "lavfi", "-i", "sine=frequency=220:duration=40", "-af",
                      "volume='0.08+0.7*abs(sin(t*0.9))*abs(sin(t*3.1))':eval=frame", "-c:a", "aac_at", "-b:a", "128k",
                      audio.path]) else { return nil }
        return (InputItem.inspect(video), InputItem.inspect(audio))
    }

    private static func mediaEditors(suffix: String, appearance: NSAppearance) {
        if mediaSamples == nil { mediaSamples = makeMediaSamples() }
        guard let samples = mediaSamples else {
            print("snapshot: FAILED media samples (is ffmpeg in the bundle?)")
            failures += 1
            return
        }
        func host<V: View>(_ name: String, _ view: V, size: NSSize) {
            windowContent("media-\(name)-\(suffix)", NSHostingView(rootView: view), appearance, size: size, settle: 3)
        }
        let videoSize = NSSize(width: 980, height: 720), audioSize = NSSize(width: 900, height: 520)
        host("trim-video", TrimEditor(item: samples.video, close: {}), size: videoSize)
        host("trim-audio", TrimEditor(item: samples.audio, close: {}), size: audioSize)
        host("crop-video", VideoCropEditor(item: samples.video, close: {}), size: videoSize)
        host("split-audio", SplitMediaEditor(item: samples.audio, markers: [9.5, 21, 30.25], close: {}), size: audioSize)
        host("snapshot", SnapshotEditor(item: samples.video, close: {}), size: videoSize)
        var box = Redaction(rect: CGRect(x: 760, y: 120, width: 360, height: 220), style: .pixelate)
        box.start = 2
        box.end = 9
        host("redact-video", VideoRedactEditor(item: samples.video, regions: [box], close: {}), size: videoSize)
        host("bleep", BleepEditor(item: samples.audio, intervals: [4.2...5.1, 17...18.6], close: {}), size: audioSize)
    }

    /// A simple landscape: sky gradient, sun, two hills.
    private static func writeSamplePhoto(to url: URL, size: CGSize, sky: (CGFloat, CGFloat, CGFloat)) -> Bool {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        let colors = [CGColor(srgbRed: sky.0, green: sky.1, blue: sky.2, alpha: 1),
                      CGColor(srgbRed: 1, green: 0.93, blue: 0.8, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height * 0.3), options: [])
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.35, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: size.width * 0.66, y: size.height * 0.6, width: size.width * 0.14, height: size.width * 0.14))
        for (i, shade) in [(0.3, 0.55, 0.32), (0.2, 0.42, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(srgbRed: shade.0, green: shade.1, blue: shade.2, alpha: 1))
            let path = CGMutablePath()
            let base = size.height * (i == 0 ? 0.42 : 0.3)
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: base))
            path.addCurve(to: CGPoint(x: size.width, y: base * 0.8),
                          control1: CGPoint(x: size.width * (i == 0 ? 0.3 : 0.5), y: base * 1.6),
                          control2: CGPoint(x: size.width * 0.7, y: base * 0.4))
            path.addLine(to: CGPoint(x: size.width, y: 0))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Clementine", kCGImagePropertyTIFFModel: "Sample Camera",
                                             kCGImagePropertyTIFFArtist: "Sample Artist"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:05:01 09:30:00",
                                             kCGImagePropertyExifLensModel: "Sample Lens 24mm f/2",
                                             kCGImagePropertyExifISOSpeedRatings: [100]],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// A short PDF whose pages carry big page numbers.
    private static func writeSamplePDF(to url: URL, pages: Int) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        let palette: [NSColor] = [.systemOrange, .systemBlue, .systemGreen, .systemPurple, .systemPink, .systemTeal]
        for page in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(palette[page % palette.count].withAlphaComponent(0.18).cgColor)
            ctx.fill(CGRect(x: 0, y: 640, width: 612, height: 152))
            ctx.setFillColor(NSColor(white: 0.75, alpha: 1).cgColor)
            for line in 0..<14 {
                ctx.fill(CGRect(x: 60, y: 560 - CGFloat(line) * 30, width: line % 4 == 3 ? 300 : 492, height: 10))
            }
            let text = NSAttributedString(string: "\(page + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 96, weight: .bold),
                .foregroundColor: palette[page % palette.count],
            ])
            let line = CTLineCreateWithAttributedString(text)
            ctx.textPosition = CGPoint(x: 60, y: 670)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return true
    }

    /// Hosts a view in a real (briefly visible) window so AppKit and SwiftUI
    /// lay it out and draw it, then captures it. Views that size themselves
    /// to their window (editors) pass a fixed `size`.
    private static func windowContent(_ name: String, _ view: NSView, _ appearance: NSAppearance,
                                      size fixedSize: NSSize? = nil, settle: TimeInterval = 0.4) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        var size = fixedSize ?? view.fittingSize
        if size.width < 10 || size.height < 10 { size = NSSize(width: 500, height: 400) }
        window.setContentSize(size)
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.minX + 20, y: screen.maxY - size.height - 20))
        }
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        view.layoutSubtreeIfNeeded()
        view.display()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("snapshot: FAILED \(name)")
            failures += 1
            window.close()
            return
        }
        // Paint the window background first; cacheDisplay draws the views on top.
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: rep.size).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        write(rep.representation(using: .png, properties: [:]), name: name)
        window.orderOut(nil)
        window.close()
    }

    // MARK: Output

    private static func save(_ name: String, image: NSImage, size: NSSize) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            print("snapshot: FAILED \(name)")
            failures += 1
            return
        }
        // Size in points = pixels, so the image is drawn at full resolution.
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        write(rep.representation(using: .png, properties: [:]), name: name)
    }

    private static func write(_ data: Data?, name: String) {
        guard let data else {
            print("snapshot: FAILED \(name)")
            failures += 1
            return
        }
        do {
            try data.write(to: directory.appendingPathComponent("\(name).png"))
            print("snapshot: \(name).png")
        } catch {
            print("snapshot: FAILED \(name): \(error)")
            failures += 1
        }
    }
}

/// Opaque rounded background standing in for the HUD's blur in snapshots.
private final class RoundedBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}
