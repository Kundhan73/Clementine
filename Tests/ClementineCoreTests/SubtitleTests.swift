import ClementineCore
import XCTest

final class SubtitleTests: XCTestCase {
    let srt = """
    1
    00:00:01,000 --> 00:00:03,500
    Hello <i>there</i>!

    2
    00:00:04,000 --> 00:00:06,000
    Two
    lines


    """

    func testSRTRoundTrip() {
        let cues = Subtitles.parseSRT(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "Two\nlines")
        XCTAssertEqual(Subtitles.parseSRT(Subtitles.srt(cues)), cues)
    }

    func testSRTToVTTAndBack() {
        let vtt = Subtitles.vtt(Subtitles.parseSRT(srt))
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:03.500\n"))
        XCTAssertEqual(Subtitles.parseVTT(vtt), Subtitles.parseSRT(srt))
    }

    func testVTTWithSettingsNotesAndShortTimes() {
        let vtt = """
        WEBVTT - title

        NOTE this is a comment

        intro
        00:01.500 --> 00:03.000 align:start position:10%
        <v Roger>Hi <c.loud>there</c>

        00:00:05.000 --> 00:00:06.000
        Bye
        """
        let cues = Subtitles.parseVTT(vtt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.0, accuracy: 0.001)
        XCTAssertEqual(Subtitles.plainText(cues), "Hi there\nBye\n")
        XCTAssertEqual(Subtitles.srt(cues).components(separatedBy: "\n")[2], "Hi there")
    }

    func testASS() {
        let ass = """
        [Script Info]
        Title: x

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:02.50,0:00:04.00,Default,,0,0,0,,{\\i1}Hello{\\i0}, world\\Nsecond line
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,First
        """
        let cues = Subtitles.parseASS(ass)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "First")
        XCTAssertEqual(cues[1].text, "Hello, world\nsecond line")
        XCTAssertEqual(cues[1].start, 2.5, accuracy: 0.001)
    }

    func testPlainTextTiming() {
        let cues = Subtitles.cues(fromPlainText: "Short.\nThis line is a fair bit longer than the first one, so it lasts longer.\n\n")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 0)
        XCTAssertEqual(cues[0].end, 1.5, accuracy: 0.001)       // minimum
        XCTAssertEqual(cues[1].start, 1.6, accuracy: 0.001)     // 0.1 s gap
        XCTAssertLessThanOrEqual(cues[1].end - cues[1].start, 7)
        let paragraphs = Subtitles.cues(fromPlainText: "One\nstill one\n\nTwo")
        XCTAssertEqual(paragraphs.map(\.text), ["One\nstill one", "Two"])
    }

    func testDecodingBOMsAndCRLF() {
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("a\r\nb".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(TextDecoding.decode(utf16), "a\nb")
        XCTAssertEqual(TextDecoding.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hé".utf8)), "hé")
        XCTAssertEqual(TextDecoding.decode(Data([0x63, 0x61, 0x66, 0xE9])), "café") // Windows-1252
    }

    func testConvertErrors() {
        XCTAssertThrowsError(try Subtitles.convert(Data("nothing here".utf8), from: .srt, to: .vtt))
        XCTAssertEqual(try Subtitles.convert(Data(srt.utf8), from: .srt, to: .txt), "Hello there!\nTwo lines\n")
    }
}
