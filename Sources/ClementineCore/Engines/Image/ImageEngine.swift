#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO

/// Image conversions: raster ↔ raster (ImageIO, ffmpeg for WebP/AVIF),
/// image → PDF, SVG and DOCX.
public enum ImageEngine {
    /// Converts one image to `target`, writing to `output`.
    public static func convert(_ input: InputItem, to target: Format, output: URL, settings: ConversionSettings,
                               progress: @Sendable (Double) -> Void = { _ in }) async throws {
        progress(0.05)
        let decoded = try ImageCodec.decode(input.url, format: input.format)
        progress(0.4)
        try Task.checkCancellation()
        switch target {
        case .pdf:
            try ImagePDF.write(pages: [decoded], to: output)
        case .svg:
            try writeSVG(decoded, source: input, to: output, settings: settings)
        case .docx:
            try writeDOCX(decoded, source: input, to: output, settings: settings)
        default:
            try await ImageCodec.encode(decoded, as: target, to: output, settings: settings)
        }
        progress(1)
    }

    /// SVG that embeds the bitmap (exact appearance). JPEG/PNG sources are
    /// embedded byte-for-byte when no orientation fix is needed.
    static func writeSVG(_ decoded: DecodedImage, source: InputItem, to output: URL, settings: ConversionSettings) throws {
        let (data, mime) = try embeddableBitmap(decoded, source: source)
        let w = decoded.width, h = decoded.height
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" \
        width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
        <image width="\(w)" height="\(h)" preserveAspectRatio="none" xlink:href="data:\(mime);base64,\(data.base64EncodedString())"/>
        </svg>

        """
        try Data(svg.utf8).write(to: output)
    }

    /// DOCX with the image on a page, fitted to the page width.
    static func writeDOCX(_ decoded: DecodedImage, source: InputItem, to output: URL, settings: ConversionSettings) throws {
        let (data, mime) = try embeddableBitmap(decoded, source: source)
        var doc = DOCXDocument(title: OutputNamer.baseName(of: source.url))
        let size = decoded.pointSize
        let (w, h) = doc.fittedImageSize(width: size.width, height: size.height)
        doc.blocks = [.image(data, format: mime == "image/jpeg" ? "jpeg" : "png", width: w, height: h)]
        try DOCXWriter.data(for: doc).write(to: output)
    }

    /// Bitmap bytes suitable for embedding (SVG data URI, DOCX media).
    static func embeddableBitmap(_ decoded: DecodedImage, source: InputItem) throws -> (Data, String) {
        if source.format == .jpg || source.format == .png, !isRotated(source.url),
           let original = try? Data(contentsOf: source.url) {
            return (original, source.format == .jpg ? "image/jpeg" : "image/png")
        }
        if decoded.hasAlpha {
            return (try ImageCodec.data(decoded.image, as: .png), "image/png")
        }
        let lossless: Set<Format> = [.png, .tiff, .bmp, .gif, .svg, .ico, .icns, .tga, .psd]
        if let f = source.format, lossless.contains(f) {
            return (try ImageCodec.data(decoded.image, as: .png), "image/png")
        }
        let opaque = try ImageCodec.flattened(decoded.image)
        return (try ImageCodec.data(opaque, as: .jpg, properties: [kCGImageDestinationLossyCompressionQuality as String: 0.92]),
                "image/jpeg")
    }

    /// Whether the file carries an EXIF orientation other than "up".
    static func isRotated(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return false }
        return ((props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1) != 1
    }
}

/// Builds PDFs from images (one page per image).
public enum ImagePDF {
    public enum PageSize: String, Sendable, CaseIterable {
        case fitImage, a4, letter
        var points: CGSize? {
            switch self {
            case .fitImage: return nil
            case .a4: return CGSize(width: 595.28, height: 841.89)
            case .letter: return CGSize(width: 612, height: 792)
            }
        }
    }

    /// Writes already-decoded images, one per page.
    public static func write(pages: [DecodedImage], to url: URL, pageSize: PageSize = .fitImage, margin: CGFloat = 0) throws {
        var index = 0
        try write(count: pages.count, to: url, pageSize: pageSize, margin: margin) {
            defer { index += 1 }
            return pages[index]
        }
    }

    /// Writes `count` pages, asking `next` for each image just in time (so
    /// only one full-size image is in memory at once).
    public static func write(count: Int, to url: URL, pageSize: PageSize = .fitImage, margin: CGFloat = 0,
                             next: () throws -> DecodedImage) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [CFString: Any] = [kCGPDFContextCreator: "Clementine"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw JobFailure("Couldn't create the PDF.")
        }
        for _ in 0..<count {
            try autoreleasepool {
                let page = try next()
                let imageSize = page.pointSize
                var media: CGRect
                var drawRect: CGRect
                if let fixed = pageSize.points {
                    // Landscape page for landscape images.
                    let landscape = imageSize.width > imageSize.height
                    let size = landscape ? CGSize(width: fixed.height, height: fixed.width) : fixed
                    media = CGRect(origin: .zero, size: size)
                    let avail = media.insetBy(dx: margin, dy: margin)
                    let scale = min(avail.width / imageSize.width, avail.height / imageSize.height, 1)
                    let w = imageSize.width * scale, h = imageSize.height * scale
                    drawRect = CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
                } else {
                    media = CGRect(x: 0, y: 0, width: imageSize.width + 2 * margin, height: imageSize.height + 2 * margin)
                    drawRect = CGRect(x: margin, y: margin, width: imageSize.width, height: imageSize.height)
                }
                let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: NSData(bytes: &media, length: MemoryLayout<CGRect>.size)]
                ctx.beginPDFPage(pageInfo as CFDictionary)
                ctx.interpolationQuality = .high
                ctx.draw(page.image, in: drawRect)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
    }
}
#endif
