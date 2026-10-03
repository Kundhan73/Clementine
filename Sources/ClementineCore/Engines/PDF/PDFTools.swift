#if canImport(PDFKit)
import AppKit
import Foundation
import PDFKit
#if canImport(Quartz)
import Quartz
#endif

/// PDF tools: merge, split, rotate, compress, strip metadata, create from
/// images, read codes.
public enum PDFTools {
    /// Merges PDFs (and images, one page each) in the given order.
    public static func merge(_ inputs: [InputItem], to output: URL, pageSize: CreatePDFOptions = CreatePDFOptions(),
                             progress: (Double) -> Void = { _ in }) throws {
        let merged = PDFDocument()
        var keepAlive: [PDFDocument] = []
        let tmp = try TempDirectory(prefix: "clementine-merge")
        defer { tmp.remove() }
        for (i, item) in inputs.enumerated() {
            try autoreleasepool {
                let source: PDFDocument
                if item.kind == .pdf {
                    source = try PDFEngine.open(item.url)
                } else if item.kind == .image {
                    let page = tmp.file("image-\(i).pdf")
                    try ImagePDF.write(count: 1, to: page, pageSize: ImagePDF.PageSize(rawValue: pageSize.pageSize.rawValue) ?? .fitImage,
                                       margin: CGFloat(pageSize.margin)) {
                        try ImageCodec.decode(item.url, format: item.format)
                    }
                    guard let doc = PDFDocument(url: page) else { throw JobFailure("Couldn't add \(item.url.lastPathComponent).") }
                    source = doc
                } else {
                    throw JobFailure("\(item.url.lastPathComponent) isn't a PDF or an image.")
                }
                keepAlive.append(source)
                for p in 0..<source.pageCount {
                    if let page = source.page(at: p)?.copy() as? PDFPage {
                        merged.insert(page, at: merged.pageCount)
                    }
                }
            }
            progress(Double(i + 1) / Double(inputs.count) * 0.9)
        }
        guard merged.pageCount > 0 else { throw JobFailure("There are no pages to save.") }
        try write(merged, to: output)
        withExtendedLifetime(keepAlive) {}
    }

    /// Splits into page groups; writes "<base> part N.pdf" files into `folder`.
    public static func split(_ input: URL, options: SplitPDFOptions, into folder: URL, base: String) throws -> Int {
        let doc = try PDFEngine.open(input)
        let groups = try options.groups(pageCount: doc.pageCount)
        guard groups.count > 1 || groups.first?.count != doc.pageCount else {
            throw JobFailure("That would make one PDF with every page.")
        }
        for (i, group) in groups.enumerated() {
            try autoreleasepool {
                let part = PDFDocument()
                for number in group {
                    if let page = doc.page(at: number - 1)?.copy() as? PDFPage { part.insert(page, at: part.pageCount) }
                }
                let name = groups.allSatisfy({ $0.count == 1 }) ? "\(base) page \(group[0]).pdf" : "\(base) part \(i + 1).pdf"
                try write(part, to: folder.appendingPathComponent(name))
            }
        }
        return groups.count
    }

    public static func rotate(_ input: URL, options: RotateOptions, to output: URL) throws {
        let doc = try PDFEngine.open(input)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            page.rotation = ((page.rotation + options.turn.rawValue) % 360 + 360) % 360
        }
        try write(doc, to: output)
    }

    /// Clears the document info (title, author, creator, keywords…).
    public static func stripMetadata(_ input: URL, to output: URL) throws {
        let doc = try PDFEngine.open(input)
        doc.documentAttributes = [:]
        try write(doc, to: output)
    }

    /// Codes found on any page (rendered at 200 dpi).
    public static func readCodes(_ input: URL) throws -> [String] {
        let doc = try PDFEngine.open(input)
        var found: [String] = []
        for i in 0..<min(doc.pageCount, 200) {
            try autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                for code in try ImageTools.readCodes(in: PDFEngine.render(page, dpi: 200)) where !found.contains(code) {
                    found.append(code)
                }
            }
        }
        return found
    }

    // MARK: Compress

    struct Level {
        let dpi: Int
        let quality: Double
    }

    static let levels = [Level(dpi: 150, quality: 0.7), Level(dpi: 110, quality: 0.6), Level(dpi: 72, quality: 0.5)]

    /// Re-writes with downsampled, JPEG-recompressed images; text stays
    /// vector. With a target size, keeps the largest result that fits.
    public static func compress(_ input: URL, options: CompressOptions, to output: URL,
                                progress: (Double) -> Void = { _ in }) throws -> String? {
        let originalSize = fileSize(input) ?? 0
        let target = options.targetBytes ?? options.presetLimitBytes
        let tmp = try TempDirectory(prefix: "clementine-pdfz")
        defer { tmp.remove() }
        var candidates: [(URL, Int64)] = []
        let chosen: [Level]
        if target != nil {
            chosen = levels
        } else {
            switch options.preset {
            case .high: chosen = [levels[0]]
            case .medium: chosen = [levels[1]]
            default: chosen = [levels[2]]
            }
        }
        for (i, level) in chosen.enumerated() {
            let url = tmp.file("level-\(i).pdf")
            if try writeCompressed(input, level: level, to: url), let size = fileSize(url) {
                candidates.append((url, size))
                if let target, size <= target { break }
            }
            progress(Double(i + 1) / Double(chosen.count))
        }
        guard !candidates.isEmpty else { throw JobFailure("Couldn't compress this PDF.") }
        let fitting = target.map { t in candidates.filter { $0.1 <= t } } ?? candidates
        let best = (fitting.max { $0.1 < $1.1 }) ?? candidates.min { $0.1 < $1.1 }!
        if best.1 >= originalSize {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: input, to: output)
            return "This PDF can't be made smaller."
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: best.0, to: output)
        if let target, best.1 > target {
            return "Smallest possible: \(ByteCountFormatter.string(fromByteCount: best.1, countStyle: .file))."
        }
        return nil
    }

    /// One compression pass with a generated Quartz filter (falls back to
    /// PDFKit's JPEG/screen-optimised write options).
    static func writeCompressed(_ input: URL, level: Level, to output: URL) throws -> Bool {
        guard let doc = PDFDocument(url: input) else { throw JobFailure("This PDF can't be opened.") }
        if doc.isLocked { throw JobFailure("This PDF is password-protected.") }
        #if canImport(Quartz)
        if let filter = quartzFilter(level) {
            let options: [PDFDocumentWriteOption: Any] = [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]
            if doc.write(to: output, withOptions: options) { return true }
        }
        #endif
        var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
        if level.dpi <= 110 { options[.optimizeImagesForScreenOption] = true }
        return doc.write(to: output, withOptions: options)
    }

    #if canImport(Quartz)
    static func quartzFilter(_ level: Level) -> QuartzFilter? {
        let plist: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "Clementine \(level.dpi) dpi",
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": level.quality,
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": level.dpi,
                            "ImageScaleFactor": 0.0,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": 0,
                            "ImageSizeMin": 0,
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        // Kept in Caches (the filter may read its file lazily).
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clementine/Filters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("reduce-\(level.dpi)-\(Int(level.quality * 100)).qfilter")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: url)) != nil else { return nil }
        return QuartzFilter(url: url)
    }
    #endif

    // MARK: Helpers

    static func write(_ doc: PDFDocument, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard doc.write(to: url) else { throw JobFailure("Couldn't save the PDF.") }
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).map(Int64.init)
    }
}
#endif
