import Foundation

/// Reads and rewrites the EXIF orientation tag of a JPEG in place, so
/// rotating or flipping a JPEG never re-encodes it.
public enum JPEGOrientation {
    /// The orientation stored in the file (1 if there is none).
    public static func read(_ data: Data) -> Int? {
        guard let exif = findExif(data) else { return isJPEG(data) ? 1 : nil }
        return exif.orientationOffset.map { readShort(data, at: $0, bigEndian: exif.bigEndian) } ?? 1
    }

    /// Returns the file with its orientation set to `orientation` (1…8), or
    /// nil if the file isn't a JPEG this can patch safely.
    public static func set(_ data: Data, orientation: Int) -> Data? {
        guard isJPEG(data), (1...8).contains(orientation) else { return nil }
        if let exif = findExif(data) {
            guard let offset = exif.orientationOffset else { return nil } // EXIF without the tag: let ImageIO handle it
            var out = data
            writeShort(&out, at: offset, value: UInt16(orientation), bigEndian: exif.bigEndian)
            return out
        }
        // No EXIF at all: insert a minimal APP1 segment with just the orientation.
        var segment = Data([0xFF, 0xE1, 0x00, 0x22])
        segment.append(contentsOf: Array("Exif".utf8) + [0, 0])
        segment.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]) // "MM", 42, IFD0 at 8
        segment.append(contentsOf: [0x00, 0x01])                                     // one entry
        segment.append(contentsOf: [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01])  // Orientation, SHORT, 1
        segment.append(contentsOf: [0x00, UInt8(orientation), 0x00, 0x00])
        segment.append(contentsOf: [0x00, 0x00, 0x00, 0x00])                          // no next IFD
        var insertAt = data.startIndex + 2
        // Keep a JFIF APP0 first if there is one.
        if data.count > 6, data[insertAt] == 0xFF, data[insertAt + 1] == 0xE0 {
            let length = Int(data[insertAt + 2]) << 8 | Int(data[insertAt + 3])
            insertAt += 2 + length
        }
        var out = Data(data[data.startIndex..<insertAt])
        out.append(segment)
        out.append(data[insertAt...])
        return out
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.count > 4 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
    }

    struct ExifInfo {
        var bigEndian: Bool
        /// Absolute offset of the orientation value (a SHORT), if present.
        var orientationOffset: Int?
    }

    /// Walks the segments up to the scan and parses IFD0 of the first Exif APP1.
    static func findExif(_ data: Data) -> ExifInfo? {
        guard isJPEG(data) else { return nil }
        var i = data.startIndex + 2
        while i + 4 <= data.endIndex {
            guard data[i] == 0xFF else { return nil }
            let marker = data[i + 1]
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            if marker == 0xDA || marker == 0xD9 { return nil } // start of scan / end: no EXIF before it
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard length >= 2, i + 2 + length <= data.endIndex else { return nil }
            let body = i + 4
            if marker == 0xE1, length >= 16,
               data[body..<body + 6].elementsEqual(Array("Exif".utf8) + [0, 0]) {
                let tiff = body + 6
                let bigEndian: Bool
                switch (data[tiff], data[tiff + 1]) {
                case (0x4D, 0x4D): bigEndian = true
                case (0x49, 0x49): bigEndian = false
                default: return nil
                }
                let end = i + 2 + length
                let ifd0 = tiff + Int(readLong(data, at: tiff + 4, bigEndian: bigEndian))
                guard ifd0 + 2 <= end else { return ExifInfo(bigEndian: bigEndian, orientationOffset: nil) }
                let count = Int(readShort(data, at: ifd0, bigEndian: bigEndian))
                for n in 0..<count {
                    let entry = ifd0 + 2 + n * 12
                    guard entry + 12 <= end else { break }
                    if readShort(data, at: entry, bigEndian: bigEndian) == 0x0112 {
                        return ExifInfo(bigEndian: bigEndian, orientationOffset: entry + 8)
                    }
                }
                return ExifInfo(bigEndian: bigEndian, orientationOffset: nil)
            }
            i += 2 + length
        }
        return nil
    }

    static func readShort(_ data: Data, at i: Int, bigEndian: Bool) -> Int {
        let a = Int(data[i]), b = Int(data[i + 1])
        return bigEndian ? (a << 8 | b) : (b << 8 | a)
    }

    static func readLong(_ data: Data, at i: Int, bigEndian: Bool) -> UInt32 {
        let bytes = (0..<4).map { UInt32(data[i + $0]) }
        return bigEndian ? (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3])
                         : (bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0])
    }

    static func writeShort(_ data: inout Data, at i: Int, value: UInt16, bigEndian: Bool) {
        data[i] = UInt8(bigEndian ? value >> 8 : value & 0xFF)
        data[i + 1] = UInt8(bigEndian ? value & 0xFF : value >> 8)
    }
}

/// Removes metadata segments from a JPEG without touching the image data.
public enum JPEGMetadata {
    /// Drops EXIF/XMP (APP1), Ducky (APP12), IPTC/Photoshop (APP13) and
    /// comments; keeps JFIF, the colour profile and everything after the
    /// scan starts. Re-adds the orientation tag when it isn't 1.
    public static func strip(_ data: Data) -> Data? {
        guard JPEGOrientation.isJPEG(data) else { return nil }
        let orientation = JPEGOrientation.read(data) ?? 1
        var out = Data([0xFF, 0xD8])
        var i = data.startIndex + 2
        while i + 4 <= data.endIndex {
            guard data[i] == 0xFF else { return nil }
            let marker = data[i + 1]
            if marker == 0xDA || marker == 0xD9 {
                out.append(data[i...])
                return orientation == 1 ? out : JPEGOrientation.set(out, orientation: orientation)
            }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard length >= 2, i + 2 + length <= data.endIndex else { return nil }
            if ![0xE1, 0xEC, 0xED, 0xFE].contains(marker) {
                out.append(data[i..<(i + 2 + length)])
            }
            i += 2 + length
        }
        return nil
    }
}
