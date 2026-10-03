#if canImport(AppKit) && canImport(PDFKit)
import AppKit
import ClementineCore
import ImageIO
import PDFKit
import XCTest

/// Exports from the image and PDF editors (the state an editor hands to the
/// job queue, rendered at full resolution).
final class EditorExportTests: XCTestCase {
    private var tmp: TempDirectory!
    private var engines: Engines!

    override func setUpWithError() throws {
        tmp = try TempDirectory(prefix: "clem-editors")
        engines = Engines(settings: ConversionSettings(),
                          planner: OutputPlanner(location: .besideOriginal, downloads: tmp.file("Downloads")))
    }

    override func tearDownWithError() throws { tmp.remove() }

    // MARK: Helpers

    func export(_ tool: Tool, _ urls: [URL], _ options: ToolOptions) async throws -> URL {
        let job = Job(JobRequest(inputs: urls.map(InputItem.inspect), operation: .tool(tool), options: options))
        let result = try await engines.execute(job)
        return try XCTUnwrap(result.outputs.first)
    }

    struct Pixel: Equatable, CustomStringConvertible {
        var r: Int, g: Int, b: Int, a: Int
        var description: String { "rgba(\(r), \(g), \(b), \(a))" }

        func near(_ o: Pixel, _ tolerance: Int = 14) -> Bool {
            abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance && abs(a - o.a) <= tolerance
        }

        static let red = Pixel(r: 255, g: 0, b: 0, a: 255), green = Pixel(r: 0, g: 255, b: 0, a: 255)
        static let blue = Pixel(r: 0, g: 0, b: 255, a: 255), white = Pixel(r: 255, g: 255, b: 255, a: 255)
        static let black = Pixel(r: 0, g: 0, b: 0, a: 255)
    }

    /// 400 × 300 with four quadrants: red top-left, green top-right, blue
    /// bottom-left, white bottom-right.
    func quadrants(_ name: String = "quad.png", format: Format = .png, properties: [String: Any] = [:]) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: ImageCodec.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Core Graphics has a bottom-left origin: the top half is y ≥ 150.
        let fills: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: 150, width: 200, height: 150), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: 200, y: 150, width: 200, height: 150), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: 200, height: 150), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: 200, y: 0, width: 200, height: 150), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
        ]
        for (rect, color) in fills {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }
        let url = tmp.file(name)
        try ImageCodec.write(try XCTUnwrap(ctx.makeImage()), as: format, to: url, properties: properties)
        return url
    }

    /// sRGB pixel at (x, y), top-left origin, orientation applied.
    func pixel(_ url: URL, _ x: Int, _ y: Int) throws -> Pixel {
        try pixel(ImageCodec.decode(url).image, x, y)
    }

    func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> Pixel {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let ctx = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: ImageCodec.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return Pixel(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]), a: Int(bytes[3]))
    }

    func pixelSize(_ url: URL) throws -> (Int, Int) {
        let image = try ImageCodec.decode(url).image
        return (image.width, image.height)
    }

    func assertPixel(_ url: URL, _ x: Int, _ y: Int, _ expected: Pixel, tolerance: Int = 14,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let p = try pixel(url, x, y)
        XCTAssertTrue(p.near(expected, tolerance), "pixel (\(x), \(y)) is \(p), expected \(expected)", file: file, line: line)
    }

    // MARK: Crop

    func testCropUsesTopLeftPixelCoordinates() async throws {
        let out = try await export(.crop, [try quadrants()], .crop(CGRect(x: 200, y: 0, width: 200, height: 150)))
        XCTAssertEqual(out.lastPathComponent, "quad (cropped).png")
        let (w, h) = try pixelSize(out)
        XCTAssertEqual(w, 200)
        XCTAssertEqual(h, 150)
        try assertPixel(out, 5, 5, .green)
        try assertPixel(out, 195, 145, .green)
    }

    func testCropFollowsDisplayedOrientation() async throws {
        // Stored landscape, shown rotated 90° clockwise (EXIF 6): displayed
        // as 300 × 400 with blue top-left, red top-right.
        let input = try quadrants("turned.jpg", format: .jpg, properties: [kCGImagePropertyOrientation as String: 6])
        try assertPixel(input, 75, 100, .blue, tolerance: 30)
        try assertPixel(input, 225, 100, .red, tolerance: 30)
        let out = try await export(.crop, [input], .crop(CGRect(x: 150, y: 0, width: 150, height: 200)))
        let (w, h) = try pixelSize(out)
        XCTAssertEqual(w, 150)
        XCTAssertEqual(h, 200)
        try assertPixel(out, 75, 100, .red, tolerance: 30)
    }

    func testCropOutsideTheImageIsClampedOrRejected() async throws {
        let input = try quadrants()
        let out = try await export(.crop, [input], .crop(CGRect(x: 300, y: 200, width: 500, height: 500)))
        let (w, h) = try pixelSize(out)
        XCTAssertEqual(w, 100)
        XCTAssertEqual(h, 100)
        do {
            _ = try await export(.crop, [input], .crop(CGRect(x: 900, y: 900, width: 10, height: 10)))
            XCTFail("an empty crop should fail")
        } catch {}
    }

    // MARK: Adjust

    func testAdjustAppliesAtFullResolution() async throws {
        var params = AdjustParameters()
        params.saturation = -1
        let out = try await export(.adjust, [try quadrants()], .adjust(params))
        XCTAssertEqual(out.lastPathComponent, "quad (adjusted).png")
        let (w, h) = try pixelSize(out)
        XCTAssertEqual(w, 400)
        XCTAssertEqual(h, 300)
        let p = try pixel(out, 50, 50)
        XCTAssertLessThan(max(p.r, p.g, p.b) - min(p.r, p.g, p.b), 12, "desaturated red should be grey, got \(p)")

        var brighter = AdjustParameters()
        brighter.exposure = 1
        let lit = try await export(.adjust, [try grey()], .adjust(brighter))
        let b = try pixel(lit, 50, 50)
        XCTAssertGreaterThan(b.g, 150, "+1 EV should lift mid grey, got \(b)")
    }

    /// 200 × 200 mid grey.
    func grey(_ name: String = "grey.png") throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: ImageCodec.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let url = tmp.file(name)
        try ImageCodec.write(try XCTUnwrap(ctx.makeImage()), as: .png, to: url)
        return url
    }

    // MARK: Annotate

    func testAnnotationsLandWhereTheyWereDrawn() async throws {
        var box = Annotation(kind: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 100)],
                             color: .black, lineWidth: 4)
        box.filled = true
        let line = Annotation(kind: .line, points: [CGPoint(x: 250, y: 200), CGPoint(x: 390, y: 200)],
                              color: RGBA(1, 0, 0), lineWidth: 10)
        var label = Annotation(kind: .text, points: [CGPoint(x: 210, y: 20)], color: .black, lineWidth: 4)
        label.text = "Hi"
        label.fontSize = 60
        let out = try await export(.annotate, [try quadrants()], .annotate([box, line, label]))
        XCTAssertEqual(out.lastPathComponent, "quad (annotated).png")
        try assertPixel(out, 60, 60, .black)
        try assertPixel(out, 150, 120, .red) // untouched
        try assertPixel(out, 320, 200, .red) // the line, over white
        try assertPixel(out, 320, 260, .white) // below the line
        // The text darkens part of the green quadrant near its origin.
        let image = try ImageCodec.decode(out).image
        var dark = 0
        for y in stride(from: 25, to: 90, by: 3) {
            for x in stride(from: 212, to: 290, by: 3) {
                if try pixel(image, x, y).g < 128 { dark += 1 }
            }
        }
        XCTAssertGreaterThan(dark, 10, "text should be drawn below and right of its origin")
    }

    // MARK: Redact

    func testRedactionsCoverTheirAreaAndDropMetadata() async throws {
        let gps: [String: Any] = [kCGImagePropertyGPSLatitude as String: 48.85, kCGImagePropertyGPSLatitudeRef as String: "N",
                                  kCGImagePropertyGPSLongitude as String: 2.35, kCGImagePropertyGPSLongitudeRef as String: "E"]
        let input = try quadrants("secret.jpg", format: .jpg, properties: [kCGImagePropertyGPSDictionary as String: gps])
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(input as CFURL, nil)!, 0, nil) as? [String: Any]
        XCTAssertNotNil(props?[kCGImagePropertyGPSDictionary as String], "fixture should carry GPS")

        var solid = Redaction(rect: CGRect(x: 0, y: 0, width: 200, height: 150), style: .solid)
        solid.color = .black
        let blur = Redaction(rect: CGRect(x: 150, y: 100, width: 100, height: 100), style: .blur)
        let out = try await export(.redact, [input], .redact([solid, blur]))
        XCTAssertEqual(out.lastPathComponent, "secret (redacted).jpg")
        try assertPixel(out, 60, 60, .black, tolerance: 20)
        try assertPixel(out, 300, 60, .green, tolerance: 30)
        // Inside the blurred square the four colours mix.
        let mixed = try pixel(out, 205, 155)
        XCTAssertFalse(mixed.near(.white, 30), "blurred area should not stay pure white, got \(mixed)")
        let outProps = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil) as? [String: Any]
        XCTAssertNil(outProps?[kCGImagePropertyGPSDictionary as String], "redacted copies must not keep GPS")
    }

    // MARK: Background

    func testBackgroundAddsPaddingAndSavesPNG() async throws {
        var style = FrameStyle()
        style.padding = 0.08
        style.shadow = 0
        style.cornerRadius = 0
        style.fill = .solid(.black)
        let input = try quadrants("framed.jpg", format: .jpg)
        let out = try await export(.background, [input], .background(style))
        XCTAssertEqual(out.lastPathComponent, "framed (framed).png")
        let (w, h) = try pixelSize(out)
        XCTAssertEqual(w, 464)
        XCTAssertEqual(h, 364)
        try assertPixel(out, 4, 4, .black)
        try assertPixel(out, 32 + 100, 32 + 75, .red, tolerance: 30)
        try assertPixel(out, 32 + 300, 32 + 225, .white, tolerance: 30)

        style.fill = .none
        style.aspect = .square
        let square = try await export(.background, [try quadrants()], .background(style))
        let (sw, sh) = try pixelSize(square)
        XCTAssertEqual(sw, 464)
        XCTAssertEqual(sh, 464)
        XCTAssertEqual(try pixel(square, 2, 2).a, 0, "no fill should leave the margin transparent")
    }

    // MARK: Collage

    func testCollageGridLayout() async throws {
        let inputs = [try quadrants("a.png"), try quadrants("b.png"), try quadrants("c.png")]
        var style = CollageStyle()
        style.layout = .grid
        style.outputWidth = 1200
        style.padding = 24
        style.spacing = 12
        style.cornerRadius = 0
        style.background = .white
        let out = try await export(.collage, inputs, .collage(style))
        XCTAssertEqual(out.lastPathComponent, "Collage.png")
        let (w, h) = try pixelSize(out)
        XCTAssertEqual(w, 1200)
        XCTAssertEqual(h, 1200)
        try assertPixel(out, 5, 5, .white)
        try assertPixel(out, 124, 124, .red, tolerance: 20)
        // The fourth cell is empty.
        try assertPixel(out, 900, 900, .white)
    }

    func testCollageLayoutsStayValidWithExtremeSettings() {
        let sizes = Array(repeating: CGSize(width: 400, height: 300), count: 36)
        for layout in CollageStyle.Layout.allCases {
            var style = CollageStyle()
            style.layout = layout
            style.outputWidth = 1200
            style.spacing = 80
            style.padding = 160
            let (canvas, cells) = Collage.cells(for: sizes, style: style)
            XCTAssertEqual(cells.count, 36, "\(layout)")
            XCTAssertGreaterThan(canvas.height, 0, "\(layout)")
            for cell in cells {
                XCTAssertGreaterThan(cell.width, 0, "\(layout)")
                XCTAssertGreaterThan(cell.height, 0, "\(layout)")
            }
        }
    }

    // MARK: Organize PDF

    /// Pages of increasing width so they can be told apart.
    func pdf(_ name: String = "doc.pdf", pages: Int = 3) throws -> URL {
        let url = tmp.file(name)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: nil, nil))
        for i in 0..<pages {
            var box = CGRect(x: 0, y: 0, width: 300 + 100 * i, height: 400)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 50, height: 50))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    func testOrganizeReordersRotatesAndInserts() async throws {
        let doc = try pdf()
        let image = try quadrants("insert.png")
        let pages = [PageRef(source: 0, page: 2, rotation: 90), PageRef(source: 1, page: 0), PageRef(source: 0, page: 0)]
        let out = try await export(.organizePDF, [doc, image], .organizePDF(pages))
        XCTAssertEqual(out.lastPathComponent, "doc (organized).pdf")
        let result = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.page(at: 0)?.bounds(for: .mediaBox).width, 500)
        XCTAssertEqual(result.page(at: 0)?.rotation, 90)
        XCTAssertEqual(result.page(at: 2)?.bounds(for: .mediaBox).width, 300)
        XCTAssertEqual(result.page(at: 2)?.rotation, 0)
        // The source is never touched.
        XCTAssertEqual(PDFDocument(url: doc)?.pageCount, 3)
    }

    func testOrganizeWithNoPagesFails() async throws {
        do {
            _ = try await export(.organizePDF, [try pdf()], .organizePDF([]))
            XCTFail("saving zero pages should fail")
        } catch {}
    }

    // MARK: Metadata

    func testMetadataEditsImageCopy() async throws {
        let input = try quadrants("tagged.jpg", format: .jpg, properties: [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Clementine",
                                                       kCGImagePropertyTIFFModel as String: "Test"],
        ])
        let item = InputItem.inspect(input)
        let rows = await MetadataInspector.read(item)
        XCTAssertTrue(rows.contains { $0.key == "Make" && $0.value == "Clementine" }, "inspector should list TIFF Make")
        XCTAssertTrue(rows.contains { $0.group == "File" && $0.key == "Name" })

        var fields = EditableMetadata()
        fields.title = "Harbour at dawn"
        fields.author = "K."
        fields.copyright = "© 2026"
        let out = try await export(.metadata, [input], .metadata(fields))
        XCTAssertEqual(out.lastPathComponent, "tagged (edited).jpg")
        let edited = MetadataInspector.editable(InputItem.inspect(out), from: await MetadataInspector.read(InputItem.inspect(out)))
        XCTAssertEqual(edited.title, "Harbour at dawn")
        XCTAssertEqual(edited.author, "K.")
        XCTAssertEqual(edited.copyright, "© 2026")
        // The original keeps its own metadata.
        let original = MetadataInspector.editable(item, from: rows)
        XCTAssertEqual(original.title, "")
    }

    func testMetadataEditsPDFCopy() async throws {
        let input = try pdf("report.pdf", pages: 1)
        var fields = EditableMetadata()
        fields.title = "Quarterly report"
        fields.author = "Finance"
        fields.comment = "Draft"
        let out = try await export(.metadata, [input], .metadata(fields))
        let attrs = try XCTUnwrap(PDFDocument(url: out)?.documentAttributes)
        XCTAssertEqual(attrs[PDFDocumentAttribute.titleAttribute] as? String, "Quarterly report")
        XCTAssertEqual(attrs[PDFDocumentAttribute.authorAttribute] as? String, "Finance")
        XCTAssertEqual(attrs[PDFDocumentAttribute.subjectAttribute] as? String, "Draft")
    }

    func testMetadataEditsAudioTags() async throws {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { throw XCTSkip("needs ffmpeg") }
        let input = tmp.file("song.m4a")
        let made = try await ProcessRunner.run(ffmpeg, ["-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                                                        "-metadata", "title=Old", "-c:a", "aac_at", "-y", input.path])
        XCTAssertEqual(made.status, 0, made.stderrString)
        var fields = EditableMetadata()
        fields.title = "New title"
        fields.author = "Someone"
        let out = try await export(.metadata, [input], .metadata(fields))
        let info = try await MediaProbe.probe(out)
        XCTAssertEqual(info.tags.first { $0.key.lowercased() == "title" }?.value, "New title")
        XCTAssertEqual(info.tags.first { $0.key.lowercased() == "artist" }?.value, "Someone")
    }
}
#endif
