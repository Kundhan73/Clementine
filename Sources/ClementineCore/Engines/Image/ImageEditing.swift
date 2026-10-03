#if canImport(AppKit) && canImport(CoreImage)
import AppKit
import CoreGraphics
import CoreImage
import Foundation
#if canImport(Vision)
import Vision
#endif


/// AppKit/Core Graphics conveniences for the neutral colour type.
public extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
}

// MARK: Crop

public enum ImageCrop {
    /// Crops to `rect` in top-left-origin pixel coordinates (clamped).
    public static func crop(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1, let out = image.cropping(to: r) else {
            throw JobFailure("The crop area is empty.")
        }
        return out
    }

    /// Largest rect with `aspect` (w/h) centred in `size`.
    public static func centred(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0 else { return CGRect(origin: .zero, size: size) }
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

// MARK: Annotate


public extension Annotation {
    /// Bounding box (for selection and hit-testing).
    var bounds: CGRect {
        guard let first = points.first else { return .null }
        var r = CGRect(origin: first, size: .zero)
        for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
        switch kind {
        case .text:
            let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)])
            return CGRect(origin: first, size: size)
        case .marker:
            let d = markerDiameter
            return CGRect(x: first.x - d / 2, y: first.y - d / 2, width: d, height: d)
        default:
            return r.insetBy(dx: -lineWidth, dy: -lineWidth)
        }
    }
}

public enum AnnotationRenderer {
    /// Draws `annotations` over `image` and returns the flattened result.
    public static func render(_ image: CGImage, annotations: [Annotation]) throws -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageCodec.rgbSpace(of: image),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw JobFailure("Not enough memory for this image.")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Annotations use top-left coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(annotations, in: ctx)
        guard let out = ctx.makeImage() else { throw JobFailure("Couldn't draw the annotations.") }
        return out
    }

    /// Draws into a context already set up with top-left (flipped) coordinates.
    public static func draw(_ annotations: [Annotation], in ctx: CGContext) {
        for a in annotations {
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setFillColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            switch a.kind {
            case .pen, .highlighter:
                if a.kind == .highlighter {
                    ctx.setBlendMode(.multiply)
                    ctx.setAlpha(0.45)
                    ctx.setLineCap(.butt)
                }
                guard let first = a.points.first else { break }
                ctx.move(to: first)
                for p in a.points.dropFirst() { ctx.addLine(to: p) }
                if a.points.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
                ctx.strokePath()
            case .line, .arrow:
                guard a.points.count >= 2, let start = a.points.first, let end = a.points.last else { break }
                var shaftEnd = end
                if a.kind == .arrow {
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let head = CGFloat(max(12, a.lineWidth * 4))
                    shaftEnd = CGPoint(x: end.x - cos(angle) * head * 0.6, y: end.y - sin(angle) * head * 0.6)
                    ctx.move(to: end)
                    ctx.addLine(to: CGPoint(x: end.x - cos(angle - 0.45) * head, y: end.y - sin(angle - 0.45) * head))
                    ctx.addLine(to: CGPoint(x: end.x - cos(angle + 0.45) * head, y: end.y - sin(angle + 0.45) * head))
                    ctx.closePath()
                    ctx.fillPath()
                }
                ctx.move(to: start)
                ctx.addLine(to: shaftEnd)
                ctx.strokePath()
            case .rectangle, .ellipse:
                guard a.points.count >= 2, let p0 = a.points.first, let p1 = a.points.last else { break }
                let rect = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
                if a.kind == .rectangle { ctx.addRect(rect) } else { ctx.addEllipse(in: rect) }
                if a.filled { ctx.fillPath() } else { ctx.strokePath() }
            case .text:
                guard let origin = a.points.first, !a.text.isEmpty else { break }
                drawText(a.text, at: origin, size: a.fontSize, color: a.color.nsColor, in: ctx)
            case .marker:
                guard let c = a.points.first else { break }
                let d = a.markerDiameter
                ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
                let label = "\(a.number)"
                let font = NSFont.systemFont(ofSize: d * 0.55, weight: .bold)
                let size = (label as NSString).size(withAttributes: [.font: font])
                drawText(label, at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), size: d * 0.55,
                         color: .white, in: ctx, weight: .bold)
            }
            ctx.restoreGState()
        }
    }

    static func drawText(_ text: String, at origin: CGPoint, size: Double, color: NSColor, in ctx: CGContext,
                         weight: NSFont.Weight = .semibold) {
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(color == .white ? 0 : 0.25)
        shadow.shadowBlurRadius = 2
        (text as NSString).draw(at: origin, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                             .foregroundColor: color, .shadow: shadow])
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: Redact


public enum Redactor {
    /// Destructively hides the regions (blur also pixelates first, so it
    /// can't be undone).
    public static func render(_ image: CGImage, redactions: [Redaction]) throws -> CGImage {
        let h = CGFloat(image.height)
        var ci = CIImage(cgImage: image)
        let extent = ci.extent
        for r in redactions {
            // CI uses a bottom-left origin.
            let rect = CGRect(x: r.rect.minX, y: h - r.rect.maxY, width: r.rect.width, height: r.rect.height)
                .intersection(extent)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let patch: CIImage
            switch r.style {
            case .solid:
                patch = CIImage(color: CIColor(cgColor: r.color.cgColor)).cropped(to: rect)
            case .pixelate:
                let scale = max(8, min(rect.width, rect.height) / 8)
                patch = ci.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale,
                                                                kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY)])
                    .cropped(to: rect)
            case .blur:
                let scale = max(6, min(rect.width, rect.height) / 12)
                let radius = max(12, min(rect.width, rect.height) / 5)
                patch = ci.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale])
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: rect)
            }
            ci = patch.composited(over: ci)
        }
        guard let out = ImageAdjuster.context.createCGImage(ci.cropped(to: extent), from: extent, format: .RGBA8,
                                                            colorSpace: ImageCodec.rgbSpace(of: image)) else {
            throw JobFailure("Couldn't apply the redactions.")
        }
        return out
    }

    /// Faces, as top-left-origin pixel rects (slightly enlarged).
    public static func faces(in image: CGImage) -> [CGRect] {
        #if canImport(Vision)
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map { face in
            let r = pixelRect(face.boundingBox, image: image)
            return r.insetBy(dx: -0.15 * r.width, dy: -0.2 * r.height)
        }
        #else
        return []
        #endif
    }

    /// Recognised text lines with their rects (for "redact all text" and search).
    public static func textLines(in image: CGImage) -> [(text: String, rect: CGRect)] {
        #if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return (candidate.string, pixelRect(obs.boundingBox, image: image).insetBy(dx: -2, dy: -2))
        }
        #else
        return []
        #endif
    }

    /// Rects of words matching `query` (case-insensitive) inside text lines.
    public static func matches(of query: String, in image: CGImage) -> [CGRect] {
        #if canImport(Vision)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var rects: [CGRect] = []
        for obs in request.results ?? [] {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let s = candidate.string
            var searchRange = s.startIndex..<s.endIndex
            while let found = s.range(of: q, options: .caseInsensitive, range: searchRange) {
                if let box = try? candidate.boundingBox(for: found) {
                    rects.append(pixelRect(box.boundingBox, image: image).insetBy(dx: -2, dy: -2))
                }
                searchRange = found.upperBound..<s.endIndex
            }
        }
        return rects
        #else
        return []
        #endif
    }

    /// Vision's normalised bottom-left rect → pixel top-left rect.
    static func pixelRect(_ r: CGRect, image: CGImage) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
    }
}

// MARK: Background / frame


public enum Framer {
    public static func render(_ image: CGImage, style: FrameStyle) throws -> CGImage {
        var subject = image
        if style.removeBackground { subject = try cutOut(image) }
        let iw = CGFloat(subject.width), ih = CGFloat(subject.height)
        let pad = CGFloat(style.padding) * max(iw, ih)
        var cw = iw + 2 * pad, ch = ih + 2 * pad
        if let ratio = style.aspect.ratio {
            if cw / ch < ratio { cw = ch * ratio } else { ch = cw / ratio }
        }
        let canvasW = Int(cw.rounded()), canvasH = Int(ch.rounded())
        try ImageCodec.checkLimits(width: canvasW, height: canvasH)
        guard let ctx = CGContext(data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageCodec.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw JobFailure("Not enough memory for this image.")
        }
        let canvas = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        switch style.fill {
        case .none:
            break
        case .solid(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(canvas)
        case .gradient(let a, let b):
            let g = CGGradient(colorsSpace: ImageCodec.sRGB, colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        case .blurredSelf:
            let blurred = CIImage(cgImage: image).clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(iw, ih) / 25])
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.05, kCIInputSaturationKey: 1.2])
            let scale = max(cw / CGFloat(image.width), ch / CGFloat(image.height))
            let scaled = blurred.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = ImageAdjuster.context.createCGImage(scaled, from: canvas) {
                ctx.draw(cg, in: canvas)
            }
        }
        let rect = CGRect(x: (cw - iw) / 2, y: (ch - ih) / 2, width: iw, height: ih)
        let radius = CGFloat(style.cornerRadius) * min(iw, ih)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if style.shadow > 0 && !style.removeBackground {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -max(iw, ih) * 0.01), blur: max(iw, ih) * 0.04 * style.shadow,
                          color: CGColor(gray: 0, alpha: 0.45 * style.shadow))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        } else if style.shadow > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: -max(iw, ih) * 0.01), blur: max(iw, ih) * 0.04 * style.shadow,
                          color: CGColor(gray: 0, alpha: 0.45 * style.shadow))
        }
        ctx.saveGState()
        if !style.removeBackground {
            ctx.addPath(path)
            ctx.clip()
        }
        ctx.draw(subject, in: rect)
        ctx.restoreGState()
        guard let out = ctx.makeImage() else { throw JobFailure("Couldn't render the frame.") }
        return out
    }

    /// The main subject with the background removed (Vision, macOS 14+).
    public static func cutOut(_ image: CGImage) throws -> CGImage {
        #if canImport(Vision)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw JobFailure("No subject was found to cut out.")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ImageAdjuster.context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: ImageCodec.sRGB) else {
            throw JobFailure("Couldn't cut out the subject.")
        }
        return cg
        #else
        throw JobFailure("Background removal needs macOS 14.")
        #endif
    }
}

// MARK: Collage


public enum Collage {
    /// Cell rects (top-left origin) for `count` images of the given sizes.
    public static func cells(for sizes: [CGSize], style: CollageStyle) -> (canvas: CGSize, cells: [CGRect]) {
        let n = sizes.count
        guard n > 0 else { return (.zero, []) }
        let W = CGFloat(max(200, style.outputWidth)), p = CGFloat(style.padding), s = CGFloat(style.spacing)
        let inner = W - 2 * p
        switch style.layout {
        case .row:
            // Same height, widths follow the aspect ratios.
            let ratios = sizes.map { $0.width / max(1, $0.height) }
            let h = (inner - s * CGFloat(n - 1)) / ratios.reduce(0, +)
            var x = p
            let cells = ratios.map { r -> CGRect in
                defer { x += r * h + s }
                return CGRect(x: x, y: p, width: r * h, height: h)
            }
            return (CGSize(width: W, height: h + 2 * p), cells)
        case .column:
            var y = p
            let cells = sizes.map { size -> CGRect in
                let h = inner * size.height / max(1, size.width)
                defer { y += h + s }
                return CGRect(x: p, y: y, width: inner, height: h)
            }
            return (CGSize(width: W, height: y - s + p), cells)
        case .grid:
            let cols = Int(ceil(sqrt(Double(n))))
            let rows = Int(ceil(Double(n) / Double(cols)))
            let cell = (inner - s * CGFloat(cols - 1)) / CGFloat(cols)
            let cells = (0..<n).map { i in
                CGRect(x: p + CGFloat(i % cols) * (cell + s), y: p + CGFloat(i / cols) * (cell + s), width: cell, height: cell)
            }
            return (CGSize(width: W, height: 2 * p + CGFloat(rows) * cell + CGFloat(rows - 1) * s), cells)
        case .featured:
            if n == 1 { return cells(for: sizes, style: { var c = style; c.layout = .grid; return c }()) }
            let bigW = (inner - s) * 2 / 3, sideW = inner - s - bigW
            let others = n - 1
            let sideH = (bigW * 3 / 4 - s * CGFloat(others - 1)) / CGFloat(others)
            let height = max(bigW * 3 / 4, CGFloat(others) * min(sideH, sideW) + s * CGFloat(others - 1))
            var cells = [CGRect(x: p, y: p, width: bigW, height: height)]
            let h = (height - s * CGFloat(others - 1)) / CGFloat(others)
            for i in 0..<others {
                cells.append(CGRect(x: p + bigW + s, y: p + CGFloat(i) * (h + s), width: sideW, height: h))
            }
            return (CGSize(width: W, height: height + 2 * p), cells)
        }
    }

    public static func render(_ images: [CGImage], style: CollageStyle) throws -> CGImage {
        let sizes = images.map { CGSize(width: $0.width, height: $0.height) }
        let (canvas, cells) = cells(for: sizes, style: style)
        let w = Int(canvas.width.rounded()), h = Int(canvas.height.rounded())
        try ImageCodec.checkLimits(width: w, height: h)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: ImageCodec.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw JobFailure("Not enough memory for this collage.")
        }
        ctx.setFillColor(style.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        for (image, cellTL) in zip(images, cells) {
            // Top-left → bottom-left.
            let cell = CGRect(x: cellTL.minX, y: CGFloat(h) - cellTL.maxY, width: cellTL.width, height: cellTL.height)
            ctx.saveGState()
            let r = min(CGFloat(style.cornerRadius), min(cell.width, cell.height) / 2)
            ctx.addPath(CGPath(roundedRect: cell, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.clip()
            // Aspect fill.
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = max(cell.width / iw, cell.height / ih)
            let dw = iw * scale, dh = ih * scale
            ctx.draw(image, in: CGRect(x: cell.midX - dw / 2, y: cell.midY - dh / 2, width: dw, height: dh))
            ctx.restoreGState()
        }
        guard let out = ctx.makeImage() else { throw JobFailure("Couldn't render the collage.") }
        return out
    }
}
#endif
