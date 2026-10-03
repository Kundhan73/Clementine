#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
#if canImport(AppKit)
import AppKit
#endif

/// A decoded still image (orientation already applied) and the metadata worth
/// carrying over to the output.
public struct DecodedImage: @unchecked Sendable {
    public var image: CGImage
    public var metadata: [String: Any]
    public var hasAlpha: Bool
    /// Pixels per inch (72 if unknown).
    public var dpi: Double

    public init(image: CGImage, metadata: [String: Any] = [:], hasAlpha: Bool, dpi: Double = 72) {
        self.image = image
        self.metadata = metadata
        self.hasAlpha = hasAlpha
        self.dpi = dpi
    }

    public var width: Int { image.width }
    public var height: Int { image.height }
    /// Size in points for page layout.
    public var pointSize: CGSize {
        let scale = 72.0 / (dpi > 0 ? dpi : 72)
        return CGSize(width: Double(width) * scale, height: Double(height) * scale)
    }
}

/// ImageIO decode/encode helpers shared by the image engine and tools.
public enum ImageCodec {
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let maxSide = 30_000
    static let maxPixels = 300_000_000

    /// UTIs ImageIO can write on this Mac.
    public static let encodableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    public static func uti(for format: Format) -> String? {
        switch format {
        case .jpg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .gif: return "com.compuserve.gif"
        case .avif: return "public.avif"
        case .webp: return "org.webmproject.webp"
        default: return nil
        }
    }

    /// Whether ImageIO itself can write `format` (else ffmpeg is used for
    /// WebP/AVIF). HEIC is probed with a real encode because virtual Macs
    /// without a media engine list it but fail.
    public static func canEncodeNatively(_ format: Format) -> Bool {
        switch format {
        case .heic: return heicEncodeWorks
        case .avif: return avifEncodeWorks
        case .webp: return webpEncodeWorks
        default: return uti(for: format).map(encodableTypes.contains) ?? false
        }
    }

    private static let heicEncodeWorks = probeEncode("public.heic")
    private static let avifEncodeWorks = probeEncode("public.avif")
    private static let webpEncodeWorks = probeEncode("org.webmproject.webp")

    private static func probeEncode(_ uti: String) -> Bool {
        guard encodableTypes.contains(uti),
              let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = ctx.makeImage() else { return false }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, uti as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) && data.length > 0
    }

    // MARK: Decode

    /// Decodes the first frame (largest image for icon files) with EXIF
    /// orientation applied to the pixels.
    public static func decode(_ url: URL, format: Format? = nil) throws -> DecodedImage {
        let format = format ?? Format.detect(url: url)
        if format == .svg { return try decodeSVG(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw JobFailure("This image can't be opened. It may be damaged or in an unsupported format.")
        }
        var index = 0
        if format == .ico || format == .icns {
            var best = 0
            for i in 0..<CGImageSourceGetCount(source) {
                let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any] ?? [:]
                let w = (p[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
                if w > best { best = w; index = i }
            }
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        let pw = (props[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
        let ph = (props[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
        try checkLimits(width: pw, height: ph)
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1

        let image: CGImage?
        if orientation != 1 && orientation >= 1 && orientation <= 8 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(pw, ph, 1),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, index, opts as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image else {
            throw JobFailure("This image can't be decoded. It may be damaged or in an unsupported format.")
        }
        var metadata = props
        metadata[kCGImagePropertyOrientation as String] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        let dpi = (props[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue ?? 72
        let alphaFlag = (props[kCGImagePropertyHasAlpha as String] as? Bool) ?? true
        return DecodedImage(image: image, metadata: metadata, hasAlpha: alphaFlag && imageHasAlpha(image), dpi: dpi)
    }

    static func checkLimits(width: Int, height: Int) throws {
        if width > maxSide || height > maxSide || width * height > maxPixels {
            throw JobFailure("This image is too large to convert (\(width) × \(height) pixels).")
        }
    }

    public static func imageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: return true
        default: return false
        }
    }

    /// Renders an SVG with AppKit's vector renderer, at its intrinsic size
    /// but at least 1024 px on the long edge.
    static func decodeSVG(_ url: URL) throws -> DecodedImage {
        #if canImport(AppKit)
        guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else {
            throw JobFailure("This SVG can't be rendered.")
        }
        let size = svg.size
        let scale = max(1, 1024 / max(size.width, size.height))
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        try checkLimits(width: w, height: h)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw JobFailure("Not enough memory to render this SVG.")
        }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        svg.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { throw JobFailure("This SVG can't be rendered.") }
        return DecodedImage(image: image, metadata: [:], hasAlpha: true, dpi: 72)
        #else
        throw JobFailure("SVG rendering needs macOS.")
        #endif
    }

    // MARK: Pixel helpers

    /// Draws `image` over a solid background (alpha → opaque).
    public static func flattened(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) throws -> CGImage {
        let space = rgbSpace(of: image)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw JobFailure("Not enough memory for this image.")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(background)
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        guard let out = ctx.makeImage() else { throw JobFailure("Not enough memory for this image.") }
        return out
    }

    /// Redraws images in unusual colour models (CMYK, Lab, indexed) as RGB.
    public static func normalized(_ image: CGImage) throws -> CGImage {
        guard let model = image.colorSpace?.model, model != .rgb, model != .monochrome else { return image }
        let alpha = imageHasAlpha(image)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                    : CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw JobFailure("Not enough memory for this image.")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { throw JobFailure("Not enough memory for this image.") }
        return out
    }

    static func rgbSpace(of image: CGImage) -> CGColorSpace {
        if let cs = image.colorSpace, cs.model == .rgb { return cs }
        return sRGB
    }

    /// Scales an image to exact pixel dimensions.
    public static func scaled(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let alpha = imageHasAlpha(image)
        guard let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: rgbSpace(of: image),
                                  bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                    : CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw JobFailure("Not enough memory for this image.")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { throw JobFailure("Not enough memory for this image.") }
        return out
    }

    // MARK: Encode

    /// Metadata for the destination: EXIF/GPS/IPTC/TIFF when keeping
    /// metadata, plus format options (quality, TIFF LZW).
    public static func destinationProperties(for decoded: DecodedImage, target: Format, keepMetadata: Bool,
                                             quality: Double?) -> [String: Any] {
        var props: [String: Any] = [:]
        if keepMetadata {
            let keys: [CFString] = [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                                    kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                                    kCGImagePropertyExifAuxDictionary, kCGImagePropertyDPIWidth,
                                    kCGImagePropertyDPIHeight]
            for key in keys {
                if let value = decoded.metadata[key as String] { props[key as String] = value }
            }
            if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                exif[kCGImagePropertyExifPixelXDimension as String] = decoded.width
                exif[kCGImagePropertyExifPixelYDimension as String] = decoded.height
                props[kCGImagePropertyExifDictionary as String] = exif
            }
            props[kCGImagePropertyOrientation as String] = 1
        }
        if target == .tiff {
            var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression as String] = 5 // LZW
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let quality { props[kCGImageDestinationLossyCompressionQuality as String] = quality }
        return props
    }

    /// Encodes with ImageIO to a file.
    public static func write(_ image: CGImage, as format: Format, to url: URL, properties: [String: Any] = [:]) throws {
        guard let uti = uti(for: format),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            throw JobFailure("\(format.displayName) can't be written on this Mac.")
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw JobFailure("Couldn't write the \(format.displayName) file.")
        }
    }

    /// Encodes with ImageIO into memory.
    public static func data(_ image: CGImage, as format: Format, properties: [String: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        guard let uti = uti(for: format),
              let dest = CGImageDestinationCreateWithData(data as CFMutableData, uti as CFString, 1, nil) else {
            throw JobFailure("\(format.displayName) can't be written on this Mac.")
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw JobFailure("Couldn't encode the \(format.displayName) image.")
        }
        return data as Data
    }

    /// Default quality (0…1) for lossy targets.
    public static func quality(for format: Format, settings: ConversionSettings) -> Double? {
        switch format {
        case .jpg: return settings.jpegQuality
        case .heic: return settings.heicQuality
        case .webp: return Double(settings.webpQuality) / 100
        case .avif: return Double(settings.avifQuality) / 100
        default: return nil
        }
    }

    /// Writes `decoded` as `format`, using ImageIO where it can and ffmpeg
    /// (libwebp / libaom) for WebP and AVIF otherwise.
    public static func encode(_ decoded: DecodedImage, as format: Format, to url: URL, settings: ConversionSettings,
                              quality overrideQuality: Double? = nil, keepMetadata: Bool? = nil) async throws {
        var image = try normalized(decoded.image)
        var hasAlpha = decoded.hasAlpha
        if (format == .jpg || format == .bmp) && imageHasAlpha(image) {
            image = try flattened(image)
            hasAlpha = false
        }
        let quality = overrideQuality ?? Self.quality(for: format, settings: settings)
        if canEncodeNatively(format) {
            var d = decoded
            d.image = image
            let props = destinationProperties(for: d, target: format, keepMetadata: keepMetadata ?? settings.keepMetadata,
                                              quality: quality)
            try write(image, as: format, to: url, properties: props)
        } else if format == .webp || format == .avif {
            try await encodeWithFFmpeg(image, hasAlpha: hasAlpha, as: format, to: url, quality: quality ?? 0.8)
        } else {
            throw JobFailure("\(format.displayName) can't be written on this Mac.")
        }
    }

    /// WebP via libwebp and AVIF via libaom (still picture, with an alpha
    /// plane when needed), from a lossless PNG intermediate.
    static func encodeWithFFmpeg(_ image: CGImage, hasAlpha: Bool, as format: Format, to url: URL,
                                 quality: Double) async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let png = tmp.file("frame.png")
        try write(image, as: .png, to: png)
        var args = ["-i", png.path]
        switch format {
        case .webp:
            let q = Int((quality * 100).rounded())
            args += ["-frames:v", "1", "-c:v", "libwebp", "-quality", "\(max(1, min(100, q)))",
                     "-compression_level", "4", "-f", "webp", url.path]
        case .avif:
            // quality 1.0 → crf 10, 0.7 → 25, 0.0 → 60
            let crf = Int((60 - quality * 50).rounded())
            let color = "scale=out_color_matrix=bt709:out_range=pc,format=yuv420p"
            if hasAlpha {
                args += ["-filter_complex", "[0:v]split[c][a];[c]\(color)[cv];[a]alphaextract,format=gray[av]",
                         "-map", "[cv]", "-map", "[av]"]
            } else {
                args += ["-vf", color]
            }
            args += ["-frames:v", "1", "-c:v", "libaom-av1", "-still-picture", "1", "-crf", "\(max(0, min(63, crf)))",
                     "-b:v", "0", "-cpu-used", "6", "-row-mt", "1",
                     "-color_range", "pc", "-colorspace", "bt709", "-color_primaries", "bt709",
                     "-color_trc", "iec61966-2-1", "-f", "avif", url.path]
        default:
            throw JobFailure("\(format.displayName) can't be written with ffmpeg.")
        }
        try await FFmpegRunner.run(args, duration: nil, failure: "Couldn't write the \(format.displayName) file.")
    }
}
#endif
