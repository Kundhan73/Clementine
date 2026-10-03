import Foundation
#if canImport(Compression)
import Compression
#endif

/// CRC-32 (IEEE 802.3), as used by ZIP and PNG.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var crc = ~seed
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for byte in buf { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return ~crc
    }
}

/// Small in-memory ZIP writer (stored + deflate, UTF-8 names) used to build
/// DOCX packages. Large user archives use `ditto`/`bsdtar` instead.
public struct ZipWriter {
    public enum Method: UInt16 { case stored = 0, deflated = 8 }

    private var body = Data()
    private var central = Data()
    private var entries: UInt16 = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    public init(date: Date = Date()) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dosDay: Int = (year << 9) | (month << 5) | day
        dosTime = UInt16(truncatingIfNeeded: time)
        dosDate = UInt16(truncatingIfNeeded: dosDay)
    }

    /// Adds a file. Deflate falls back to stored when it doesn't help.
    public mutating func add(_ path: String, _ data: Data, method: Method = .deflated) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        var payload = data
        var used = Method.stored
        if method == .deflated, let packed = Self.deflate(data) {
            payload = packed
            used = .deflated
        }
        let offset = UInt32(body.count)
        var local = Data()
        local.le32(0x0403_4B50)
        local.le16(20)                 // version needed
        local.le16(0x0800)             // UTF-8 names
        local.le16(used.rawValue)
        local.le16(dosTime)
        local.le16(dosDate)
        local.le32(crc)
        local.le32(UInt32(payload.count))
        local.le32(UInt32(data.count))
        local.le16(UInt16(name.count))
        local.le16(0)                  // extra length
        local.append(name)
        body.append(local)
        body.append(payload)

        central.le32(0x0201_4B50)
        central.le16(0x031E)           // made by: Unix, spec 3.0
        central.le16(20)
        central.le16(0x0800)
        central.le16(used.rawValue)
        central.le16(dosTime)
        central.le16(dosDate)
        central.le32(crc)
        central.le32(UInt32(payload.count))
        central.le32(UInt32(data.count))
        central.le16(UInt16(name.count))
        central.le16(0)                // extra
        central.le16(0)                // comment
        central.le16(0)                // disk
        central.le16(0)                // internal attributes
        central.le32(UInt32(0o100644) << 16) // -rw-r--r--
        central.le32(offset)
        central.append(name)
        entries += 1
    }

    public mutating func add(_ path: String, _ text: String) { add(path, Data(text.utf8)) }

    /// The complete archive.
    public func finish() -> Data {
        var out = body
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4B50)
        out.le16(0)
        out.le16(0)
        out.le16(entries)
        out.le16(entries)
        out.le32(UInt32(central.count))
        out.le32(cdOffset)
        out.le16(0)
        return out
    }

    /// Raw DEFLATE (RFC 1951). Returns nil if unavailable or not smaller.
    static func deflate(_ input: Data) -> Data? {
        #if canImport(Compression)
        guard input.count > 64 else { return nil }
        let capacity = input.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < input.count else { return nil }
        output.count = written
        return output
        #else
        return nil
        #endif
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(shift)) & 0xFF)) } }
}
