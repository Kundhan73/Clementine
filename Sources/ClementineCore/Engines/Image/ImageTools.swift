#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
#if canImport(Vision)
import Vision
#endif

/// Instant image tools.
public enum ImageTools {
    /// Removes EXIF/GPS/IPTC/XMP. Lossless (no re-encode) where ImageIO can
    /// copy the compressed data; otherwise re-encodes at high quality. The
    /// visible orientation is kept.
    public static func stripMetadata(_ item: InputItem, to output: URL, settings: ConversionSettings) async throws {
        guard let format = item.format, let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else {
            throw JobFailure("This image can't be opened.")
        }
        if format == .jpg, let data = try? Data(contentsOf: item.url), let stripped = JPEGMetadata.strip(data) {
            try stripped.write(to: output)
            if !hasIdentifyingMetadata(output) { return }
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        if [.png, .tiff, .heic].contains(format), let type = CGImageSourceGetType(source),
           let dest = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
            let metadata = CGImageMetadataCreateMutable()
            if orientation != 1 {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation, NSNumber(value: orientation))
            }
            let options: [String: Any] = [
                kCGImageDestinationMetadata as String: metadata,
                kCGImageDestinationMergeMetadata as String: false,
                kCGImageMetadataShouldExcludeGPS as String: true,
                kCGImageMetadataShouldExcludeXMP as String: true,
            ]
            if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil),
               !hasIdentifyingMetadata(output) {
                return
            }
        }
        // Fallback: decode (baking orientation) and re-encode without metadata.
        let decoded = try ImageCodec.decode(item.url, format: format)
        let quality: Double? = [.jpg, .heic, .webp, .avif].contains(format) ? 0.95 : nil
        try await ImageCodec.encode(decoded, as: format, to: output, settings: settings, quality: quality, keepMetadata: false)
    }

    /// True if the file still has EXIF capture data, GPS or IPTC.
    public static func hasIdentifyingMetadata(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return false }
        if props[kCGImagePropertyGPSDictionary as String] != nil { return true }
        if props[kCGImagePropertyIPTCDictionary as String] != nil { return true }
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            let identifying = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifLensModel,
                               kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifUserComment]
            if identifying.contains(where: { exif[$0 as String] != nil }) { return true }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            let identifying = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime,
                               kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFSoftware]
            if identifying.contains(where: { tiff[$0 as String] != nil }) { return true }
        }
        return false
    }

    /// The format a tool writes an image in: the source's own format when
    /// Clementine can write it, otherwise PNG.
    public static func toolOutputFormat(for source: Format?) -> Format {
        guard let source, source.kind == .image, source != .svg, ImageCodec.uti(for: source) != nil else { return .png }
        if source == .heic && !ImageCodec.canEncodeNatively(.heic) { return .jpg }
        return source
    }

    /// Resizes keeping the aspect ratio (and metadata).
    public static func resize(_ item: InputItem, options: ResizeOptions, to output: URL, format: Format,
                              settings: ConversionSettings) async throws {
        var decoded = try ImageCodec.decode(item.url, format: item.format)
        let (w, h) = ImageGeometry.resized(width: decoded.width, height: decoded.height, mode: options.mode)
        try ImageCodec.checkLimits(width: w, height: h)
        decoded.image = try ImageCodec.scaled(decoded.image, width: w, height: h)
        try await ImageCodec.encode(decoded, as: format, to: output, settings: settings,
                                    quality: format == .jpg ? max(settings.jpegQuality, 0.9) : nil)
    }

    /// Rotates/flips. JPEG and HEIC only get a new orientation tag (no
    /// re-encode, no quality loss); other formats are redrawn (lossless for
    /// lossless formats).
    public static func rotate(_ item: InputItem, options: RotateOptions, to output: URL, format: Format,
                              settings: ConversionSettings) async throws {
        if format == item.format, format == .jpg, let data = try? Data(contentsOf: item.url),
           let current = JPEGOrientation.read(data) {
            let new = ExifOrientation.compose(current, turn: options.turn, flipHorizontal: options.flipHorizontal,
                                              flipVertical: options.flipVertical)
            if let patched = JPEGOrientation.set(data, orientation: new) {
                try patched.write(to: output)
                return
            }
        }
        if format == item.format, format == .jpg || format == .heic,
           let source = CGImageSourceCreateWithURL(item.url as CFURL, nil), let type = CGImageSourceGetType(source),
           let dest = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            let current = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
            let new = ExifOrientation.compose(current, turn: options.turn, flipHorizontal: options.flipHorizontal,
                                              flipVertical: options.flipVertical)
            let metadata = CGImageMetadataCreateMutable()
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyTIFFOrientation, NSNumber(value: new))
            let opts: [String: Any] = [kCGImageDestinationMetadata as String: metadata,
                                       kCGImageDestinationMergeMetadata as String: true,
                                       kCGImageDestinationOrientation as String: new]
            if CGImageDestinationCopyImageSource(dest, source, opts as CFDictionary, nil) { return }
        }
        var decoded = try ImageCodec.decode(item.url, format: item.format)
        var image = decoded.image
        if options.flipHorizontal { image = try transformed(image, .flipHorizontal) }
        if options.flipVertical { image = try transformed(image, .flipVertical) }
        switch options.turn {
        case .none: break
        case .right: image = try transformed(image, .right)
        case .half: image = try transformed(image, .half)
        case .left: image = try transformed(image, .left)
        }
        decoded.image = image
        try await ImageCodec.encode(decoded, as: format, to: output, settings: settings,
                                    quality: format == .jpg || format == .heic ? 0.95 : nil)
    }

    enum Transform { case right, left, half, flipHorizontal, flipVertical }

    static func transformed(_ image: CGImage, _ t: Transform) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let swap = t == .right || t == .left
        let nw = Int(swap ? h : w), nh = Int(swap ? w : h)
        let alpha = ImageCodec.imageHasAlpha(image)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageCodec.rgbSpace(of: image),
                                  bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                    : CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw JobFailure("Not enough memory for this image.")
        }
        switch t {
        case .right:
            ctx.translateBy(x: 0, y: CGFloat(nh))
            ctx.rotate(by: -.pi / 2)
        case .left:
            ctx.translateBy(x: CGFloat(nw), y: 0)
            ctx.rotate(by: .pi / 2)
        case .half:
            ctx.translateBy(x: w, y: h)
            ctx.rotate(by: .pi)
        case .flipHorizontal:
            ctx.translateBy(x: w, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        case .flipVertical:
            ctx.translateBy(x: 0, y: h)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw JobFailure("Not enough memory for this image.") }
        return out
    }

    /// Finds QR codes and barcodes (QR, Aztec, PDF417, DataMatrix, EAN,
    /// Code 128 …). Returns their text, de-duplicated, in reading order.
    public static func readCodes(in image: CGImage) throws -> [String] {
        #if canImport(Vision)
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let results = (request.results ?? []).sorted {
            // Vision uses a bottom-left origin: top-to-bottom, then left-to-right.
            ($0.boundingBox.minY, -$0.boundingBox.minX) > ($1.boundingBox.minY, -$1.boundingBox.minX)
        }
        var seen = Set<String>()
        return results.compactMap { $0.payloadStringValue }.filter { seen.insert($0).inserted }
        #else
        return []
        #endif
    }
}
#endif
