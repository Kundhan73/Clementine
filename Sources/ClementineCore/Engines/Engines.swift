#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
#if canImport(PDFKit)
import PDFKit
#endif

/// Runs jobs: picks the engine for each conversion or tool, manages the
/// atomic output and reports progress.
public struct Engines: JobExecuting {
    public var settings: ConversionSettings
    public var planner: OutputPlanner

    public init(settings: ConversionSettings = ConversionSettings(), planner: OutputPlanner = OutputPlanner()) {
        self.settings = settings
        self.planner = planner
    }

    // MARK: Availability (what this build can do)

    public static let implementedEngines: Set<EngineKind> = [
        .image, .imageToPDF, .imageToSVG, .imageToDOCX, .media, .pdfToImages, .pdfToText, .pdfToDOCX,
        .document, .textToImages, .subtitle, .textToSubtitle, .archive, .extract,
    ]
    /// Tools and the file kinds they are implemented for so far.
    public static let implementedTools: [Tool: Set<FileKind>] = [
        .compress: [.image, .video, .audio, .pdf],
        .resize: [.image, .video],
        .rotate: [.image, .video, .pdf],
        .removeMetadata: [.image, .audio, .video, .pdf],
        .readQR: [.image, .pdf],
        .createPDF: [.image, .pdf],
        .mergePDF: [.pdf, .image],
        .split: [.pdf, .video, .audio],
        .join: [.video, .audio],
        .speed: [.video, .audio],
        .normalize: [.audio, .video],
        .mute: [.video],
        .extractAudio: [.video],
        .channels: [.audio],
        .crop: [.image, .video],
        .adjust: [.image],
        .annotate: [.image],
        .redact: [.image, .video],
        .trim: [.video, .audio],
        .snapshot: [.video],
        .bleep: [.audio, .video],
        .visualizer: [.audio],
        .background: [.image],
        .collage: [.image],
        .organizePDF: [.pdf],
        .metadata: [.image, .audio, .video, .pdf, .document],
    ]
    static let implementedArchiveTargets: Set<Format> = [.zip, .tar, .tgz, .gz]

    /// Whether a wheel chip can run for these files in this build/on this Mac.
    public static func isAvailable(_ chip: WheelChip, for items: [InputItem]) -> Bool {
        switch chip {
        case .format(let target):
            if items.count > 1, target.kind == .archive, target != .extract {
                return target != .gz && implementedArchiveTargets.contains(target)
            }
            for item in items where item.format != target {
                guard let engine = ConversionMatrix.engine(from: item.format, kind: item.kind, to: target),
                      implementedEngines.contains(engine) else { return false }
                if engine == .archive && !implementedArchiveTargets.contains(target) { return false }
                if engine == .media && !FFmpegLocator.isAvailable { return false }
                if engine == .image && !canWriteImage(target) { return false }
            }
            return true
        case .tool(let tool):
            guard let kinds = implementedTools[tool], items.allSatisfy({ kinds.contains($0.kind) }) else { return false }
            if items.contains(where: { $0.kind == .audio || $0.kind == .video }) && !FFmpegLocator.isAvailable {
                return false
            }
            if tool == .removeMetadata,
               items.contains(where: { $0.kind == .image && !($0.format.map(canWriteImage) ?? false) }) {
                return false
            }
            return true
        }
    }

    static func canWriteImage(_ format: Format) -> Bool {
        if ImageCodec.canEncodeNatively(format) { return true }
        return (format == .webp || format == .avif) && FFmpegLocator.isAvailable
    }

    // MARK: Execution

    public func execute(_ job: Job) async throws -> JobResult {
        switch job.request.operation {
        case .convert(let target):
            return try await convert(job, to: target)
        case .tool(let tool):
            return try await ToolRunner.run(tool, job: job, engines: self)
        }
    }

    private func convert(_ job: Job, to target: Format) async throws -> JobResult {
        let request = job.request
        if request.inputs.count > 1 {
            guard target.kind == .archive, target != .extract, let first = request.inputs.first else {
                throw JobFailure("Several files can only be combined into an archive.")
            }
            return try await withOutput(for: first, base: "Archive", extension: target.fileExtension, request: request) { url in
                try await ArchiveEngine.create(request.inputs.map(\.url), as: target, at: url)
            }
        }
        guard let item = request.inputs.first else { throw JobFailure("There's nothing to convert.") }
        if item.format == target {
            return JobResult(note: "Already \(target.displayName), skipped.")
        }
        guard let engine = ConversionMatrix.engine(from: item.format, kind: item.kind, to: target) else {
            throw JobFailure("\(item.format?.displayName ?? "This file") can't be converted to \(target.displayName).")
        }
        let settings = self.settings
        let report: @Sendable (Double) -> Void = { job.report($0) }
        switch engine {
        case .image, .imageToPDF, .imageToSVG, .imageToDOCX:
            return try await withOutput(for: item, extension: target.fileExtension, request: request) { url in
                try await ImageEngine.convert(item, to: target, output: url, settings: settings, progress: report)
            }
        case .media:
            return try await withOutput(for: item, extension: target.fileExtension, request: request) { url in
                try await MediaEngine.convert(item, to: target, output: url, settings: settings, progress: report)
            }
        case .subtitle, .textToSubtitle:
            return try await withOutput(for: item, extension: target.fileExtension, request: request) { url in
                let text = try Subtitles.convert(Data(contentsOf: item.url), from: item.format ?? .srt, to: target)
                try Data(text.utf8).write(to: url)
            }
        case .document:
            return try await withOutput(for: item, extension: target.fileExtension, request: request) { url in
                let text = try await DocumentEngine.read(item.url, format: item.format ?? .txt)
                report(0.5)
                try DocumentEngine.write(text, as: target, to: url, title: OutputNamer.baseName(of: item.url))
            }
        case .textToImages:
            let text = try await DocumentEngine.read(item.url, format: item.format ?? .txt)
            let pages = TextPaginator.pageCount(text)
            return try await pagedImages(for: item, count: pages, target: target, request: request) { write in
                try TextPaginator.renderPages(text, dpi: min(settings.pdfDPI, 300)) { index, _, image in
                    try write(index, image)
                    report(Double(index + 1) / Double(pages))
                }
            }
        case .pdfToImages:
            let doc = try PDFEngine.open(item.url)
            let count = doc.pageCount
            let dpi = CGFloat(settings.pdfDPI)
            return try await pagedImages(for: item, count: count, target: target, request: request) { write in
                for i in 0..<count {
                    try Task.checkCancellation()
                    guard let page = doc.page(at: i) else { continue }
                    try autoreleasepool { try write(i, try PDFEngine.render(page, dpi: dpi)) }
                    report(Double(i + 1) / Double(count))
                }
            }
        case .pdfToText:
            return try await withOutput(for: item, extension: target.fileExtension, request: request) { url in
                let doc = try PDFEngine.open(item.url)
                let pages = try PDFEngine.pageTexts(doc) { report($0) }
                let text = pages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n\u{0C}")
                try Data((text + "\n").utf8).write(to: url)
            }
        case .pdfToDOCX:
            return try await withOutput(for: item, extension: target.fileExtension, request: request) { url in
                let doc = try PDFEngine.open(item.url)
                try PDFEngine.docx(from: doc, title: OutputNamer.baseName(of: item.url)) { report($0) }.write(to: url)
            }
        case .archive:
            if item.kind == .archive, let source = item.format {
                return try await withOutput(for: item, extension: target.fileExtension, request: request) { url in
                    try await ArchiveEngine.repack(item.url, format: source, as: target, at: url)
                }
            }
            return try await withOutput(for: item, base: item.url.lastPathComponent, extension: target.fileExtension,
                                        request: request) { url in
                try await ArchiveEngine.create([item.url], as: target, at: url)
            }
        case .extract:
            return try await extract(item, request: request)
        }
    }

    // MARK: Outputs

    /// Plans an atomic output for `item`, runs `body` on its temporary URL,
    /// then commits it (or cleans up on failure/cancel).
    func withOutput(for item: InputItem, base: String? = nil, suffix: String? = nil, extension ext: String,
                    isDirectory: Bool = false, request: JobRequest,
                    _ body: (URL) async throws -> Void) async throws -> JobResult {
        let (output, fellBack) = try makeOutput(for: item, base: base, suffix: suffix, extension: ext,
                                                isDirectory: isDirectory, request: request)
        do {
            try await body(output.tempURL)
            try Task.checkCancellation()
            let final = try output.commit()
            if settings.keepFileDates { Self.copyDates(from: item.url, to: final) }
            return JobResult(outputs: [final], note: fellBack ? Self.fallbackNote : nil)
        } catch {
            output.discard()
            throw error
        }
    }

    static let fallbackNote = "Saved in Downloads because the original folder isn't writable."

    func makeOutput(for item: InputItem, base: String?, suffix: String?, extension ext: String, isDirectory: Bool,
                    request: JobRequest) throws -> (AtomicOutput, Bool) {
        var planner = self.planner
        if let dir = request.outputDirectory { planner.location = .folder(dir) }
        let base = base ?? (item.kind == .folder ? item.url.lastPathComponent : OutputNamer.baseName(of: item.url))
        return try planner.makeOutput(for: item.url, base: base, suffix: suffix, extension: ext, isDirectory: isDirectory)
    }

    /// One image per page: a single file for one page, otherwise a folder
    /// named after the source with "Page 001.jpg"….
    func pagedImages(for item: InputItem, count: Int, target: Format, request: JobRequest,
                     render: ((Int, CGImage) throws -> Void) async throws -> Void) async throws -> JobResult {
        let settings = self.settings
        func encode(_ image: CGImage, to url: URL) throws {
            let quality = target == .jpg ? settings.jpegQuality : nil
            var props: [String: Any] = [:]
            if let quality { props[kCGImageDestinationLossyCompressionQuality as String] = quality }
            if target == .tiff { props[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFCompression as String: 5] }
            let dpi = Double(settings.pdfDPI)
            props[kCGImagePropertyDPIWidth as String] = dpi
            props[kCGImagePropertyDPIHeight as String] = dpi
            try ImageCodec.write(image, as: target, to: url, properties: props)
        }
        if count <= 1 {
            return try await withOutput(for: item, extension: target.fileExtension, request: request) { url in
                try await render { _, image in try encode(image, to: url) }
            }
        }
        return try await withOutput(for: item, extension: "", isDirectory: true, request: request) { folder in
            try await render { index, image in
                let name = OutputNamer.pageName(index + 1, of: count) + "." + target.fileExtension
                try encode(image, to: folder.appendingPathComponent(name))
            }
        }
    }

    /// Extracts next to the archive: a single top-level item comes out as
    /// itself; several go into a folder named after the archive.
    func extract(_ item: InputItem, request: JobRequest) async throws -> JobResult {
        guard let format = item.format else { throw JobFailure("This archive type isn't supported.") }
        let (folder, fellBack) = try makeOutput(for: item, base: nil, suffix: nil, extension: "", isDirectory: true,
                                                request: request)
        let note = fellBack ? Self.fallbackNote : nil
        do {
            try await ArchiveEngine.extract(item.url, format: format, into: folder.tempURL)
            try Task.checkCancellation()
            let contents = try FileManager.default.contentsOfDirectory(at: folder.tempURL, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != ".DS_Store" }
            guard !contents.isEmpty else { throw JobFailure("The archive is empty.") }
            if contents.count == 1, let only = contents.first {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: only.path, isDirectory: &isDir)
                let name = only.lastPathComponent
                let ext = isDir.boolValue ? "" : (name as NSString).pathExtension
                let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
                let single = try AtomicOutput(directory: folder.directory, base: base, extension: ext,
                                              isDirectory: isDir.boolValue)
                try? FileManager.default.removeItem(at: single.tempURL)
                try FileManager.default.moveItem(at: only, to: single.tempURL)
                let final = try single.commit()
                folder.discard()
                return JobResult(outputs: [final], note: note)
            }
            let final = try folder.commit()
            return JobResult(outputs: [final], note: note)
        } catch {
            folder.discard()
            throw error
        }
    }

    static func copyDates(from source: URL, to destination: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: source.path) else { return }
        var dates: [FileAttributeKey: Any] = [:]
        dates[.creationDate] = attrs[.creationDate]
        dates[.modificationDate] = attrs[.modificationDate]
        try? FileManager.default.setAttributes(dates, ofItemAtPath: destination.path)
    }
}
#endif
