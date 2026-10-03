#if canImport(AppKit) && canImport(PDFKit)
import AppKit
import ClementineCore
import ImageIO
import PDFKit
import XCTest

/// Runs every (source → target) pair of the conversion matrix end to end on
/// generated fixtures and checks each output. Pairs that this machine can't
/// do (no fixture generator, no encoder) are listed as skipped.
final class MatrixE2ETests: XCTestCase {
    private var tmp: TempDirectory!

    override func setUpWithError() throws {
        tmp = try TempDirectory(prefix: "clem-matrix")
    }

    override func tearDownWithError() throws { tmp.remove() }

    func testEveryPair() async throws {
        let engines = Engines(settings: ConversionSettings(),
                              planner: OutputPlanner(location: .besideOriginal, downloads: tmp.file("Downloads")))
        var fixtures: [Format: URL] = [:]
        var fixtureSkips: [String] = []
        for source in Format.allCases where source != .extract {
            do {
                if let url = try await Fixtures.make(source, in: tmp.url.appendingPathComponent(source.rawValue)) {
                    fixtures[source] = url
                } else {
                    fixtureSkips.append(source.rawValue)
                }
            } catch {
                fixtureSkips.append("\(source.rawValue) (\(error))")
            }
        }

        var passed = 0
        var skipped: [String] = []
        var failures: [String] = []
        for (source, target) in ConversionMatrix.pairs {
            let pair = "\(source.rawValue)→\(target.rawValue)"
            guard let input = fixtures[source] else { skipped.append(pair); continue }
            let item = InputItem.inspect(input)
            guard Engines.isAvailable(.format(target), for: [item]) else {
                skipped.append(pair + " (unavailable here)")
                continue
            }
            do {
                let job = Job(JobRequest(inputs: [item], operation: .convert(target)))
                let result = try await engines.execute(job)
                guard let out = result.outputs.first else { throw JobFailure("no output") }
                try await Verify.output(out, target: target, source: source)
                try? FileManager.default.removeItem(at: out)
                passed += 1
            } catch {
                failures.append("\(pair): \(JobFailure.from(error).description.prefix(300))")
            }
        }
        print("::notice title=Matrix e2e::passed \(passed) of \(ConversionMatrix.pairs.count) pairs; " +
              "no fixture: \(fixtureSkips.joined(separator: ", ")); skipped: \(skipped.count)")
        if !skipped.isEmpty { print("matrix skipped: \(skipped.joined(separator: ", "))") }
        for f in failures { print("::error title=Matrix pair failed::\(f.replacingOccurrences(of: "\n", with: " | "))") }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) pairs failed:\n" + failures.joined(separator: "\n"))
        if FFmpegLocator.isAvailable {
            XCTAssertGreaterThanOrEqual(passed, 188, "fewer than 188 pairs verified")
        }
    }
}

/// Generates small sample files of every format.
enum Fixtures {
    static let sampleText = """
    Clementine test document

    The quick brown fox jumps over the lazy dog. Café, naïve, résumé.

    Second paragraph with a little more text so that pages have content.
    """

    static func make(_ format: Format, in dir: URL) async throws -> URL? {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sample.\(format.fileExtension.isEmpty ? format.rawValue : format.fileExtension)")
        switch format.kind {
        case .image: return try await image(format, url: url)
        case .audio, .video: return try await media(format, url: url)
        case .pdf:
            try TextPaginator.writePDF(styled(pages: 2), to: url, title: "Sample")
            return url
        case .document: return try document(format, url: url)
        case .subtitle: return try subtitle(format, url: url)
        case .archive: return try await archive(format, url: url, dir: dir)
        default: return nil
        }
    }

    static func drawing(width: Int = 256, height: Int = 192) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: ImageCodec.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.97, green: 0.52, blue: 0.08, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    static func image(_ format: Format, url: URL) async throws -> URL? {
        switch format {
        case .svg:
            try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="150"><rect width="200" height="150" fill="#2a6"/><circle cx="100" cy="75" r="50" fill="#f80"/></svg>"##.utf8).write(to: url)
            return url
        case .gif:
            if let ffmpeg = FFmpegLocator.ffmpeg {
                try await run(ffmpeg, ["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=10:duration=0.5", "-y", url.path])
                return url
            }
        case .cameraRaw:
            return nil
        default:
            break
        }
        let decoded = DecodedImage(image: drawing(width: format == .icns || format == .ico ? 256 : 256,
                                                  height: format == .icns || format == .ico ? 256 : 192),
                                   hasAlpha: false)
        let utis: [Format: String] = [.psd: "com.adobe.photoshop-image", .ico: "com.microsoft.ico",
                                      .icns: "com.apple.icns", .jp2: "public.jpeg-2000", .tga: "com.truevision.tga-image"]
        if let uti = utis[format] {
            guard ImageCodec.encodableTypes.contains(uti),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, decoded.image, nil)
            return CGImageDestinationFinalize(dest) ? url : nil
        }
        guard ImageCodec.canEncodeNatively(format) || ((format == .webp || format == .avif) && FFmpegLocator.isAvailable) else {
            return nil
        }
        try await ImageCodec.encode(decoded, as: format, to: url, settings: ConversionSettings())
        return url
    }

    static func media(_ format: Format, url: URL) async throws -> URL? {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { return nil }
        let tone = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1"]
        let picture = ["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=10:duration=1"]
        var args: [String]
        switch format {
        case .mp3: args = tone + ["-c:a", "libmp3lame", "-q:a", "4", "-metadata", "title=Sample"]
        case .m4a: args = tone + ["-c:a", "aac_at", "-b:a", "96k"]
        case .aac: args = tone + ["-c:a", "aac_at", "-b:a", "96k", "-f", "adts"]
        case .wav: args = tone + ["-c:a", "pcm_s16le"]
        case .flac: args = tone + ["-c:a", "flac"]
        case .ogg: args = tone + ["-c:a", "libvorbis", "-q:a", "3"]
        case .opus: args = tone + ["-c:a", "libopus", "-b:a", "64k"]
        case .aiff: args = tone + ["-c:a", "pcm_s16be"]
        case .wma: args = tone + ["-c:a", "wmav2", "-b:a", "96k"]
        case .caf: args = tone + ["-c:a", "alac"]
        case .ac3: args = tone + ["-c:a", "ac3", "-b:a", "128k"]
        case .amr: return nil // no AMR encoder in an LGPL build
        case .mp4, .mov, .m4v:
            args = picture + tone + ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac_at", "-b:a", "96k", "-shortest"]
        case .mkv: args = picture + tone + ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "libvorbis", "-shortest"]
        case .webm: args = picture + tone + ["-c:v", "libvpx-vp9", "-b:v", "200k", "-c:a", "libopus", "-shortest"]
        case .avi: args = picture + tone + ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "libmp3lame", "-shortest"]
        case .wmv: args = picture + tone + ["-c:v", "wmv2", "-c:a", "wmav2", "-shortest"]
        case .flv: args = picture + tone + ["-c:v", "flv1", "-c:a", "libmp3lame", "-ar", "44100", "-shortest"]
        case .mpeg: args = picture + tone + ["-c:v", "mpeg2video", "-c:a", "mp2", "-shortest", "-f", "mpeg"]
        case .threeGP:
            args = ["-f", "lavfi", "-i", "testsrc2=size=176x144:rate=10:duration=1"] + tone +
                ["-c:v", "h263", "-c:a", "aac_at", "-b:a", "64k", "-ar", "44100", "-shortest"]
        case .ts: args = picture + tone + ["-c:v", "mpeg2video", "-c:a", "mp2", "-shortest", "-f", "mpegts"]
        default: return nil
        }
        try await run(ffmpeg, args + ["-y", url.path])
        return url
    }

    static func styled(pages: Int = 1) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "Clementine test document\n",
                                      attributes: [.font: NSFont.boldSystemFont(ofSize: 22)]))
        out.append(NSAttributedString(string: "The quick brown fox jumps over the lazy dog. ",
                                      attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        out.append(NSAttributedString(string: "Italic words.\n",
                                      attributes: [.font: NSFont(descriptor: NSFont.systemFont(ofSize: 12).fontDescriptor
                                                                    .withSymbolicTraits(.italic), size: 12)!]))
        let filler = String(repeating: "More text to fill the page. ", count: 40) + "\n"
        let lines = pages > 1 ? 8 : 1
        for _ in 0..<lines {
            out.append(NSAttributedString(string: filler, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        }
        return out
    }

    static func document(_ format: Format, url: URL) throws -> URL? {
        let text = styled()
        let range = NSRange(location: 0, length: text.length)
        switch format {
        case .txt: try Data(sampleText.utf8).write(to: url)
        case .md: try Data("# Clementine test document\n\nSome **bold** and *italic* text.\n\n- one\n- two\n".utf8).write(to: url)
        case .html: try Data("<html><body><h1>Clementine test document</h1><p>Some <b>bold</b> text.</p></body></html>".utf8).write(to: url)
        case .rtf: try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
        case .doc: try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat]).write(to: url)
        case .docx: try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: url)
        case .odt: try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument]).write(to: url)
        case .rtfd:
            let wrapper = try text.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        default: return nil
        }
        return url
    }

    static func subtitle(_ format: Format, url: URL) throws -> URL? {
        let text: String
        switch format {
        case .srt: text = "1\n00:00:00,500 --> 00:00:02,000\nHello Clementine\n\n2\n00:00:02,500 --> 00:00:04,000\nSecond line\n"
        case .vtt: text = "WEBVTT\n\n00:00.500 --> 00:02.000\nHello Clementine\n\n00:02.500 --> 00:04.000\nSecond line\n"
        case .ass:
            text = "[Script Info]\nTitle: t\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" +
                "Dialogue: 0,0:00:00.50,0:00:02.00,Default,,0,0,0,,Hello Clementine\n"
        default: return nil
        }
        try Data(text.utf8).write(to: url)
        return url
    }

    static func archive(_ format: Format, url: URL, dir: URL) async throws -> URL? {
        let content = dir.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data(sampleText.utf8).write(to: content.appendingPathComponent("notes.txt"))
        try Data("second".utf8).write(to: content.appendingPathComponent("more.txt"))
        let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
        switch format {
        case .zip: try await run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", content.path, url.path])
        case .tar: try await run(bsdtar, ["-cf", url.path, "-C", dir.path, "content"])
        case .tgz: try await run(bsdtar, ["-czf", url.path, "-C", dir.path, "content"])
        case .bz2:
            let bz = dir.appendingPathComponent("sample.tar.bz2")
            try await run(bsdtar, ["-cjf", bz.path, "-C", dir.path, "content"])
            return bz
        case .xz:
            let xz = dir.appendingPathComponent("sample.tar.xz")
            try await run(bsdtar, ["-cJf", xz.path, "-C", dir.path, "content"])
            return xz
        case .sevenZip: try await run(bsdtar, ["--format", "7zip", "-cf", url.path, "-C", dir.path, "content"])
        case .gz:
            let gz = dir.appendingPathComponent("notes.txt.gz")
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"),
                                                     ["-c", content.appendingPathComponent("notes.txt").path], stdoutFile: gz)
            guard result.status == 0 else { return nil }
            return gz
        default: return nil // RAR can't be created without the proprietary tool
        }
        return url
    }

    static func run(_ tool: URL, _ args: [String]) async throws {
        let result = try await ProcessRunner.run(tool, args)
        if result.status != 0 { throw JobFailure("fixture tool failed", details: result.stderrString) }
    }
}

/// Checks that an output really is what it claims to be.
enum Verify {
    static func output(_ url: URL, target: Format, source: Format) async throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw JobFailure("missing output") }
        if isDir.boolValue {
            // Multi-page output or an extracted folder.
            let items = try FileManager.default.contentsOfDirectory(atPath: url.path)
            guard !items.isEmpty else { throw JobFailure("empty folder") }
            if target.kind == .image {
                for name in items { try image(url.appendingPathComponent(name)) }
            }
            return
        }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw JobFailure("empty file") }
        switch target {
        case .jpg, .png, .heic, .webp, .avif, .tiff, .bmp, .gif:
            try image(url)
        case .pdf:
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw JobFailure("not a PDF") }
        case .docx, .odt, .zip:
            let head = try Data(contentsOf: url).prefix(2)
            guard Array(head) == [0x50, 0x4B] else { throw JobFailure("not a zip container") }
        case .txt, .md, .html, .rtf, .srt, .vtt, .svg:
            let text = TextDecoding.decode(try Data(contentsOf: url))
            let markers = ["Clementine", "clementine", "<svg", "quick brown fox", "Hello", "notes"]
            guard markers.contains(where: text.contains) || target == .svg else {
                throw JobFailure("expected text missing", details: String(text.prefix(200)))
            }
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma:
            let info = try await MediaProbe.probe(url)
            guard info.hasAudio else { throw JobFailure("no audio stream") }
            if let d = info.duration, d < 0.4 || d > 2 { throw JobFailure("unexpected duration \(d)") }
        case .mp4, .mov, .mkv, .webm, .avi, .wmv:
            let info = try await MediaProbe.probe(url)
            guard info.hasVideo else { throw JobFailure("no video stream") }
        case .tar, .tgz:
            let list = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/bsdtar"), ["-tf", url.path])
            guard list.status == 0, !list.stdoutString.isEmpty else { throw JobFailure("unreadable archive") }
        case .gz:
            let check = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-t", url.path])
            guard check.status == 0 else { throw JobFailure("bad gzip") }
        default:
            break
        }
    }

    static func image(_ url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              (props[kCGImagePropertyPixelWidth as String] as? Int ?? 0) > 0 else {
            throw JobFailure("unreadable image \(url.lastPathComponent)")
        }
    }
}
#endif
