#if canImport(AppKit)
import AppKit
import ClementineCore
import ImageIO
import XCTest

/// Media editor exports with the real ffmpeg (skipped without it).
final class MediaEditE2ETests: XCTestCase {
    private var tmp: TempDirectory!
    private var engines: Engines!

    override func setUpWithError() throws {
        guard FFmpegLocator.isAvailable else { throw XCTSkip("needs ffmpeg") }
        tmp = try TempDirectory(prefix: "clem-media-edit")
        engines = Engines(settings: ConversionSettings(),
                          planner: OutputPlanner(location: .besideOriginal, downloads: tmp.file("Downloads")))
    }

    override func tearDownWithError() throws { tmp?.remove() }

    // MARK: Helpers

    func export(_ tool: Tool, _ url: URL, _ options: ToolOptions) async throws -> URL {
        let job = Job(JobRequest(inputs: [InputItem.inspect(url)], operation: .tool(tool), options: options))
        let result = try await engines.execute(job)
        return try XCTUnwrap(result.outputs.first)
    }

    func make(_ name: String, _ args: [String]) async throws -> URL {
        let url = tmp.file(name)
        let result = try await ProcessRunner.run(FFmpegLocator.ffmpeg!, ["-nostdin", "-y"] + args + [url.path])
        XCTAssertEqual(result.status, 0, result.stderrString)
        return url
    }

    /// 4 s of 320×240 test pattern with a tone, keyframe every second.
    func video(_ name: String = "clip.mp4", seconds: Int = 4) async throws -> URL {
        try await make(name, ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=\(seconds)",
                              "-f", "lavfi", "-i", "sine=frequency=330:duration=\(seconds)",
                              "-c:v", "mpeg4", "-q:v", "2", "-g", "25", "-c:a", "aac_at", "-b:a", "128k", "-shortest"])
    }

    func tone(_ name: String = "tone.m4a", seconds: Int = 4) async throws -> URL {
        try await make(name, ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-af", "volume=0.5",
                              "-c:a", "aac_at", "-b:a", "192k"])
    }

    func duration(_ url: URL) async throws -> Double {
        let info = try await MediaProbe.probe(url)
        return try XCTUnwrap(info.duration)
    }

    /// Peak level (dBFS) of `url` between two times.
    func maxVolume(_ url: URL, from start: Double, length: Double) async throws -> Double {
        let result = try await ProcessRunner.run(FFmpegLocator.ffmpeg!, ["-nostdin", "-hide_banner", "-ss", "\(start)", "-t", "\(length)",
                                                                          "-i", url.path, "-af", "volumedetect", "-f", "null", "-"])
        let log = result.stderrString
        guard let r = log.range(of: "max_volume: ") else { return -200 }
        let value = log[r.upperBound...].prefix { "0123456789.-".contains($0) }
        return Double(value) ?? -200
    }

    /// One decoded frame of a video at `time`.
    func frame(_ url: URL, at time: Double) async throws -> CGImage {
        let png = try await make("frame-\(UUID().uuidString.prefix(6)).png", ["-ss", "\(time)", "-i", url.path, "-frames:v", "1",
                                                                             "-update", "1"])
        return try ImageCodec.decode(png, format: .png).image
    }

    func brightness(_ image: CGImage, x: Int, y: Int) -> Int {
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: ImageCodec.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (Int(px[0]) + Int(px[1]) + Int(px[2])) / 3
    }

    // MARK: Trim

    func testFastTrimCopiesAndKeepsRoughlyTheSelection() async throws {
        let out = try await export(.trim, try await video(), .trim(TrimOptions(start: 1, end: 3)))
        XCTAssertEqual(out.lastPathComponent, "clip (trimmed).mp4")
        let d = try await duration(out)
        XCTAssertGreaterThan(d, 1.8)
        XCTAssertLessThan(d, 3.2)
        let codec = try await MediaProbe.probe(out).video?.codec
        XCTAssertEqual(codec, "mpeg4", "fast trim must not re-encode")
    }

    func testPreciseTrimIsFrameExact() async throws {
        let out = try await export(.trim, try await video(), .trim(TrimOptions(start: 1.2, end: 2.6, precise: true)))
        let d = try await duration(out)
        XCTAssertEqual(d, 1.4, accuracy: 0.12)
    }

    func testAudioTrimWithFades() async throws {
        let out = try await export(.trim, try await tone(), .trim(TrimOptions(start: 0.5, end: 3.5, fadeIn: 1, fadeOut: 1)))
        XCTAssertEqual(out.pathExtension, "m4a")
        let length = try await duration(out)
        XCTAssertEqual(length, 3, accuracy: 0.1)
        // Quiet at the very start (fading in), full level in the middle.
        let start = try await maxVolume(out, from: 0, length: 0.1)
        let middle = try await maxVolume(out, from: 1.4, length: 0.3)
        XCTAssertLessThan(start, middle - 10, "start \(start) dB vs middle \(middle) dB")
    }

    // MARK: Crop, snapshot, redact

    func testVideoCropUsesDisplayedPixels() async throws {
        let out = try await export(.crop, try await video(), .crop(CGRect(x: 40, y: 20, width: 161, height: 121)))
        XCTAssertEqual(out.lastPathComponent, "clip (cropped).mp4")
        let info = try await MediaProbe.probe(out)
        XCTAssertEqual(info.video?.width, 160)
        XCTAssertEqual(info.video?.height, 120)
        XCTAssertTrue(info.hasAudio)
    }

    func testSnapshotSavesTheFrameAsPNG() async throws {
        let input = try await video()
        let out = try await export(.snapshot, input, .snapshot(1.0))
        XCTAssertEqual(out.lastPathComponent, "clip 00-00-01.000.png")
        let image = try ImageCodec.decode(out, format: .png).image
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 240)
        // Past the end still gives the last frame.
        let last = try await export(.snapshot, input, .snapshot(30))
        XCTAssertEqual(try ImageCodec.decode(last, format: .png).image.width, 320)
    }

    func testVideoRedactionCoversTheAreaOnlyDuringItsRange() async throws {
        var box = Redaction(rect: CGRect(x: 0, y: 0, width: 160, height: 120), style: .solid)
        box.color = .black
        box.start = 2
        let out = try await export(.redact, try await video(), .redact([box]))
        XCTAssertEqual(out.lastPathComponent, "clip (redacted).mp4")
        let before = try await frame(out, at: 1)
        let during = try await frame(out, at: 3)
        XCTAssertLessThan(brightness(during, x: 60, y: 60), 20)
        XCTAssertGreaterThan(brightness(before, x: 60, y: 60) + brightness(before, x: 100, y: 30), 40,
                             "the area should be visible before the range starts")
        let tags = try await MediaProbe.probe(out).tags
        XCTAssertNil(tags["title"])
    }

    // MARK: Bleep

    func testBleepSilenceAndTone() async throws {
        let input = try await tone()
        let silent = try await export(.bleep, input, .bleep(BleepOptions(intervals: [1...2], sound: .silence)))
        XCTAssertEqual(silent.lastPathComponent, "tone (bleeped).m4a")
        let gap = try await maxVolume(silent, from: 1.2, length: 0.6)
        let kept = try await maxVolume(silent, from: 2.5, length: 0.5)
        XCTAssertLessThan(gap, -50, "bleeped part should be silent, got \(gap) dB")
        // ffmpeg's sine source is 1/8 of full scale, × 0.5 here: about −24 dB.
        XCTAssertGreaterThan(kept, -30, "the rest should stay, got \(kept) dB")

        let beeped = try await export(.bleep, input, .bleep(BleepOptions(intervals: [1...2], sound: .tone(frequency: 1000))))
        let beep = try await maxVolume(beeped, from: 1.2, length: 0.6)
        XCTAssertGreaterThan(beep, -20, "a tone should play during the bleep, got \(beep) dB")
    }

    func testBleepKeepsVideoUntouched() async throws {
        let out = try await export(.bleep, try await video(), .bleep(BleepOptions(intervals: [0.5...1.5])))
        let info = try await MediaProbe.probe(out)
        XCTAssertEqual(info.video?.codec, "mpeg4")
        XCTAssertTrue(info.hasAudio)
    }

    // MARK: Visualizer

    func testVisualizerStyles() async throws {
        let audio = try await tone("song.m4a", seconds: 2)
        for style in VisualizerOptions.Style.allCases {
            let options = VisualizerOptions(style: style, color: .orange, background: .gradient(.blue, .black),
                                            title: style == .circle ? "" : "My Song", shape: .square)
            let out = try await export(.visualizer, audio, .visualizer(options))
            let info = try await MediaProbe.probe(out)
            XCTAssertEqual(info.video?.width, 1080, "\(style)")
            XCTAssertEqual(info.video?.height, 1080, "\(style)")
            XCTAssertEqual(info.duration ?? 0, 2, accuracy: 0.3, "\(style)")
            XCTAssertTrue(info.hasAudio, "\(style)")
            try FileManager.default.removeItem(at: out)
        }
    }

    func testVisualizerUsesCoverArt() async throws {
        let cover = tmp.file("cover.png")
        let ctx = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: ImageCodec.sRGB,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        try ImageCodec.write(ctx.makeImage()!, as: .png, to: cover)
        let song = try await make("covered.mp3", ["-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-i", cover.path,
                                                  "-map", "0:a", "-map", "1:v", "-c:a", "libmp3lame", "-c:v", "png",
                                                  "-disposition:v", "attached_pic", "-id3v2_version", "3"])
        let songInfo = try await MediaProbe.probe(song)
        XCTAssertNotNil(songInfo.coverArt)
        let out = try await export(.visualizer, song, .visualizer(VisualizerOptions(style: .bars, background: .coverArt,
                                                                                    shape: .landscape)))
        XCTAssertEqual(out.lastPathComponent, "covered (visualizer).mp4")
        let image = try await frame(out, at: 1)
        // The red cover fills the background (dimmed), away from the bars.
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buffer in
            let c = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: ImageCodec.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: -40, y: -(image.height - 1 - 40), width: image.width, height: image.height))
        }
        XCTAssertGreaterThan(Int(px[0]), Int(px[1]) + 80, "background should be the red cover, got \(px)")
    }

    func testVisualizerWithAChosenPicture() async throws {
        let picture = tmp.file("backdrop.png")
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: ImageCodec.sRGB,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        try ImageCodec.write(ctx.makeImage()!, as: .png, to: picture)
        let audio = try await tone("speech.m4a", seconds: 2)
        let out = try await export(.visualizer, audio, .visualizer(VisualizerOptions(style: .circle, background: .image(picture),
                                                                                      title: "Episode 1", shape: .portrait)))
        let info = try await MediaProbe.probe(out)
        XCTAssertEqual(info.video?.width, 1080)
        XCTAssertEqual(info.video?.height, 1920)
        let image = try await frame(out, at: 1)
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buffer in
            let c = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: ImageCodec.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: -20, y: -(image.height - 1 - (image.height - 40)), width: image.width, height: image.height))
        }
        XCTAssertGreaterThan(Int(px[1]), Int(px[0]) + 60, "background should be the green picture, got \(px)")
    }

    // MARK: Analysis helpers

    func testSilencesWaveformAndProxy() async throws {
        // 1 s of silence, 2 s of tone, 1 s of silence.
        let padded = try await make("padded.wav", ["-f", "lavfi", "-i", "sine=frequency=440:duration=4:sample_rate=44100",
                                                   "-af", "volume=volume=0:enable='lt(t,1)+gt(t,3)'"])
        let paddedLength = try await duration(padded)
        XCTAssertEqual(paddedLength, 4, accuracy: 0.05)
        let silences = try await MediaAnalysis.silences(padded)
        let bounds = MediaAnalysis.trimmedBounds(duration: 4, silences: silences)
        XCTAssertEqual(bounds.start, 0.95, accuracy: 0.1)
        XCTAssertEqual(bounds.end, 3.05, accuracy: 0.1)

        let wave = tmp.file("wave.png")
        try await MediaAnalysis.waveform(padded, to: wave, width: 800, height: 100)
        let picture = try ImageCodec.decode(wave, format: .png).image
        XCTAssertEqual(picture.width, 800)
        XCTAssertEqual(picture.height, 100)

        let mkv = try await make("clip.mkv", ["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25:duration=2",
                                              "-f", "lavfi", "-i", "sine=duration=2", "-c:v", "libvpx", "-b:v", "1M",
                                              "-c:a", "libvorbis", "-shortest"])
        let proxy = tmp.file("proxy.mp4")
        try await MediaAnalysis.previewProxy(mkv, to: proxy, hasVideo: true, settings: ConversionSettings()) { _ in }
        let info = try await MediaProbe.probe(proxy)
        XCTAssertEqual(info.video?.height, 720)
        XCTAssertTrue(["h264", "mpeg4"].contains(info.video?.codec ?? ""))
        XCTAssertEqual(info.audio.first?.codec, "aac")
    }
}
#endif
