// Draws Clementine's app icon with Core Graphics and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <out.iconset>
// Then: iconutil -c icns <out.iconset> -o AppIcon.icns
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a,
    ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// Draws the icon in a 1024×1024 coordinate space (y up).
func drawIcon(_ c: CGContext) {
    // Background tile (Apple's grid: 824 pt tile, 100 pt margin).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
    c.addPath(tilePath)
    c.setFillColor(rgb(0xFFF3E2))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(tilePath)
    c.clip()
    c.drawLinearGradient(gradient([(0, rgb(0xFFFBF4)), (1, rgb(0xFFE2C2))]),
                         start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()

    // Fruit.
    let center = CGPoint(x: 512, y: 468)
    let r: CGFloat = 300
    let fruit = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x8A3200, 0.35))
    c.addPath(fruit)
    c.setFillColor(rgb(0xF0700F))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(fruit)
    c.clip()
    c.drawRadialGradient(gradient([(0, rgb(0xFFC56B)), (0.45, rgb(0xFB8C1C)), (1, rgb(0xDD5308))]),
                         startCenter: CGPoint(x: 420, y: 580), startRadius: 0,
                         endCenter: center, endRadius: r * 1.18, options: [.drawsAfterEndLocation])
    // Peel dimples (deterministic).
    var seed: UInt32 = 7
    func rand() -> CGFloat { seed = seed &* 1_103_515_245 &+ 12345; return CGFloat((seed >> 8) & 0xFFFF) / 65535 }
    c.setFillColor(rgb(0xB84A05, 0.18))
    for _ in 0..<90 {
        let a = rand() * 2 * .pi, d = sqrt(rand()) * (r - 18)
        let p = CGPoint(x: center.x + cos(a) * d, y: center.y + sin(a) * d)
        let s = 4 + rand() * 5
        c.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
    }
    // Soft highlight.
    c.setFillColor(rgb(0xFFFFFF, 0.22))
    c.saveGState()
    c.translateBy(x: 392, y: 628)
    c.rotate(by: 0.6)
    c.fillEllipse(in: CGRect(x: -95, y: -48, width: 190, height: 96))
    c.restoreGState()
    c.restoreGState()

    // Convert symbol: two arrows chasing each other.
    let ring: CGFloat = 150
    c.saveGState()
    c.setStrokeColor(rgb(0xFFFFFF, 0.95))
    c.setFillColor(rgb(0xFFFFFF, 0.95))
    c.setLineWidth(46)
    c.setLineCap(.round)
    for start in [CGFloat(35), CGFloat(215)] {
        let a0 = start * .pi / 180, a1 = (start + 105) * .pi / 180
        c.addArc(center: center, radius: ring, startAngle: a0, endAngle: a1, clockwise: false)
        c.strokePath()
        // Arrowhead at the end of the counter-clockwise arc.
        let th = a1 + 0.05
        let radial = CGPoint(x: cos(th), y: sin(th)), tangent = CGPoint(x: -sin(th), y: cos(th))
        let base = CGPoint(x: center.x + radial.x * ring, y: center.y + radial.y * ring)
        let w: CGFloat = 62, l: CGFloat = 78
        c.move(to: CGPoint(x: base.x + radial.x * w, y: base.y + radial.y * w))
        c.addLine(to: CGPoint(x: base.x + tangent.x * l, y: base.y + tangent.y * l))
        c.addLine(to: CGPoint(x: base.x - radial.x * w, y: base.y - radial.y * w))
        c.closePath()
        c.fillPath()
    }
    c.restoreGState()

    // Stem.
    c.saveGState()
    c.translateBy(x: 500, y: 752)
    c.rotate(by: -0.18)
    c.addPath(CGPath(roundedRect: CGRect(x: -14, y: -6, width: 28, height: 70), cornerWidth: 12, cornerHeight: 12, transform: nil))
    c.setFillColor(rgb(0x6B4A2B))
    c.fillPath()
    c.restoreGState()

    // Leaf.
    c.saveGState()
    c.translateBy(x: 512, y: 800)
    c.rotate(by: 0.5)
    let leafLength: CGFloat = 250, leafWidth: CGFloat = 92
    let leaf = CGMutablePath()
    leaf.move(to: .zero)
    leaf.addQuadCurve(to: CGPoint(x: leafLength, y: 0), control: CGPoint(x: leafLength * 0.45, y: leafWidth * 1.25))
    leaf.addQuadCurve(to: .zero, control: CGPoint(x: leafLength * 0.55, y: -leafWidth * 1.25))
    c.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: rgb(0x1B4D1E, 0.3))
    c.addPath(leaf)
    c.setFillColor(rgb(0x3D9A45))
    c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.addPath(leaf)
    c.clip()
    c.drawLinearGradient(gradient([(0, rgb(0x7CCB6F)), (1, rgb(0x2E7D32))]),
                         start: CGPoint(x: 0, y: leafWidth), end: CGPoint(x: leafLength, y: -leafWidth), options: [])
    c.setStrokeColor(rgb(0x1E5E22, 0.55))
    c.setLineWidth(7)
    c.setLineCap(.round)
    c.move(to: CGPoint(x: 18, y: 0))
    c.addQuadCurve(to: CGPoint(x: leafLength - 30, y: 0), control: CGPoint(x: leafLength * 0.5, y: 10))
    c.strokePath()
    c.restoreGState()
}

func render(_ px: Int) -> CGImage {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.setShouldAntialias(true)
    c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawIcon(c)
    return c.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

for base in [16, 32, 128, 256, 512] {
    writePNG(render(base), to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(base * 2), to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote \(outDir.path)")
