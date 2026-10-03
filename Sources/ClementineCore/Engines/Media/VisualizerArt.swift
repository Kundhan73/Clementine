#if canImport(AppKit) && canImport(CoreImage)
import AppKit
import CoreImage
import Foundation

/// The still pictures behind and above the visualizer: the background
/// (colour, gradient or cover art) and a transparent layer with the title.
public enum VisualizerArt {
    public struct Pictures: Sendable {
        public let background: URL
        public let overlay: URL?
    }

    static let fallback = (RGBA(0.12, 0.14, 0.22), RGBA(0.32, 0.25, 0.45))

    public static func prepare(_ audio: URL, info: MediaInfo, options: VisualizerOptions, in dir: URL) async throws -> Pictures {
        let (w, h) = options.shape.size
        var cover: CGImage?
        let wantsCover: Bool
        switch options.background {
        case .coverArt, .blurredCover: wantsCover = true
        default: wantsCover = false
        }
        if info.coverArt != nil, wantsCover {
            let coverURL = dir.appendingPathComponent("cover.png")
            if (try? await MediaEngine.run([FFmpegAttempt("cover", output: ["-map", "0:v:0", "-frames:v", "1", "-update", "1",
                                                                             "-f", "image2", "-c:v", "png"])],
                                           input: audio, output: coverURL, duration: nil, failure: "")) != nil {
                cover = try? ImageCodec.decode(coverURL, format: .png).image
            }
        }
        if case .image(let url) = options.background {
            cover = try? ImageCodec.decode(url).image
        }
        let background = dir.appendingPathComponent("background.png")
        try ImageCodec.write(try backgroundImage(options.background, cover: cover, width: w, height: h), as: .png, to: background)
        var overlay: URL?
        let title = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, let image = titleImage(title, width: w, height: h) {
            let url = dir.appendingPathComponent("title.png")
            try ImageCodec.write(image, as: .png, to: url)
            overlay = url
        }
        return Pictures(background: background, overlay: overlay)
    }

    public static func backgroundImage(_ background: VisualizerOptions.Background, cover: CGImage?, width: Int,
                                       height: Int) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageCodec.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw JobFailure("Not enough memory for the video picture.")
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        func gradient(_ a: RGBA, _ b: RGBA) {
            let g = CGGradient(colorsSpace: ImageCodec.sRGB, colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        }
        func aspectFill(_ image: CGImage) -> CGRect {
            let s = max(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
            let dw = CGFloat(image.width) * s, dh = CGFloat(image.height) * s
            return CGRect(x: (canvas.width - dw) / 2, y: (canvas.height - dh) / 2, width: dw, height: dh)
        }
        switch background {
        case .solid(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(canvas)
        case .gradient(let a, let b):
            gradient(a, b)
        case .coverArt, .image:
            if let cover {
                ctx.interpolationQuality = .high
                ctx.draw(cover, in: aspectFill(cover))
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.25))
                ctx.fill(canvas)
            } else {
                gradient(fallback.0, fallback.1)
            }
        case .blurredCover:
            if let cover {
                let rect = aspectFill(cover)
                let scaled = CIImage(cgImage: cover)
                    .transformed(by: CGAffineTransform(scaleX: rect.width / CGFloat(cover.width), y: rect.height / CGFloat(cover.height)))
                    .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                let blurred = scaled.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(max(width, height)) / 28])
                    .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.18, kCIInputSaturationKey: 1.15])
                if let cg = ImageAdjuster.context.createCGImage(blurred, from: canvas) {
                    ctx.draw(cg, in: canvas)
                } else {
                    gradient(fallback.0, fallback.1)
                }
            } else {
                gradient(fallback.0, fallback.1)
            }
        }
        guard let image = ctx.makeImage() else { throw JobFailure("Couldn't draw the video picture.") }
        return image
    }

    /// Transparent full-frame layer with the title near the top.
    public static func titleImage(_ title: String, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageCodec.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGFloat(min(width, height)) * 0.055
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = size * 0.25
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.05)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ]
        // One line, shortened with "…" to fit.
        let maxWidth = CGFloat(width) * 0.86
        var text = title
        while text.count > 1 && (text as NSString).size(withAttributes: attributes).width > maxWidth {
            text = String(text.dropLast(2)) + "…"
        }
        let measured = (text as NSString).size(withAttributes: attributes)
        let origin = CGPoint(x: (CGFloat(width) - measured.width) / 2, y: CGFloat(height) * 0.9 - measured.height / 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: origin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
#endif
