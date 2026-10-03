import ClementineCore
import XCTest

final class ToolOptionTests: XCTestCase {
    func testPageRanges() throws {
        XCTAssertEqual(try PageRanges.parse("1-3, 5, 7-", pageCount: 9), [[1, 2, 3], [5], [7, 8, 9]])
        XCTAssertThrowsError(try PageRanges.parse("0-2", pageCount: 5))
        XCTAssertThrowsError(try PageRanges.parse("4-2", pageCount: 5))
        XCTAssertThrowsError(try PageRanges.parse("abc", pageCount: 5))
        XCTAssertThrowsError(try PageRanges.parse(" ", pageCount: 5))
    }

    func testSplitPDFGroups() throws {
        XCTAssertEqual(try SplitPDFOptions(mode: .everyPage).groups(pageCount: 3), [[1], [2], [3]])
        XCTAssertEqual(try SplitPDFOptions(mode: .everyN(2)).groups(pageCount: 5), [[1, 2], [3, 4], [5]])
    }

    func testMediaSegments() {
        let parts = SplitMediaOptions(mode: .parts(3)).segments(duration: 30)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[1].start, 10, accuracy: 0.001)
        XCTAssertEqual(parts[2].duration, 10, accuracy: 0.001)
        let every = SplitMediaOptions(mode: .every(seconds: 12)).segments(duration: 30)
        XCTAssertEqual(every.map(\.start), [0, 12, 24])
        let marks = SplitMediaOptions(mode: .at([20, 5, 40])).segments(duration: 30)
        XCTAssertEqual(marks.map(\.start), [0, 5, 20])
    }

    func testOrientationComposition() {
        XCTAssertEqual(ExifOrientation.compose(1, turn: .right, flipHorizontal: false, flipVertical: false), 6)
        XCTAssertEqual(ExifOrientation.compose(6, turn: .right, flipHorizontal: false, flipVertical: false), 3)
        XCTAssertEqual(ExifOrientation.compose(3, turn: .right, flipHorizontal: false, flipVertical: false), 8)
        XCTAssertEqual(ExifOrientation.compose(8, turn: .right, flipHorizontal: false, flipVertical: false), 1)
        XCTAssertEqual(ExifOrientation.compose(1, turn: .left, flipHorizontal: false, flipVertical: false), 8)
        XCTAssertEqual(ExifOrientation.compose(1, turn: .none, flipHorizontal: true, flipVertical: false), 2)
        XCTAssertEqual(ExifOrientation.compose(2, turn: .none, flipHorizontal: true, flipVertical: false), 1)
        XCTAssertEqual(ExifOrientation.compose(1, turn: .half, flipHorizontal: false, flipVertical: false), 3)
        XCTAssertEqual(ExifOrientation.compose(1, turn: .none, flipHorizontal: false, flipVertical: true), 4)
        // Every orientation composed with a full turn comes back.
        for o in 1...8 {
            var x = o
            for _ in 0..<4 { x = ExifOrientation.compose(x, turn: .right, flipHorizontal: false, flipVertical: false) }
            XCTAssertEqual(x, o)
        }
    }
}
