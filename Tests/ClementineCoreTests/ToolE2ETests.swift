#if canImport(AppKit) && canImport(PDFKit)
import AppKit
import ClementineCore
import CoreImage
import ImageIO
import PDFKit
import XCTest

/// End-to-end tests for the ⇧⌥ tools.
final class ToolE2ETests: XCTestCase {
    private var tmp: TempDirectory!
    private var engines: Engines!

    override func setUpWithError() throws {
        tmp = try TempDirectory(prefix: "clem-tools")
        engines = Engines(settings: ConversionSettings(),
                          planner: OutputPlanner(location: .besideOriginal, downloads: tmp.file("Downloads")))
    }

    override func tearDownWithError() throws { tmp.remove() }

    // MARK: Helpers

    func run(_ tool: Tool, _ urls: [URL], _ options: ToolOptions = .none) async throws -> JobResult {
        let job = Job(JobRequest(inputs: urls.map(InputItem.inspect), operation: .tool(tool), options: options))
        return try await engines.execute(job)
    }

    func output(_ tool: Tool, _ urls: [URL], _ options: ToolOptions = .none) async throws -> URL {
        let result = try await run(tool, urls, options)
        return try XCTUnwrap(result.outputs.first)
    }

    func requireFFmpeg() throws {
        guard FFmpegLocator.isAvailable else { throw XCTSkip("needs ffmpeg") }
    }

    func size(_ url: URL) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
    }

    /// A photo-like JPEG (gradients and noise) that compresses realistically.
    func photo(_ name: String = "photo.jpg", width: Int = 1600, height: Int = 1200, format: Format = .jpg) throws -> URL {
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: CGFloat(width), y: CGFloat(height)),
            "inputColor0": CIColor(red: 0.9, green: 0.4, blue: 0.1), "inputColor1": CIColor(red: 0.1, green: 0.3, blue: 0.8),
        ])!.outputImage!.cropped(to: noise.extent)
        let blended = noise.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.25)])
            .composited(over: gradient)
        let cg = CIContext().createCGImage(blended, from: noise.extent)!
        let url = tmp.file(name)
        try ImageCodec.write(cg, as: format, to: url, properties: [kCGImageDestinationLossyCompressionQuality as String: 0.95])
        return url
    }

    func media(_ name: String, _ args: [String]) async throws -> URL {
        let url = tmp.file(name)
        let result = try await ProcessRunner.run(FFmpegLocator.ffmpeg!, args + ["-y", url.path])
        XCTAssertEqual(result.status, 0, result.stderrString)
        return url
    }

    func video(_ name: String = "clip.mp4", seconds: Int = 4, size: String = "320x240") async throws -> URL {
        try await media(name, ["-f", "lavfi", "-i", "testsrc2=size=\(size):rate=25:duration=\(seconds)",
                               "-f", "lavfi", "-i", "sine=frequency=330:duration=\(seconds)",
                               "-c:v", "mpeg4", "-q:v", "2", "-c:a", "aac_at", "-b:a", "128k", "-shortest"])
    }

    func audio(_ name: String = "tone.m4a", seconds: Int = 4, volume: Double = 0.3) async throws -> URL {
        try await media(name, ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
                               "-af", "volume=\(volume)", "-metadata", "title=Secret", "-c:a", "aac_at", "-b:a", "192k"])
    }

    // MARK: Compress

    func testCompressJPEGToExactSize() async throws {
        let input = try photo()
        XCTAssertGreaterThan(size(input), 400_000)
        let out = try await output(.compress, [input], .compress(CompressOptions(targetBytes: 150_000)))
        XCTAssertEqual(out.lastPathComponent, "photo (compressed).jpg")
        XCTAssertLessThanOrEqual(size(out), 150_000)
        XCTAssertGreaterThan(size(out), 60_000, "should use most of the budget")
    }

    func testCompressToTinySizeDownscales() async throws {
        let input = try photo()
        let out = try await output(.compress, [input], .compress(CompressOptions(targetBytes: 20_000)))
        XCTAssertLessThanOrEqual(size(out), 20_000)
        let decoded = try ImageCodec.decode(out)
        XCTAssertLessThan(decoded.width, 1600)
    }

    func testCompressPresetsShrink() async throws {
        let input = try photo()
        for preset in [CompressOptions.Preset.high, .medium, .small] {
            let out = try await output(.compress, [input], .compress(CompressOptions(preset: preset)))
            XCTAssertLessThan(size(out), size(input), "\(preset)")
            try FileManager.default.removeItem(at: out)
        }
    }

    func testCompressPNG() async throws {
        try requireFFmpeg()
        let input = try photo("shot.png", width: 800, height: 600, format: .png)
        let target = size(input) / 3
        let out = try await output(.compress, [input], .compress(CompressOptions(targetBytes: target)))
        XCTAssertEqual(out.pathExtension, "png")
        XCTAssertLessThanOrEqual(size(out), target)
    }

    func testCompressVideoToExactSize() async throws {
        try requireFFmpeg()
        let input = try await video(seconds: 6)
        let target: Int64 = 180_000
        let out = try await output(.compress, [input], .compress(CompressOptions(targetBytes: target)))
        XCTAssertEqual(out.pathExtension, "mp4")
        XCTAssertLessThanOrEqual(size(out), target * 105 / 100, "within 5% of the target")
        let info = try await MediaProbe.probe(out)
        XCTAssertTrue(info.hasVideo)
        XCTAssertTrue(info.hasAudio)
    }

    func testCompressAudioToExactSize() async throws {
        try requireFFmpeg()
        let input = try await audio(seconds: 10)
        let out = try await output(.compress, [input], .compress(CompressOptions(targetBytes: 60_000)))
        XCTAssertLessThanOrEqual(size(out), 66_000)
    }

    func testCompressPDF() async throws {
        let pdf = tmp.file("scan.pdf")
        let img = try photo("page.jpg", width: 2400, height: 3200)
        let item = InputItem.inspect(img)
        try PDFTools.merge([item, item], to: pdf, pageSize: CreatePDFOptions(pageSize: .a4))
        let out = try await output(.compress, [pdf], .compress(CompressOptions(preset: .small)))
        XCTAssertNotNil(PDFDocument(url: out))
        XCTAssertLessThan(size(out), size(pdf))
    }

    // MARK: Resize / rotate

    func testResizeImage() async throws {
        let input = try photo(width: 1000, height: 800)
        let out = try await output(.resize, [input], .resize(ResizeOptions(mode: .percent(50))))
        let d = try ImageCodec.decode(out)
        XCTAssertEqual(d.width, 500)
        XCTAssertEqual(d.height, 400)
        let fit = try await output(.resize, [input], .resize(ResizeOptions(mode: .fit(width: 300, height: 300))))
        let f = try ImageCodec.decode(fit)
        XCTAssertEqual(f.width, 300)
        XCTAssertEqual(f.height, 240)
    }

    func testRotateJPEGIsLossless() async throws {
        let input = try photo(width: 400, height: 300)
        let out = try await output(.rotate, [input], .rotate(RotateOptions(turn: .right)))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
        XCTAssertEqual(props[kCGImagePropertyOrientation as String] as? Int, 6)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 400, "pixels untouched")
        let shown = try ImageCodec.decode(out)
        XCTAssertEqual(shown.width, 300)
        XCTAssertEqual(shown.height, 400)
    }

    func testRotatePNGRedraws() async throws {
        let input = try photo("p.png", width: 40, height: 20, format: .png)
        let out = try await output(.rotate, [input], .rotate(RotateOptions(turn: .left)))
        let d = try ImageCodec.decode(out)
        XCTAssertEqual(d.width, 20)
        XCTAssertEqual(d.height, 40)
    }

    func testRotateVideoWithoutReencoding() async throws {
        try requireFFmpeg()
        let input = try await video()
        let out = try await output(.rotate, [input], .rotate(RotateOptions(turn: .right)))
        let info = try await MediaProbe.probe(out)
        XCTAssertEqual(info.video?.codec, "mpeg4", "stream copied")
        XCTAssertEqual(info.displaySize?.width, 240)
        XCTAssertEqual(info.displaySize?.height, 320)
    }

    func testResizeVideo() async throws {
        try requireFFmpeg()
        let input = try await video(size: "640x360")
        let out = try await output(.resize, [input], .resize(ResizeOptions(mode: .percent(50))))
        let info = try await MediaProbe.probe(out)
        XCTAssertEqual(info.video?.width, 320)
        XCTAssertEqual(info.video?.height, 180)
    }

    // MARK: PDF tools

    func makePDF(_ name: String, pages: Int) throws -> URL {
        let url = tmp.file(name)
        let doc = PDFDocument()
        for i in 0..<pages {
            let image = NSImage(size: NSSize(width: 200, height: 280), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                ("Page \(i + 1)" as NSString).draw(at: NSPoint(x: 20, y: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
                return true
            }
            doc.insert(PDFPage(image: image)!, at: doc.pageCount)
        }
        XCTAssertTrue(doc.write(to: url))
        return url
    }

    func testMergeAndCreatePDF() async throws {
        let a = try makePDF("a.pdf", pages: 2), b = try makePDF("b.pdf", pages: 3)
        let merged = try await output(.mergePDF, [a, b])
        XCTAssertEqual(merged.lastPathComponent, "Merged.pdf")
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, 5)
        let img = try photo("pic.jpg", width: 300, height: 200)
        let created = try await output(.createPDF, [img, a], .createPDF(CreatePDFOptions(pageSize: .a4, margin: 18)))
        XCTAssertEqual(created.lastPathComponent, "Images.pdf")
        XCTAssertEqual(PDFDocument(url: created)?.pageCount, 3)
    }

    func testSplitPDF() async throws {
        let pdf = try makePDF("book.pdf", pages: 5)
        let folder = try await output(.split, [pdf], .splitPDF(SplitPDFOptions(mode: .ranges("1-2, 3-"))))
        XCTAssertEqual(folder.lastPathComponent, "book (split)")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["book part 1.pdf", "book part 2.pdf"])
        XCTAssertEqual(PDFDocument(url: folder.appendingPathComponent("book part 2.pdf"))?.pageCount, 3)
    }

    func testRotateAndStripPDF() async throws {
        let pdf = try makePDF("doc.pdf", pages: 2)
        let rotated = try await output(.rotate, [pdf], .rotate(RotateOptions(turn: .right)))
        XCTAssertEqual(PDFDocument(url: rotated)?.page(at: 0)?.rotation, 90)
        let stripped = try await output(.removeMetadata, [pdf])
        XCTAssertEqual(stripped.lastPathComponent, "doc (no metadata).pdf")
        XCTAssertNotNil(PDFDocument(url: stripped))
    }

    func testReadQRInPDF() async throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("CLEMENTINE-PDF".utf8), forKey: "inputMessage")
        let ci = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let padded = ci.composited(over: CIImage(color: .white).cropped(to: ci.extent.insetBy(dx: -40, dy: -40)))
        let cg = try XCTUnwrap(CIContext().createCGImage(padded, from: padded.extent))
        let png = tmp.file("qr.png")
        try ImageCodec.write(cg, as: .png, to: png)
        let pdf = tmp.file("qr.pdf")
        try PDFTools.merge([InputItem.inspect(png)], to: pdf)
        let result = try await run(.readQR, [pdf])
        XCTAssertEqual(result.text, "CLEMENTINE-PDF")
    }

    // MARK: Media tools

    func testMuteAndExtractAudio() async throws {
        try requireFFmpeg()
        let input = try await video()
        let muted = try await output(.mute, [input])
        XCTAssertEqual(muted.lastPathComponent, "clip (muted).mp4")
        let mutedInfo = try await MediaProbe.probe(muted)
        XCTAssertFalse(mutedInfo.hasAudio)
        XCTAssertTrue(mutedInfo.hasVideo)
        let extracted = try await output(.extractAudio, [input], .extractAudio(.m4a))
        XCTAssertEqual(extracted.pathExtension, "m4a")
        let info = try await MediaProbe.probe(extracted)
        XCTAssertTrue(info.hasAudio)
        XCTAssertFalse(info.hasVideo)
    }

    func testSpeed() async throws {
        try requireFFmpeg()
        let input = try await audio(seconds: 4)
        let out = try await output(.speed, [input], .speed(2))
        XCTAssertEqual(out.lastPathComponent, "tone (2x).m4a")
        let info = try await MediaProbe.probe(out)
        XCTAssertEqual(info.duration ?? 0, 2, accuracy: 0.25)
        let clip = try await video(seconds: 2)
        let slow = try await output(.speed, [clip], .speed(0.5))
        let vinfo = try await MediaProbe.probe(slow)
        XCTAssertEqual(vinfo.duration ?? 0, 4, accuracy: 0.4)
    }

    func testNormalizeHitsTarget() async throws {
        try requireFFmpeg()
        let input = try await audio(seconds: 6, volume: 0.05)
        let result = try await run(.normalize, [input], .normalize(NormalizeOptions(integratedLUFS: -16)))
        let out = try XCTUnwrap(result.outputs.first)
        XCTAssertNotNil(result.note)
        let measure = try await ProcessRunner.run(FFmpegLocator.ffmpeg!, ["-nostdin", "-i", out.path, "-af",
                                                                           "loudnorm=print_format=json", "-f", "null", "-"])
        let loudness = try XCTUnwrap(MediaTools.parseLoudnorm(measure.stderrString))
        XCTAssertEqual(loudness.integrated, -16, accuracy: 1.5)
    }

    func testChannelsMono() async throws {
        try requireFFmpeg()
        let input = try await audio()
        let out = try await output(.channels, [input], .channels(ChannelOptions(mode: .mono)))
        XCTAssertEqual(out.lastPathComponent, "tone (mono).m4a")
        let info = try await MediaProbe.probe(out)
        XCTAssertEqual(info.audio.first?.channels, 1)
    }

    func testStripAudioMetadata() async throws {
        try requireFFmpeg()
        let input = try await audio()
        let before = try await MediaProbe.probe(input)
        XCTAssertEqual(before.tags["title"], "Secret")
        let out = try await output(.removeMetadata, [input])
        let after = try await MediaProbe.probe(out)
        XCTAssertNil(after.tags["title"])
    }

    func testSplitAndJoinMedia() async throws {
        try requireFFmpeg()
        let input = try await video(seconds: 6)
        let folder = try await output(.split, [input], .splitMedia(SplitMediaOptions(mode: .parts(2))))
        let parts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(parts.map(\.lastPathComponent), ["clip part 1.mp4", "clip part 2.mp4"])
        let joined = try await output(.join, parts)
        XCTAssertEqual(joined.lastPathComponent, "Joined.mp4")
        let info = try await MediaProbe.probe(joined)
        XCTAssertEqual(info.duration ?? 0, 6, accuracy: 1)

        // Different sizes force a re-encode to the first clip's size.
        let other = try await video("wide.mp4", seconds: 2, size: "480x200")
        let mixed = try await output(.join, [input, other])
        let mixedInfo = try await MediaProbe.probe(mixed)
        XCTAssertEqual(mixedInfo.video?.width, 320)
        XCTAssertEqual(mixedInfo.duration ?? 0, 8, accuracy: 1)
    }
}
#endif
