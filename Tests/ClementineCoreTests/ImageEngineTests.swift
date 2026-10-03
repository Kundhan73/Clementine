#if canImport(ImageIO) && canImport(CoreImage)
import ClementineCore
import CoreGraphics
import CoreImage
import ImageIO
import XCTest

/// End-to-end image conversions through `Engines`, with generated fixtures.
final class ImageEngineTests: XCTestCase {
    private var tmp: TempDirectory!
    private var engines: Engines!

    override func setUpWithError() throws {
        tmp = try TempDirectory(prefix: "clem-img")
        engines = Engines(settings: ConversionSettings(),
                          planner: OutputPlanner(location: .besideOriginal, downloads: tmp.file("Downloads")))
    }

    override func tearDownWithError() throws { tmp.remove() }

    // MARK: Fixtures

    static func drawing(width: Int = 320, height: Int = 240, alpha: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: ImageCodec.sRGB,
                            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                              : CGImageAlphaInfo.noneSkipLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if alpha { ctx.clear(rect) } else {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            ctx.fill(rect)
        }
        ctx.setFillColor(CGColor(red: 0.96, green: 0.5, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: rect.insetBy(dx: CGFloat(width) * 0.2, dy: CGFloat(height) * 0.2))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width) * 0.25, height: CGFloat(height) * 0.25))
        return ctx.makeImage()!
    }

    /// Writes a fixture in `format`; returns nil if this Mac can't produce it.
    func fixture(_ format: Format, alpha: Bool = false, name: String? = nil) async throws -> URL? {
        let url = tmp.file("\(name ?? "fixture-\(format.rawValue)").\(format.fileExtension)")
        if format == .svg {
            try Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="300" height="200" viewBox="0 0 300 200">
            <rect width="300" height="200" fill="#3366cc"/><circle cx="150" cy="100" r="70" fill="#f58220"/></svg>
            """.utf8).write(to: url)
            return url
        }
        guard ImageCodec.canEncodeNatively(format) || ((format == .webp || format == .avif) && FFmpegLocator.isAvailable) else {
            return nil
        }
        let decoded = DecodedImage(image: Self.drawing(alpha: alpha), metadata: [:], hasAlpha: alpha, dpi: 72)
        try await ImageCodec.encode(decoded, as: format, to: url, settings: ConversionSettings())
        return url
    }

    func require(_ format: Format, alpha: Bool = false, name: String) async throws -> URL {
        guard let url = try await fixture(format, alpha: alpha, name: name) else {
            throw XCTSkip("\(format.displayName) can't be written on this Mac")
        }
        return url
    }

    func output(_ url: URL, _ operation: JobOperation) async throws -> URL {
        let result = try await run(url, operation)
        return try XCTUnwrap(result.outputs.first, "no output")
    }

    func run(_ url: URL, _ operation: JobOperation) async throws -> JobResult {
        let job = Job(JobRequest(inputs: [InputItem.inspect(url)], operation: operation))
        return try await engines.execute(job)
    }

    func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = p[kCGImagePropertyPixelWidth as String] as? Int,
              let h = p[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        return (w, h)
    }

    // MARK: Tests

    func testEveryImagePair() async throws {
        let sources: [Format] = [.jpg, .png, .heic, .webp, .avif, .tiff, .bmp, .gif, .svg]
        var checked = 0
        var skipped: [String] = []
        for source in sources {
            guard let input = try await fixture(source) else { skipped.append("\(source) fixture"); continue }
            for target in ConversionMatrix.targets(for: source) {
                let chip = WheelChip.format(target)
                let item = InputItem.inspect(input)
                guard Engines.isAvailable(chip, for: [item]) else {
                    if target.kind == .image || target == .pdf || target == .docx { skipped.append("\(source)→\(target)") }
                    continue
                }
                let result = try await run(input, .convert(target))
                let out = try XCTUnwrap(result.outputs.first, "\(source)→\(target) produced nothing")
                XCTAssertEqual(out.deletingLastPathComponent().standardizedFileURL, tmp.url.standardizedFileURL)
                XCTAssertEqual(out.pathExtension, target.fileExtension, "\(source)→\(target)")
                let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                XCTAssertGreaterThan(size, 0, "\(source)→\(target) is empty")
                switch target {
                case .pdf:
                    let doc = CGPDFDocument(out as CFURL)
                    XCTAssertEqual(doc?.numberOfPages, 1, "\(source)→PDF")
                case .svg:
                    XCTAssertTrue(try String(contentsOf: out, encoding: .utf8).contains("<svg"))
                case .docx:
                    let head = try Data(contentsOf: out).prefix(2)
                    XCTAssertEqual(Array(head), [0x50, 0x4B], "\(source)→DOCX isn't a zip")
                case .zip:
                    break
                default:
                    let dims = try XCTUnwrap(pixelSize(out), "\(source)→\(target) unreadable")
                    if source == .svg {
                        XCTAssertEqual(Double(dims.0) / Double(dims.1), 1.5, accuracy: 0.01, "SVG aspect ratio")
                    } else {
                        XCTAssertEqual(dims.0, 320, "\(source)→\(target) width")
                        XCTAssertEqual(dims.1, 240, "\(source)→\(target) height")
                    }
                }
                try FileManager.default.removeItem(at: out)
                checked += 1
            }
        }
        print("image pairs checked: \(checked); skipped: \(skipped.joined(separator: ", "))")
        XCTAssertGreaterThan(checked, 40)
    }

    func testNamingCollisionAndSourceUntouched() async throws {
        let input = try await require(.png, name: "photo")
        let before = try Data(contentsOf: input)
        try Data("existing".utf8).write(to: tmp.file("photo.jpg"))
        let result = try await run(input, .convert(.jpg))
        XCTAssertEqual(result.outputs.first?.lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(try Data(contentsOf: input), before, "source was modified")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [], "temporary files left behind")
    }

    func testAlphaFlattensOntoWhiteForJPEG() async throws {
        let input = try await require(.png, alpha: true, name: "alpha")
        let out = try await output(input, .convert(.jpg))
        let decoded = try ImageCodec.decode(out)
        // Top-right corner was transparent: must now be white, not black.
        let pixel = try Self.pixel(decoded.image, x: decoded.width - 2, y: 2)
        XCTAssertGreaterThan(pixel.r, 240)
        XCTAssertGreaterThan(pixel.g, 240)
        XCTAssertGreaterThan(pixel.b, 240)
    }

    func testOrientationIsApplied() async throws {
        let url = tmp.file("rotated.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, Self.drawing(), [kCGImagePropertyOrientation as String: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let out = try await output(url, .convert(.png))
        let dims = try XCTUnwrap(pixelSize(out))
        XCTAssertEqual(dims.0, 240)
        XCTAssertEqual(dims.1, 320)
    }

    func testMetadataKeptByDefault() async throws {
        let url = try writeJPEGWithMetadata(name: "meta")
        let out = try await output(url, .convert(.tiff))
        XCTAssertEqual(exif(out)?[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2024:05:01 10:00:00")
    }

    func testRemoveMetadata() async throws {
        let url = try writeJPEGWithMetadata(name: "private")
        XCTAssertTrue(ImageTools.hasIdentifyingMetadata(url))
        let out = try await output(url, .tool(.removeMetadata))
        XCTAssertEqual(out.lastPathComponent, "private (no metadata).jpg")
        XCTAssertFalse(ImageTools.hasIdentifyingMetadata(out), "metadata survived")
        // Orientation 6 kept visually: still displays as portrait.
        let decoded = try ImageCodec.decode(out)
        XCTAssertEqual(decoded.width, 240)
        XCTAssertEqual(decoded.height, 320)
    }

    func testReadQR() async throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://example.com/clementine".utf8), forKey: "inputMessage")
        let ci = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let padded = ci.composited(over: CIImage(color: .white).cropped(to: ci.extent.insetBy(dx: -40, dy: -40)))
        let cg = try XCTUnwrap(CIContext().createCGImage(padded, from: padded.extent))
        let url = tmp.file("qr.png")
        try ImageCodec.write(cg, as: .png, to: url)
        let result = try await run(url, .tool(.readQR))
        XCTAssertEqual(result.text, "https://example.com/clementine")
        XCTAssertTrue(result.outputs.isEmpty)
    }

    func testMultipleFilesToZip() async throws {
        let a = try await require(.png, name: "a")
        let b = try await require(.jpg, name: "b")
        let job = Job(JobRequest(inputs: [InputItem.inspect(a), InputItem.inspect(b)], operation: .convert(.zip)))
        let result = try await engines.execute(job)
        let out = try XCTUnwrap(result.outputs.first)
        XCTAssertEqual(out.lastPathComponent, "Archive.zip")
        let list = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-l", out.path]).stdoutString
        XCTAssertTrue(list.contains("a.png"))
        XCTAssertTrue(list.contains("b.jpg"))
        XCTAssertFalse(list.contains("__MACOSX"))
    }

    func testSingleFileZipKeepsFullName() async throws {
        let a = try await require(.png, name: "single")
        let out = try await output(a, .convert(.zip))
        XCTAssertEqual(out.lastPathComponent, "single.png.zip")
    }

    // MARK: Helpers

    func writeJPEGWithMetadata(name: String) throws -> URL {
        let url = tmp.file("\(name).jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let props: [String: Any] = [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 51.5, kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 0.12, kCGImagePropertyGPSLongitudeRef as String: "W",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2024:05:01 10:00:00",
                kCGImagePropertyExifLensModel as String: "Test Lens",
            ],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "TestCam"],
        ]
        CGImageDestinationAddImage(dest, Self.drawing(), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func exif(_ url: URL) -> [String: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        return p[kCGImagePropertyExifDictionary as String] as? [String: Any]
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: ImageCodec.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // y counts from the top.
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(buf[0]), Int(buf[1]), Int(buf[2]))
    }
}
#endif
