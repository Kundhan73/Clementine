import ClementineCore
import Foundation
import XCTest

/// The media editors' argument builders (pure logic, any platform).
final class MediaEditTests: XCTestCase {
    func videoInfo(duration: Double = 10, audio: String? = "aac", width: Int = 1280, height: Int = 720,
                   codec: String = "h264") -> MediaInfo {
        var streams = [MediaInfo.Stream(index: 0, type: "video", codec: codec, width: width, height: height, frameRate: 30)]
        if let audio { streams.append(MediaInfo.Stream(index: 1, type: "audio", codec: audio, sampleRate: 48_000, channels: 2)) }
        return MediaInfo(formatName: "mov,mp4,m4a,3gp,3g2,mj2", duration: duration, streams: streams)
    }

    func audioInfo(codec: String = "mp3", duration: Double = 30, channels: Int = 2) -> MediaInfo {
        MediaInfo(formatName: "mp3", duration: duration,
                  streams: [MediaInfo.Stream(index: 0, type: "audio", codec: codec, sampleRate: 44_100, channels: channels)])
    }

    // MARK: Trim

    func testFastVideoTrimCopiesStreamsFirst() throws {
        let attempts = try MediaEditing.trimAttempts(info: videoInfo(), format: .mp4,
                                                     options: TrimOptions(start: 2, end: 5), settings: ConversionSettings())
        XCTAssertEqual(attempts.first?.label, "copy")
        XCTAssertEqual(attempts.first?.inputArgs, ["-ss", "2.000"])
        let out = attempts[0].outputArgs
        XCTAssertEqual(out[0...1], ["-t", "3.000"])
        XCTAssertTrue(out.contains("copy"))
        XCTAssertFalse(out.contains("-af"))
        // Encoders follow as fallbacks.
        XCTAssertTrue(attempts.contains { $0.outputArgs.contains("h264_videotoolbox") || $0.outputArgs.contains("mpeg4") })
    }

    func testPreciseTrimReencodes() throws {
        let attempts = try MediaEditing.trimAttempts(info: videoInfo(), format: .mov,
                                                     options: TrimOptions(start: 1, end: 4, precise: true),
                                                     settings: ConversionSettings())
        XCTAssertFalse(attempts.contains { $0.label.hasPrefix("copy") })
        XCTAssertTrue(attempts.allSatisfy { $0.inputArgs == ["-ss", "1.000"] })
    }

    func testTrimFadesReencodeOnlyTheAudio() throws {
        let attempts = try MediaEditing.trimAttempts(info: videoInfo(), format: .mp4,
                                                     options: TrimOptions(start: 0, end: 6, fadeIn: 1, fadeOut: 2),
                                                     settings: ConversionSettings())
        let first = attempts[0].outputArgs
        XCTAssertEqual(attempts[0].label, "copy")
        XCTAssertTrue(first.contains("-c:v") && first[first.firstIndex(of: "-c:v")! + 1] == "copy")
        let af = first[first.firstIndex(of: "-af")! + 1]
        XCTAssertEqual(af, "afade=t=in:st=0:d=1.000,afade=t=out:st=4.000:d=2.000")
    }

    func testAudioTrimCopiesWhenItCan() throws {
        let copy = try MediaEditing.trimAttempts(info: audioInfo(), format: .mp3, options: TrimOptions(start: 3, end: 9),
                                                 settings: ConversionSettings())
        XCTAssertEqual(copy.first?.label, "copy")
        let faded = try MediaEditing.trimAttempts(info: audioInfo(), format: .mp3,
                                                  options: TrimOptions(start: 3, end: 9, fadeOut: 1), settings: ConversionSettings())
        XCTAssertEqual(faded.first?.label, "encode")
        XCTAssertTrue(faded[0].outputArgs.contains("libmp3lame"))
    }

    func testTrimRejectsEmptySelectionAndClampsToLength() throws {
        XCTAssertThrowsError(try MediaEditing.trimAttempts(info: audioInfo(duration: 5), format: .mp3,
                                                           options: TrimOptions(start: 5, end: 9), settings: ConversionSettings()))
        let clamped = try MediaEditing.trimAttempts(info: audioInfo(duration: 5), format: .mp3,
                                                    options: TrimOptions(start: 1, end: 99), settings: ConversionSettings())
        XCTAssertEqual(Array(clamped[0].outputArgs[0...1]), ["-t", "4.000"])
    }

    // MARK: Crop

    func testCropFilterRoundsToEvenAndClamps() throws {
        XCTAssertEqual(try MediaEditing.cropFilter(CGRect(x: 11, y: 7, width: 301, height: 199), displaySize: (1280, 720)),
                       "crop=300:198:10:6")
        XCTAssertEqual(try MediaEditing.cropFilter(CGRect(x: 1200, y: 600, width: 400, height: 400), displaySize: (1280, 720)),
                       "crop=80:120:1200:600")
        XCTAssertThrowsError(try MediaEditing.cropFilter(CGRect(x: 0, y: 0, width: 8, height: 8), displaySize: (1280, 720)))
        XCTAssertThrowsError(try MediaEditing.cropFilter(CGRect(x: 2000, y: 0, width: 100, height: 100), displaySize: (1280, 720)))
    }

    // MARK: Snapshot

    func testSnapshotNames() {
        XCTAssertEqual(MediaEditing.snapshotName(base: "clip", time: 83.456), "clip 00-01-23.456")
        XCTAssertEqual(MediaEditing.snapshotName(base: "Holiday", time: 3725.0004), "Holiday 01-02-05.000")
        XCTAssertEqual(MediaEditing.snapshotName(base: "a", time: -1), "a 00-00-00.000")
        let attempts = MediaEditing.snapshotAttempts(time: 2)
        XCTAssertEqual(attempts[0].inputArgs, ["-ss", "1.999500"])
        XCTAssertTrue(attempts[0].outputArgs.contains("-frames:v"))
    }

    // MARK: Redact

    func testRedactGraph() throws {
        var solid = Redaction(rect: CGRect(x: 10, y: 20, width: 101, height: 51), style: .solid)
        solid.color = .black
        var blur = Redaction(rect: CGRect(x: 600, y: 300, width: 200, height: 100), style: .blur)
        blur.start = 1.5
        blur.end = 4
        let pixelate = Redaction(rect: CGRect(x: 1200, y: 650, width: 400, height: 400), style: .pixelate)
        let graph = try XCTUnwrap(MediaEditing.redactGraph([solid, blur, pixelate], displaySize: (1280, 720)))
        XCTAssertTrue(graph.hasPrefix("[0:V:0]drawbox=x=10:y=20:w=100:h=50:color=0x000000@1:t=fill[r0]"), graph)
        XCTAssertTrue(graph.contains("[r0]split=2[k1][s1];[s1]crop=200:100:600:300,"), graph)
        XCTAssertTrue(graph.contains("overlay=x=600:y=300:enable='between(t,1.500,4.000)'[r1]"), graph)
        // Clamped to the frame: 80 × 70 at (1200, 650).
        XCTAssertTrue(graph.contains("crop=80:70:1200:650"), graph)
        XCTAssertTrue(graph.hasSuffix("format=yuv420p[v]"), graph)
        XCTAssertNil(MediaEditing.redactGraph([Redaction(rect: CGRect(x: 5000, y: 0, width: 10, height: 10), style: .blur)],
                                              displaySize: (1280, 720)))
    }

    // MARK: Bleep

    func testBleepIntervalsMerge() {
        let options = BleepOptions(intervals: [4...5, 1...2, 1.5...3, 9...12, -1...0.5])
        XCTAssertEqual(options.merged(duration: 10), [0...0.5, 1...3, 4...5, 9...10])
    }

    func testBleepGraphs() throws {
        let tone = try XCTUnwrap(MediaEditing.bleepGraph(BleepOptions(intervals: [1...2, 3...3.5]), duration: 10, channels: 1,
                                                         sampleRate: 44_100))
        XCTAssertTrue(tone.contains("enable='between(t,1.000,2.000)+between(t,3.000,3.500)'"), tone)
        XCTAssertTrue(tone.contains("sine=frequency=1000:sample_rate=44100:duration=11.000"), tone)
        XCTAssertTrue(tone.contains("channel_layouts=mono"), tone)
        XCTAssertTrue(tone.contains("not(between(t,1.000,2.000)+between(t,3.000,3.500))"), tone)
        XCTAssertTrue(tone.hasSuffix("amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]"), tone)
        let silence = try XCTUnwrap(MediaEditing.bleepGraph(BleepOptions(intervals: [1...2], sound: .silence), duration: 10,
                                                            channels: 2, sampleRate: 48_000))
        XCTAssertEqual(silence, "[0:a:0]volume=volume=0:enable='between(t,1.000,2.000)'[a]")
        XCTAssertNil(MediaEditing.bleepGraph(BleepOptions(intervals: []), duration: 10, channels: 2, sampleRate: 48_000))
    }

    func testBleepVideoCopiesThePicture() throws {
        let attempts = try MediaEditing.bleepAttempts(info: videoInfo(), format: .mp4, options: BleepOptions(intervals: [1...2]),
                                                      settings: ConversionSettings())
        let args = attempts[0].outputArgs
        XCTAssertTrue(args.contains("[a]"))
        XCTAssertEqual(args[args.firstIndex(of: "-c:v")! + 1], "copy")
        XCTAssertThrowsError(try MediaEditing.bleepAttempts(info: videoInfo(), format: .mp4, options: BleepOptions(intervals: []),
                                                            settings: ConversionSettings()))
    }

    // MARK: Visualizer

    func testVisualizerGraphs() {
        for style in VisualizerOptions.Style.allCases {
            for overlay in [false, true] {
                let graph = MediaEditing.visualizerGraph(VisualizerOptions(style: style, shape: .square), hasOverlay: overlay)
                XCTAssertTrue(graph.hasSuffix("fps=30,format=yuv420p[v]"), "\(style): \(graph)")
                XCTAssertEqual(graph.contains("[2:v]overlay"), overlay, "\(style): \(graph)")
            }
        }
        let circle = MediaEditing.visualizerGraph(VisualizerOptions(style: .circle), hasOverlay: true)
        XCTAssertTrue(circle.contains("[wave][3:v][4:v]remap"), circle)
        let plain = MediaEditing.visualizerGraph(VisualizerOptions(style: .circle), hasOverlay: false)
        XCTAssertTrue(plain.contains("[wave][2:v][3:v]remap"), plain)
        XCTAssertEqual(RGBA.orange.ffmpegHex, "0xF5801A")
    }

    func testCircleMapsAreRingShaped() {
        let side = 64
        let maps = MediaEditing.circleMaps(side: side)
        let header = "P5\n64 64\n65535\n"
        XCTAssertEqual(maps.x.count, header.utf8.count + side * side * 2)
        XCTAssertEqual(String(decoding: maps.y.prefix(header.utf8.count), as: UTF8.self), header)
        func value(_ data: Data, _ col: Int, _ row: Int) -> Int {
            let i = header.utf8.count + (row * side + col) * 2
            return Int(data[data.startIndex + i]) << 8 | Int(data[data.startIndex + i + 1])
        }
        // The centre is off the ring (transparent padding row).
        XCTAssertEqual(value(maps.y, 32, 32), MediaEditing.circleSource.height + 1)
        // Straight up on the ring: angle 0 → first column of the strip.
        XCTAssertLessThan(value(maps.x, 32, 4), 20)
        XCTAssertLessThan(value(maps.y, 32, 4), MediaEditing.circleSource.height)
    }

    // MARK: Analysis

    func testParseSilences() {
        let log = """
        [silencedetect @ 0x1] silence_start: 0
        [silencedetect @ 0x1] silence_end: 1.02 | silence_duration: 1.02
        size=N/A time=00:00:02.00 bitrate=N/A
        [silencedetect @ 0x1] silence_start: 3.5
        [silencedetect @ 0x1] silence_end: 4 | silence_duration: 0.5
        """
        XCTAssertEqual(MediaAnalysis.parseSilences(log), [0...1.02, 3.5...4])
        let open = MediaAnalysis.parseSilences("[silencedetect @ 0x1] silence_start: 7.25")
        XCTAssertEqual(open.first?.lowerBound, 7.25)
    }

    func testTrimmedBounds() {
        let b = MediaAnalysis.trimmedBounds(duration: 4, silences: [0...1, 3...4])
        XCTAssertEqual(b.start, 0.95, accuracy: 0.001)
        XCTAssertEqual(b.end, 3.05, accuracy: 0.001)
        // Nothing to trim, or all silent: keep everything.
        XCTAssertEqual(MediaAnalysis.trimmedBounds(duration: 4, silences: []).end, 4)
        XCTAssertEqual(MediaAnalysis.trimmedBounds(duration: 4, silences: [0...4]).start, 0)
    }
}
