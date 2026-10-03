#if canImport(ImageIO)
import Foundation

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

    public static let implementedEngines: Set<EngineKind> = [.image, .imageToPDF, .imageToSVG, .imageToDOCX, .archive]
    /// Tools and the file kinds they are implemented for so far.
    public static let implementedTools: [Tool: Set<FileKind>] = [
        .removeMetadata: [.image],
        .readQR: [.image],
    ]
    static let implementedArchiveTargets: Set<Format> = [.zip]

    /// Whether a wheel chip can run for these files in this build/on this Mac.
    public static func isAvailable(_ chip: WheelChip, for items: [InputItem]) -> Bool {
        switch chip {
        case .format(let target):
            if items.count > 1, target.kind == .archive, target != .extract {
                return implementedArchiveTargets.contains(target)
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
            guard let kinds = implementedTools[tool] else { return false }
            if tool == .removeMetadata && items.contains(where: { !($0.format.map(canWriteImage) ?? false) }) {
                return false
            }
            return items.allSatisfy { kinds.contains($0.kind) }
        }
    }

    static func canWriteImage(_ format: Format) -> Bool {
        if ImageCodec.canEncodeNatively(format) { return true }
        return (format == .webp || format == .avif) && FFmpegLocator.isAvailable
    }

    // MARK: Execution

    public func execute(_ job: Job) async throws -> JobResult {
        let request = job.request
        switch request.operation {
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
        switch engine {
        case .image, .imageToPDF, .imageToSVG, .imageToDOCX:
            return try await withOutput(for: item, extension: target.fileExtension, request: request) { url in
                try await ImageEngine.convert(item, to: target, output: url, settings: settings) { job.report($0) }
            }
        case .archive:
            return try await withOutput(for: item, base: item.url.lastPathComponent, extension: target.fileExtension,
                                        request: request) { url in
                try await ArchiveEngine.create([item.url], as: target, at: url)
            }
        default:
            throw JobFailure("\(item.format?.displayName ?? "This file") → \(target.displayName) isn't available in this version yet.")
        }
    }

    /// Plans an atomic output for `item`, runs `body` on its temporary URL,
    /// then commits it (or cleans up on failure/cancel).
    func withOutput(for item: InputItem, base: String? = nil, suffix: String? = nil, extension ext: String,
                    isDirectory: Bool = false, request: JobRequest,
                    _ body: (URL) async throws -> Void) async throws -> JobResult {
        var planner = self.planner
        if let dir = request.outputDirectory { planner.location = .folder(dir) }
        let base = base ?? (item.kind == .folder ? item.url.lastPathComponent : OutputNamer.baseName(of: item.url))
        let (output, fellBack) = try planner.makeOutput(for: item.url, base: base, suffix: suffix, extension: ext,
                                                        isDirectory: isDirectory)
        do {
            try await body(output.tempURL)
            try Task.checkCancellation()
            let final = try output.commit()
            if settings.keepFileDates { Self.copyDates(from: item.url, to: final) }
            return JobResult(outputs: [final],
                             note: fellBack ? "Saved in Downloads because the original folder isn't writable." : nil)
        } catch {
            output.discard()
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
