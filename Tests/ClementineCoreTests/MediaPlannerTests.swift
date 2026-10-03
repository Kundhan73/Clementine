import ClementineCore
import XCTest

final class MediaPlannerTests: XCTestCase {
    func info(video: String?, audio: [String], subs: [String] = [], cover: Bool = false,
              size: (Int, Int) = (1920, 1080), rate: Int = 48_000, channels: Int = 2) -> MediaInfo {
        var streams: [MediaInfo.Stream] = []
        if let video {
            streams.append(.init(index: streams.count, type: "video", codec: video, width: size.0, height: size.1, frameRate: 30))
        }
        for a in audio {
            streams.append(.init(index: streams.count, type: "audio", codec: a, sampleRate: rate, channels: channels))
        }
        for s in subs { streams.append(.init(index: streams.count, type: "subtitle", codec: s)) }
        if cover { streams.append(.init(index: streams.count, type: "video", codec: "mjpeg", isAttachedPicture: true)) }
        return MediaInfo(formatName: "x", duration: 10, streams: streams)
    }

    func plan(_ info: MediaInfo, _ target: Format, source: Format = .mov,
              settings: ConversionSettings = ConversionSettings()) throws -> [FFmpegAttempt] {
        try MediaPlanner.plan(source: source, info: info, target: target, settings: settings)
    }

    func testSmartRemuxFirst() throws {
        let attempts = try plan(info(video: "h264", audio: ["aac"]), .mp4)
        XCTAssertEqual(attempts.first?.label, "remux-nosubs")
        XCTAssertTrue(attempts[0].outputArgs.contains("copy"))
        XCTAssertTrue(attempts.contains { $0.outputArgs.contains("h264_videotoolbox") }, "transcode fallback present")
        XCTAssertEqual(attempts.last?.outputArgs.contains("mpeg4"), true, "software fallback last")
    }

    func testHEVCGetsAppleTag() throws {
        let attempts = try plan(info(video: "hevc", audio: ["aac"]), .mov)
        let args = attempts[0].outputArgs
        XCTAssertEqual(args[args.firstIndex(of: "-tag:v")! + 1], "hvc1")
    }

    func testPartialRemuxCopiesVideoAndEncodesAudio() throws {
        let attempts = try plan(info(video: "h264", audio: ["opus"]), .mp4, source: .mkv)
        let first = attempts[0].outputArgs
        XCTAssertEqual(first[first.firstIndex(of: "-c:v")! + 1], "copy")
        XCTAssertEqual(first[first.firstIndex(of: "-c:a")! + 1], "aac_at")
    }

    func testMKVKeepsSubtitles() throws {
        let attempts = try plan(info(video: "h264", audio: ["aac"], subs: ["mov_text"]), .mkv, source: .mp4)
        XCTAssertEqual(attempts[0].label, "remux")
        let args = attempts[0].outputArgs
        XCTAssertEqual(args[args.firstIndex(of: "-c:s")! + 1], "srt")
        XCTAssertEqual(attempts[1].label, "remux-nosubs")
    }

    func testWebMTranscode() throws {
        let attempts = try plan(info(video: "h264", audio: ["aac"]), .webm, source: .mp4)
        XCTAssertTrue(attempts[0].outputArgs.contains("libvpx-vp9"))
        XCTAssertTrue(attempts[0].outputArgs.contains("libopus"))
    }

    func testGIF() throws {
        let attempts = try plan(info(video: "h264", audio: ["aac"]), .gif, source: .mp4)
        let graph = attempts[0].outputArgs[attempts[0].outputArgs.firstIndex(of: "-filter_complex")! + 1]
        XCTAssertTrue(graph.contains("palettegen"))
        XCTAssertTrue(graph.contains("fps=15"))
        XCTAssertTrue(graph.contains("min(720,iw)"))
    }

    func testAudioCopyAndEncode() throws {
        let m4a = try plan(info(video: nil, audio: ["aac"]), .m4a, source: .aac)
        XCTAssertEqual(m4a[0].label, "copy")
        let mp3 = try plan(info(video: nil, audio: ["flac"], rate: 96_000, channels: 6), .mp3, source: .flac)
        let args = mp3[0].outputArgs
        XCTAssertTrue(args.contains("libmp3lame"))
        XCTAssertEqual(args[args.firstIndex(of: "-ar")! + 1], "48000")
        XCTAssertEqual(args[args.firstIndex(of: "-ac")! + 1], "2")
    }

    func testCoverArtKeptForAudioTargets() throws {
        let attempts = try plan(info(video: nil, audio: ["mp3"], cover: true), .m4a, source: .mp3)
        XCTAssertTrue(attempts[0].outputArgs.contains("attached_pic"))
        XCTAssertEqual(attempts.last?.label, "encode-nocover")
        let fromVideo = try plan(info(video: "h264", audio: ["aac"]), .mp3, source: .mp4)
        XCTAssertTrue(fromVideo[0].outputArgs.contains("-vn"))
    }

    func testErrors() {
        XCTAssertThrowsError(try plan(info(video: nil, audio: ["aac"]), .mp4))
        XCTAssertThrowsError(try plan(info(video: "h264", audio: []), .mp3))
    }

    func testProbeParsing() throws {
        let json = """
        {"streams":[{"index":0,"codec_name":"h264","codec_type":"video","width":1920,"height":1080,
          "avg_frame_rate":"30000/1001","side_data_list":[{"side_data_type":"Display Matrix","rotation":-90}]},
          {"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2,
          "tags":{"language":"eng"}},
          {"index":2,"codec_name":"mjpeg","codec_type":"video","disposition":{"attached_pic":1}}],
         "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"12.500000","bit_rate":"800000",
          "tags":{"title":"Clip"}}}
        """
        let info = try MediaProbe.parse(Data(json.utf8))
        XCTAssertEqual(info.duration ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(info.video?.codec, "h264")
        XCTAssertEqual(info.video?.rotation, 270)
        XCTAssertEqual(info.video?.frameRate ?? 0, 29.97, accuracy: 0.01)
        XCTAssertEqual(info.displaySize?.width, 1080)
        XCTAssertEqual(info.audio.first?.sampleRate, 48_000)
        XCTAssertEqual(info.audio.first?.language, "eng")
        XCTAssertNotNil(info.coverArt)
        XCTAssertEqual(info.tags["title"], "Clip")
    }

    func testArchiveListingParser() {
        let listing = """
        drwxr-xr-x  0 user   staff       0 Oct  3 12:00 content/
        -rw-r--r--  0 user   staff    1234 Oct  3 12:00 content/a.txt
        -rw-r--r--  0 user   staff     766 Oct  3 12:00 content/b.txt
        """
        let (entries, bytes) = ArchiveEngine.parseListing(listing)
        XCTAssertEqual(entries, 3)
        XCTAssertEqual(bytes, 2000)
    }
}
