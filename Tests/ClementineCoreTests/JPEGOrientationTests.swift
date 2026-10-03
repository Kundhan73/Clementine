import ClementineCore
import XCTest

final class JPEGOrientationTests: XCTestCase {
    /// SOI, JFIF APP0, a fake scan and EOI.
    let plain = Data([0xFF, 0xD8,
                      0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0] +
                     [0xFF, 0xDA, 0x00, 0x04, 0x01, 0x02, 0x11, 0x22, 0x33, 0xFF, 0xD9])

    func testInsertsExifWhenMissing() throws {
        XCTAssertEqual(JPEGOrientation.read(plain), 1)
        let rotated = try XCTUnwrap(JPEGOrientation.set(plain, orientation: 6))
        XCTAssertEqual(JPEGOrientation.read(rotated), 6)
        XCTAssertEqual(rotated.count, plain.count + 36)
        // JFIF stays first, scan data untouched.
        XCTAssertEqual(Array(rotated.prefix(4)), [0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertEqual(Array(rotated.suffix(11)), Array(plain.suffix(11)))
    }

    func testPatchesExistingTag() throws {
        let once = try XCTUnwrap(JPEGOrientation.set(plain, orientation: 3))
        let twice = try XCTUnwrap(JPEGOrientation.set(once, orientation: 8))
        XCTAssertEqual(twice.count, once.count, "patched in place")
        XCTAssertEqual(JPEGOrientation.read(twice), 8)
    }

    func testLittleEndianExif() throws {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x22] + Array("Exif".utf8) + [0, 0])
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01, 0x00,
                                 0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
                                 0x00, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xD9])
        XCTAssertEqual(JPEGOrientation.read(data), 6)
        let patched = try XCTUnwrap(JPEGOrientation.set(data, orientation: 1))
        XCTAssertEqual(JPEGOrientation.read(patched), 1)
    }

    func testRejectsNonJPEG() {
        XCTAssertNil(JPEGOrientation.set(Data([0x89, 0x50, 0x4E, 0x47, 0, 0]), orientation: 6))
        XCTAssertNil(JPEGOrientation.read(Data([1, 2, 3])))
    }
}

final class JPEGMetadataTests: XCTestCase {
    func testStripKeepsImageAndOrientation() throws {
        var data = Data([0xFF, 0xD8])
        data.append(contentsOf: [0xFF, 0xE0, 0x00, 0x04, 0xAA, 0xBB])                    // APP0
        data.append(contentsOf: [0xFF, 0xFE, 0x00, 0x06] + Array("hey!".utf8))          // comment
        data.append(contentsOf: [0xFF, 0xED, 0x00, 0x04, 0x01, 0x02])                    // IPTC
        data.append(contentsOf: [0xFF, 0xE2, 0x00, 0x04, 0x0C, 0x0D])                    // ICC (kept)
        data.append(contentsOf: [0xFF, 0xDA, 0x00, 0x02, 0x99, 0x98, 0xFF, 0xD9])         // scan
        let rotated = try XCTUnwrap(JPEGOrientation.set(data, orientation: 6))
        let stripped = try XCTUnwrap(JPEGMetadata.strip(rotated))
        XCTAssertEqual(JPEGOrientation.read(stripped), 6)
        XCTAssertFalse(stripped.range(of: Data("hey!".utf8)) != nil)
        XCTAssertNotNil(stripped.range(of: Data([0xFF, 0xE2, 0x00, 0x04, 0x0C, 0x0D])))
        XCTAssertTrue(Array(stripped.suffix(8)) == [0xFF, 0xDA, 0x00, 0x02, 0x99, 0x98, 0xFF, 0xD9])
        let plain = try XCTUnwrap(JPEGMetadata.strip(data))
        XCTAssertNil(plain.range(of: Data("Exif".utf8)))
    }
}

final class JPEGExifInsertTests: XCTestCase {
    func testAddsOrientationToExistingExif() throws {
        // Big-endian EXIF with IFD0 = [Make "Can" (inline), XResolution → offset 38], next IFD 0.
        var tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        tiff += [0x00, 0x02]
        tiff += [0x01, 0x0F, 0x00, 0x02, 0x00, 0x00, 0x00, 0x04] + Array("Can".utf8) + [0]
        tiff += [0x01, 0x1A, 0x00, 0x05, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x26]
        tiff += [0x00, 0x00, 0x00, 0x00]
        tiff += [0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x01]        // 72/1 at offset 38
        let length = 2 + 6 + tiff.count
        var data = Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + Array("Exif".utf8) + [0, 0])
        data.append(contentsOf: tiff)
        data.append(contentsOf: [0xFF, 0xDA, 0x00, 0x02, 0x55, 0xFF, 0xD9])
        XCTAssertEqual(JPEGOrientation.read(data), 1)
        let patched = try XCTUnwrap(JPEGOrientation.set(data, orientation: 6))
        XCTAssertEqual(JPEGOrientation.read(patched), 6)
        // Make is still readable, and the rational value is still where the entry points.
        XCTAssertNotNil(patched.range(of: Data("Can".utf8)))
        XCTAssertEqual(Array(patched.suffix(7)), [0xFF, 0xDA, 0x00, 0x02, 0x55, 0xFF, 0xD9])
        let again = try XCTUnwrap(JPEGOrientation.set(patched, orientation: 3))
        XCTAssertEqual(again.count, patched.count, "second change patches in place")
        XCTAssertEqual(JPEGOrientation.read(again), 3)
    }
}
