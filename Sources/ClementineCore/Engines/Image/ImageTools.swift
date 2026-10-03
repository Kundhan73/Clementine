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
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        if [.jpg, .png, .tiff, .heic].contains(format), let type = CGImageSourceGetType(source),
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
