#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO

/// Image compression with presets or an exact target size.
///
/// Lossy formats: binary-search the quality (≤ 8 encodes); if even the
/// lowest quality is too big, downscale by √(target/size) and search again.
/// PNG: lossless re-encode → 256-colour palette (keeps transparency) →
/// downscale.
public enum ImageCompressor {
    /// The format a compressed copy is written in.
    public static func outputFormat(for source: Format?, hasAlpha: Bool) -> Format {
        switch source {
        case .jpg?: return .jpg
        case .png?: return .png
        case .heic?: return ImageCodec.canEncodeNatively(.heic) ? .heic : .jpg
        case .webp?: return .webp
        case .avif?: return .avif
        default: return hasAlpha ? .png : .jpg
        }
    }

    struct Preset {
        let quality: Double
        let maxSide: Int?
    }

    static func preset(_ p: CompressOptions.Preset) -> Preset {
        switch p {
        case .high: return Preset(quality: 0.82, maxSide: nil)
        case .medium: return Preset(quality: 0.68, maxSide: 2560)
        case .small: return Preset(quality: 0.5, maxSide: 1600)
        case .email, .discord, .whatsapp: return Preset(quality: 0.82, maxSide: nil)
        }
    }

    /// Compresses `input` into `output` (which must have the extension of
    /// `outputFormat`). Returns a note for the HUD when relevant.
    @discardableResult
    public static func compress(_ input: InputItem, to output: URL, format: Format, options: CompressOptions,
                                settings: ConversionSettings,
                                progress: @Sendable (Double) -> Void = { _ in }) async throws -> String? {
        let originalSize = Int64((try? FileManager.default.attributesOfItem(atPath: input.url.path)[.size] as? Int) ?? 0)
        let target = options.targetBytes ?? options.presetLimitBytes
        if let target, originalSize > 0, originalSize <= target, input.format == format {
            // Already small enough: a byte-for-byte copy is the best result.
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: input.url, to: output)
            return "Already under \(ByteCountFormatter.string(fromByteCount: target, countStyle: .file))."
        }
        var decoded = try ImageCodec.decode(input.url, format: input.format)
        let p = preset(options.preset)
        if target == nil, let maxSide = p.maxSide {
            decoded = try limit(decoded, maxSide: maxSide)
        }
        progress(0.1)
        if format == .png {
            return try await compressPNG(decoded, to: output, target: target, preset: options.preset, progress: progress)
        }
        guard let target else {
            let data = try await encode(decoded, as: format, quality: p.quality, settings: settings)
            try data.write(to: output)
            return nil
        }
        var image = decoded
        for round in 0..<4 {
            try Task.checkCancellation()
            var lo = 0.05, hi = 0.95
            var best: Data?
            for _ in 0..<8 {
                let mid = (lo + hi) / 2
                let data = try await encode(image, as: format, quality: mid, settings: settings)
                if Int64(data.count) <= target {
                    best = data
                    lo = mid
                } else {
                    hi = mid
                }
                if hi - lo < 0.03 { break }
            }
            progress(0.2 + 0.2 * Double(round + 1))
            if let best {
                try best.write(to: output)
                return nil
            }
            // Even low quality is too big: shrink the picture and try again.
            let lowest = try await encode(image, as: format, quality: 0.05, settings: settings)
            let factor = min(0.9, sqrt(Double(target) / Double(max(1, lowest.count))) * 0.95)
            image = try scaled(image, by: factor)
        }
        throw JobFailure("Couldn't make this image small enough. Try a larger size.")
    }

    // MARK: PNG

    static func compressPNG(_ decoded: DecodedImage, to output: URL, target: Int64?, preset: CompressOptions.Preset,
                            progress: @Sendable (Double) -> Void) async throws -> String? {
        // 1. Lossless re-encode without metadata.
        let lossless = try ImageCodec.data(decoded.image, as: .png)
        if let target, Int64(lossless.count) <= target {
            try lossless.write(to: output)
            return nil
        }
        if target == nil && preset == .high {
            try lossless.write(to: output)
            return nil
        }
        // 2. Palette (256 colours, keeps transparency), then 3. downscale.
        var image = decoded.image
        for _ in 0..<5 {
            try Task.checkCancellation()
            let data = try await palettePNG(image)
            progress(0.6)
            guard let target else {
                try data.write(to: output)
                return nil
            }
            if Int64(data.count) <= target {
                try data.write(to: output)
                return nil
            }
            let factor = min(0.9, sqrt(Double(target) / Double(data.count)) * 0.95)
            image = try ImageCodec.scaled(image, width: max(1, Int(Double(image.width) * factor)),
                                          height: max(1, Int(Double(image.height) * factor)))
        }
        throw JobFailure("Couldn't make this image small enough. Try a larger size.")
    }

    /// 8-bit palette PNG via ffmpeg's palettegen/paletteuse.
    static func palettePNG(_ image: CGImage) async throws -> Data {
        let tmp = try TempDirectory(prefix: "clementine-png")
        defer { tmp.remove() }
        let input = tmp.file("in.png"), out = tmp.file("out.png")
        try ImageCodec.write(image, as: .png, to: input)
        guard FFmpegLocator.isAvailable else {
            return try Data(contentsOf: input)
        }
        try await FFmpegRunner.run(["-i", "file:" + input.path, "-filter_complex",
                                    "[0:v]split[a][b];[a]palettegen=max_colors=256:reserve_transparent=1[p];[b][p]paletteuse=dither=sierra2_4a",
                                    "-frames:v", "1", "-pix_fmt", "pal8", "file:" + out.path],
                                   duration: nil, failure: "Couldn't reduce the PNG's colours.")
        return try Data(contentsOf: out)
    }

    // MARK: Helpers

    static func encode(_ decoded: DecodedImage, as format: Format, quality: Double,
                       settings: ConversionSettings) async throws -> Data {
        if ImageCodec.canEncodeNatively(format) {
            var image = try ImageCodec.normalized(decoded.image)
            if format == .jpg && ImageCodec.imageHasAlpha(image) { image = try ImageCodec.flattened(image) }
            return try ImageCodec.data(image, as: format,
                                       properties: [kCGImageDestinationLossyCompressionQuality as String: quality])
        }
        let tmp = try TempDirectory(prefix: "clementine-enc")
        defer { tmp.remove() }
        let url = tmp.file("out.\(format.fileExtension)")
        try await ImageCodec.encode(decoded, as: format, to: url, settings: settings, quality: quality, keepMetadata: false)
        return try Data(contentsOf: url)
    }

    static func limit(_ decoded: DecodedImage, maxSide: Int) throws -> DecodedImage {
        let longest = max(decoded.width, decoded.height)
        guard longest > maxSide else { return decoded }
        return try scaled(decoded, by: Double(maxSide) / Double(longest))
    }

    static func scaled(_ decoded: DecodedImage, by factor: Double) throws -> DecodedImage {
        var copy = decoded
        copy.image = try ImageCodec.scaled(decoded.image, width: max(1, Int((Double(decoded.width) * factor).rounded())),
                                           height: max(1, Int((Double(decoded.height) * factor).rounded())))
        return copy
    }
}
#endif
