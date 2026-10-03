import ClementineCore
import XCTest

final class ZipDocxTests: XCTestCase {
    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testZipIsReadableByUnzip() throws {
        var zip = ZipWriter()
        zip.add("hello.txt", "Hello, world!")
        zip.add("dir/repeat.txt", String(repeating: "clementine ", count: 500))
        zip.add("ünïcødé.txt", "ok")
        let data = zip.finish()
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let url = tmp.file("t.zip")
        try data.write(to: url)
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        guard FileManager.default.isExecutableFile(atPath: unzip.path) else { throw XCTSkip("no unzip here") }
        let p = Process()
        p.executableURL = unzip
        p.arguments = ["-tq", url.path]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "unzip -t failed")
    }

    func testDocxStructure() throws {
        var doc = DOCXDocument(title: "T & <Test>")
        doc.blocks = [
            .paragraph([.init("Title", bold: true)], heading: 1),
            .paragraph([.init("Line 1\nLine 2\tTabbed & <escaped>"), .init(" italic", italic: true)]),
            .pageBreak,
            .image(Data([0x89, 0x50, 0x4E, 0x47]), format: "png", width: 100, height: 50),
        ]
        let data = DOCXWriter.data(for: doc)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B])
        // The package parts are present (stored names are plain UTF-8).
        let text = String(decoding: data, as: UTF8.self)
        for part in ["[Content_Types].xml", "word/document.xml", "word/styles.xml", "word/media/image1.png",
                     "word/_rels/document.xml.rels", "_rels/.rels"] {
            XCTAssertTrue(text.contains(part), "missing \(part)")
        }
        XCTAssertEqual(DOCXWriter.escape("a<b>&\u{1}c"), "a&lt;b&gt;&amp;c")
    }

    func testFittedImageSize() {
        let doc = DOCXDocument(pageSize: .letter, margin: 72)
        let (w, h) = doc.fittedImageSize(width: 4000, height: 3000)
        XCTAssertEqual(w, 468, accuracy: 0.5)
        XCTAssertEqual(h, 351, accuracy: 0.5)
    }
}
