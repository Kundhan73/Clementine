import AppKit

/// `--render-snapshots <dir>`: renders UI pieces offscreen to PNG files so they
/// can be reviewed without a Mac (CI publishes them to the ci-snapshots
/// pre-release).
@MainActor
enum SnapshotRenderer {
    static func run(into dir: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures = 0
        func save(_ name: String, size: NSSize, scale: CGFloat = 2, appearance: NSAppearance.Name = .aqua, _ draw: () -> Void) {
            guard let data = renderPNG(size: size, scale: scale, appearance: appearance, draw) else {
                print("snapshot: FAILED \(name)"); failures += 1; return
            }
            do {
                try data.write(to: dir.appendingPathComponent("\(name).png"))
                print("snapshot: \(name).png")
            } catch {
                print("snapshot: FAILED \(name): \(error)"); failures += 1
            }
        }

        for (suffix, appearance, bg) in [("light", NSAppearance.Name.aqua, NSColor(white: 0.93, alpha: 1)),
                                         ("dark", NSAppearance.Name.darkAqua, NSColor(white: 0.16, alpha: 1))] {
            save("menubar-icon-\(suffix)", size: NSSize(width: 18, height: 18), scale: 8, appearance: appearance) {
                bg.setFill()
                NSRect(x: 0, y: 0, width: 18, height: 18).fill()
                let image = MenuBarIcon.make()
                // Template images are drawn in the label colour, as the menu bar does.
                NSColor.labelColor.set()
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    NSColor.labelColor.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            }
        }
        return failures == 0 ? 0 : 1
    }

    static func renderPNG(size: NSSize, scale: CGFloat, appearance: NSAppearance.Name, _ draw: () -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance(draw)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
