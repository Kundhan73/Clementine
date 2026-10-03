import ClementineCore
import XCTest

final class MatrixTests: XCTestCase {
    func testAtLeast188Pairs() {
        let pairs = ConversionMatrix.pairs
        XCTAssertGreaterThanOrEqual(pairs.count, 188, "conversion matrix shrank")
        // No duplicates, no self-conversions.
        let keys = pairs.map { "\($0.source.rawValue)>\($0.target.rawValue)" }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertFalse(pairs.contains { $0.source == $0.target })
    }

    func testEveryPairHasAnEngine() {
        for (source, target) in ConversionMatrix.pairs {
            XCTAssertNotNil(ConversionMatrix.engine(from: source, kind: source.kind, to: target),
                            "\(source) → \(target) has no engine")
        }
    }

    func testSpecTargets() {
        XCTAssertEqual(ConversionMatrix.targets(for: .heic).prefix(3), [.jpg, .png, .webp])
        XCTAssertTrue(ConversionMatrix.targets(for: .gif).contains(.mp4))
        XCTAssertEqual(ConversionMatrix.targets(for: .srt), [.vtt, .txt])
        XCTAssertEqual(ConversionMatrix.targets(for: .pdf), [.docx, .jpg, .png, .txt, .tiff])
        XCTAssertTrue(ConversionMatrix.targets(for: .mov).contains(.mp3))
        XCTAssertFalse(ConversionMatrix.targets(for: .mp3).contains(.mp3))
    }

    func testDetection() {
        XCTAssertEqual(Format.detect(fileName: "IMG_0001.HEIC"), .heic)
        XCTAssertEqual(Format.detect(fileName: "photo.JPEG"), .jpg)
        XCTAssertEqual(Format.detect(fileName: "backup.tar.gz"), .tgz)
        XCTAssertEqual(Format.detect(fileName: "clip.MTS"), .ts)
        XCTAssertEqual(Format.detect(fileName: "raw.CR3"), .cameraRaw)
        XCTAssertNil(Format.detect(fileName: "README"))
        XCTAssertNil(Format.detect(fileName: ".zshrc"))
        XCTAssertEqual(Format.baseName(of: "backup.tar.gz"), "backup")
        XCTAssertEqual(Format.baseName(of: "my.photo.jpg"), "my.photo")
        XCTAssertEqual(Format.baseName(of: "Makefile"), "Makefile")
    }

    func testFolderItems() {
        let folder = InputItem(url: URL(fileURLWithPath: "/tmp/Stuff"), isDirectory: true)
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(ConversionMatrix.allTargets(for: folder), [.zip, .tar, .tgz])
        let rtfd = InputItem(url: URL(fileURLWithPath: "/tmp/Note.rtfd"), isDirectory: true)
        XCTAssertEqual(rtfd.kind, .document)
    }

    func testEngineKinds() {
        XCTAssertEqual(ConversionMatrix.engine(from: .png, kind: .image, to: .svg), .imageToSVG)
        XCTAssertEqual(ConversionMatrix.engine(from: .png, kind: .image, to: .pdf), .imageToPDF)
        XCTAssertEqual(ConversionMatrix.engine(from: .gif, kind: .image, to: .mp4), .media)
        XCTAssertEqual(ConversionMatrix.engine(from: .pdf, kind: .pdf, to: .txt), .pdfToText)
        XCTAssertEqual(ConversionMatrix.engine(from: .txt, kind: .document, to: .srt), .textToSubtitle)
        XCTAssertEqual(ConversionMatrix.engine(from: .zip, kind: .archive, to: .extract), .extract)
        XCTAssertEqual(ConversionMatrix.engine(from: .mp3, kind: .audio, to: .zip), .archive)
        XCTAssertNil(ConversionMatrix.engine(from: .mp3, kind: .audio, to: .jpg))
    }
}

final class WheelContentTests: XCTestCase {
    private func item(_ name: String) -> InputItem {
        InputItem(url: URL(fileURLWithPath: "/tmp/\(name)"), isDirectory: false)
    }

    func testSingleImage() {
        let chips = WheelContent.chips(for: [item("a.heic")], mode: .convert)
        XCTAssertEqual(chips.first, .format(.jpg))
        XCTAssertFalse(chips.contains(.format(.heic)))
        XCTAssertTrue(chips.contains(.format(.zip)))
        XCTAssertLessThanOrEqual(chips.count, 12)
    }

    func testMixedImagesOfferEachOthersFormats() {
        let chips = WheelContent.convertTargets(for: [item("a.jpg"), item("b.png")])
        XCTAssertEqual(chips.first, .jpg)
        XCTAssertTrue(chips.contains(.png))
        XCTAssertTrue(chips.contains(.heic))
    }

    func testAllSameFormatExcludesIt() {
        let chips = WheelContent.convertTargets(for: [item("a.jpg"), item("b.jpg")])
        XCTAssertFalse(chips.contains(.jpg))
    }

    func testMixedKindsOnlyArchive() {
        let chips = WheelContent.convertTargets(for: [item("a.jpg"), item("b.mp3")])
        XCTAssertEqual(chips, [.zip])
    }

    func testTools() {
        let image = WheelContent.chips(for: [item("a.png")], mode: .tools)
        XCTAssertEqual(image.first, .tool(.compress))
        XCTAssertFalse(image.contains(.tool(.collage)))
        let two = WheelContent.chips(for: [item("a.png"), item("b.jpg")], mode: .tools)
        XCTAssertEqual(two.first, .tool(.collage))
        XCTAssertFalse(two.contains(.tool(.crop)))
        let pdfs = WheelContent.chips(for: [item("a.pdf"), item("b.pdf")], mode: .tools)
        XCTAssertTrue(pdfs.contains(.tool(.mergePDF)))
        let videos = WheelContent.chips(for: [item("a.mp4"), item("b.mov")], mode: .tools)
        XCTAssertTrue(videos.contains(.tool(.join)))
        let mixed = WheelContent.chips(for: [item("a.mp4"), item("b.mp3")], mode: .tools)
        XCTAssertFalse(mixed.contains(.tool(.join)))
    }

    func testAvailabilityFilter() {
        let chips = WheelContent.chips(for: [item("a.png")], mode: .convert) { $0 != .format(.avif) }
        XCTAssertFalse(chips.contains(.format(.avif)))
    }
}

final class WheelLayoutTests: XCTestCase {
    func testChipsStartAtTwelveClockwise() {
        let layout = WheelLayout(count: 4)
        let top = layout.center(of: 0)
        XCTAssertEqual(top.x, 0, accuracy: 0.001)
        XCTAssertGreaterThan(top.y, 0)
        let right = layout.center(of: 1)
        XCTAssertGreaterThan(right.x, 0, "second chip should be at 3 o'clock")
        XCTAssertEqual(right.y, 0, accuracy: 0.001)
    }

    func testHitTesting() {
        let layout = WheelLayout(count: 6)
        XCTAssertEqual(layout.hitTest(.zero), .hub)
        for i in 0..<6 {
            XCTAssertEqual(layout.hitTest(layout.center(of: i)), .chip(i))
        }
        XCTAssertEqual(layout.hitTest(CGPoint(x: 0, y: layout.discRadius + 50)), .none)
    }

    func testTwoRings() {
        let layout = WheelLayout(count: 17)
        XCTAssertEqual(layout.innerCount, 12)
        XCTAssertEqual(layout.outerCount, 5)
        for i in 0..<17 {
            XCTAssertEqual(layout.hitTest(layout.center(of: i)), .chip(i), "chip \(i)")
        }
        XCTAssertGreaterThan(layout.outerRadius, layout.innerRadius + layout.chipRadius * 2)
    }

    func testChipsDontOverlap() {
        for n in 1...24 {
            let layout = WheelLayout(count: n, largeChips: true)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let a = layout.center(of: i), b = layout.center(of: j)
                    XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), 2 * layout.chipRadius, "n=\(n) \(i)/\(j)")
                }
            }
        }
    }
}
