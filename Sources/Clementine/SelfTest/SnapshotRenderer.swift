import AppKit
import ClementineCore
import SwiftUI

/// `--render-snapshots <dir>`: renders UI pieces offscreen to PNG files so
/// they can be reviewed without a Mac (CI publishes them to the ci-snapshots
/// pre-release).
@MainActor
enum SnapshotRenderer {
    private static var failures = 0
    private static var directory = URL(fileURLWithPath: "snapshots")

    static func run(into dir: URL) -> Int32 {
        directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Preferences.registerDefaults()
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

        for (suffix, name) in appearances {
            let appearance = NSAppearance(named: name)!
            menuBarIcon(suffix: suffix, appearance: appearance)
            wheels(suffix: suffix, appearance: appearance)
            hud(suffix: suffix, appearance: appearance)
            windowContent("settings-general-\(suffix)", SettingsWindowController.makeView(tab: .general), appearance)
            windowContent("settings-output-\(suffix)", SettingsWindowController.makeView(tab: .output), appearance)
            windowContent("settings-quality-\(suffix)", SettingsWindowController.makeView(tab: .quality), appearance)
            windowContent("onboarding-\(suffix)", OnboardingWindowController.makeView(), appearance)
            dialogs(suffix: suffix, appearance: appearance)
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
            (.channels, ["song.wav"]),
        ]
        for (tool, files) in cases {
            let view = ToolUI.dialog(for: tool, items: sampleItems(files), run: { _, _ in }, cancel: {})
            windowContent("dialog-\(tool.rawValue)-\(suffix)", NSHostingView(rootView: view), appearance)
        }
    }

    /// Hosts a view in a real (briefly visible) window so AppKit and SwiftUI
    /// lay it out and draw it, then captures it.
    private static func windowContent(_ name: String, _ view: NSView, _ appearance: NSAppearance) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        var size = view.fittingSize
        if size.width < 10 || size.height < 10 { size = NSSize(width: 500, height: 400) }
        window.setContentSize(size)
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.minX + 20, y: screen.maxY - size.height - 20))
        }
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
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
