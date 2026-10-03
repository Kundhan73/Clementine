#if canImport(ImageIO)
import CoreGraphics
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension JobResult {
    func adding(note extra: String?) -> JobResult {
        guard let extra else { return self }
        var copy = self
        copy.note = [note, extra].compactMap { $0 }.joined(separator: " · ")
        return copy
    }
}

/// Runs ⇧⌥-wheel tools with the options from their dialogs (defaults when
/// run instantly).
enum ToolRunner {
    static func run(_ tool: Tool, job: Job, engines: Engines) async throws -> JobResult {
        let request = job.request
        guard let first = request.inputs.first else { throw JobFailure("There's nothing to work on.") }
        let settings = engines.settings
        let report: @Sendable (Double) -> Void = { job.report($0) }
        let sameFormat = first.format ?? .png

        /// Single output next to `first` with the tool's suffix.
        func single(suffix: String? = tool.outputSuffix, format: Format,
                    _ body: (URL) async throws -> String?) async throws -> JobResult {
            var note: String?
            let result = try await engines.withOutput(for: first, suffix: suffix, extension: format.fileExtension,
                                                      request: request) { url in
                note = try await body(url)
            }
            return result.adding(note: note)
        }

        switch tool {
        case .compress:
            let options: CompressOptions
            if case .compress(let o) = request.options { options = o } else { options = CompressOptions() }
            switch first.kind {
            case .image:
                let format = ImageCompressor.outputFormat(for: first.format, hasAlpha: first.format == .png)
                return try await single(format: format) { url in
                    try await ImageCompressor.compress(first, to: url, format: format, options: options,
                                                       settings: settings, progress: report)
                }
            case .video:
                return try await single(format: .mp4) { url in
                    try await MediaTools.compressVideo(first.url, to: url, options: options, settings: settings, progress: report)
                }
            case .audio:
                let format: Format = first.format == .mp3 ? .mp3 : .m4a
                return try await single(format: format) { url in
                    try await MediaTools.compressAudio(first.url, format: format, to: url, options: options, progress: report)
                }
            case .pdf:
                return try await single(format: .pdf) { url in
                    try PDFTools.compress(first.url, options: options, to: url) { report($0) }
                }
            default:
                break
            }

        case .resize:
            let options: ResizeOptions
            if case .resize(let o) = request.options { options = o } else { options = ResizeOptions(mode: .percent(50)) }
            if first.kind == .image {
                let format = ImageTools.toolOutputFormat(for: first.format)
                return try await single(format: format) { url in
                    try await ImageTools.resize(first, options: options, to: url, format: format, settings: settings)
                    return nil
                }
            }
            if first.kind == .video {
                let format = videoOutput(first.format)
                return try await single(format: format) { url in
                    try await MediaTools.resize(first.url, format: format, options: options, to: url, settings: settings,
                                                progress: report)
                    return nil
                }
            }

        case .rotate:
            let options: RotateOptions
            if case .rotate(let o) = request.options { options = o } else { options = RotateOptions() }
            switch first.kind {
            case .image:
                let format = ImageTools.toolOutputFormat(for: first.format)
                return try await single(format: format) { url in
                    try await ImageTools.rotate(first, options: options, to: url, format: format, settings: settings)
                    return nil
                }
            case .video:
                let format = videoOutput(first.format)
                return try await single(format: format) { url in
                    try await MediaTools.rotate(first.url, format: format, options: options, to: url, settings: settings,
                                                progress: report)
                    return nil
                }
            case .pdf:
                return try await single(format: .pdf) { url in
                    try PDFTools.rotate(first.url, options: options, to: url)
                    return nil
                }
            default:
                break
            }

        case .removeMetadata:
            switch first.kind {
            case .image:
                return try await single(format: sameFormat) { url in
                    try await ImageTools.stripMetadata(first, to: url, settings: settings)
                    return nil
                }
            case .audio, .video:
                return try await single(format: sameFormat) { url in
                    try await MediaTools.stripMetadata(first.url, to: url, progress: report)
                    return nil
                }
            case .pdf:
                return try await single(format: .pdf) { url in
                    try PDFTools.stripMetadata(first.url, to: url)
                    return nil
                }
            default:
                break
            }

        case .readQR:
            let codes: [String]
            if first.kind == .pdf {
                codes = try PDFTools.readCodes(first.url)
            } else {
                let decoded = try ImageCodec.decode(first.url, format: first.format)
                job.report(0.5)
                codes = try ImageTools.readCodes(in: decoded.image)
            }
            guard !codes.isEmpty else {
                throw JobFailure("No QR code or barcode found in \(first.kind == .pdf ? "this PDF" : "this image").")
            }
            return JobResult(text: codes.joined(separator: "\n"))

        case .createPDF, .mergePDF:
            let options: CreatePDFOptions
            if case .createPDF(let o) = request.options { options = o } else { options = CreatePDFOptions() }
            let base = tool == .mergePDF ? "Merged" : "Images"
            return try await engines.withOutput(for: first, base: base, extension: "pdf", request: request) { url in
                try PDFTools.merge(request.inputs, to: url, pageSize: options) { report($0) }
            }

        case .split:
            let base = OutputNamer.baseName(of: first.url)
            var count = 0
            let result = try await engines.withOutput(for: first, suffix: "split", extension: "", isDirectory: true,
                                                      request: request) { folder in
                if first.kind == .pdf {
                    let options: SplitPDFOptions
                    if case .splitPDF(let o) = request.options { options = o } else { options = SplitPDFOptions() }
                    count = try PDFTools.split(first.url, options: options, into: folder, base: base)
                } else {
                    let options: SplitMediaOptions
                    if case .splitMedia(let o) = request.options { options = o } else { options = SplitMediaOptions() }
                    count = try await MediaTools.split(first.url, format: sameFormat, options: options, into: folder,
                                                       base: base, progress: report)
                }
            }
            return result.adding(note: "\(count) parts")

        case .join:
            var inputs = request.inputs
            if case .join(let o) = request.options, let order = o.order, order.count == inputs.count {
                inputs = order.map { request.inputs[$0] }
            }
            let isVideo = inputs.allSatisfy { $0.kind == .video }
            let firstFormat = inputs.first?.format
            let format: Format = isVideo
                ? (firstFormat.map { [.mp4, .mov, .mkv].contains($0) } == true ? firstFormat! : .mp4)
                : (firstFormat.map { ConversionMatrix.audioTargets.contains($0) } == true ? firstFormat! : .m4a)
            return try await engines.withOutput(for: first, base: "Joined", extension: format.fileExtension,
                                                request: request) { url in
                try await MediaTools.join(inputs.map(\.url), to: url, format: format, settings: settings, progress: report)
            }

        case .speed:
            var factor = 1.5
            if case .speed(let f) = request.options { factor = f }
            let format = first.kind == .video ? videoOutput(first.format) : audioOutput(first.format)
            let label = String(format: "%gx", factor)
            return try await single(suffix: label, format: format) { url in
                try await MediaTools.speed(first.url, format: format, factor: factor, to: url, settings: settings,
                                           progress: report)
                return nil
            }

        case .normalize:
            let options: NormalizeOptions
            if case .normalize(let o) = request.options { options = o } else { options = NormalizeOptions() }
            let format = first.kind == .video ? videoOutput(first.format) : audioOutput(first.format)
            return try await single(format: format) { url in
                try await MediaTools.normalize(first.url, format: format, options: options, to: url, settings: settings,
                                               progress: report)
            }

        case .mute:
            return try await single(format: videoOutput(first.format)) { url in
                try await MediaTools.mute(first.url, to: url, progress: report)
                return nil
            }

        case .extractAudio:
            var format: Format = .mp3
            if case .extractAudio(let f) = request.options { format = f }
            return try await engines.withOutput(for: first, extension: format.fileExtension, request: request) { url in
                try await MediaEngine.convert(first, to: format, output: url, settings: settings, progress: report)
            }

        case .channels:
            let options: ChannelOptions
            if case .channels(let o) = request.options { options = o } else { options = ChannelOptions() }
            let format = audioOutput(first.format)
            let label: String
            switch options.mode {
            case .mono: label = "mono"
            case .stereo: label = "stereo"
            case .leftOnly: label = "left"
            case .rightOnly: label = "right"
            case .swap: label = "swapped"
            }
            return try await single(suffix: label, format: format) { url in
                try await MediaTools.channels(first.url, format: format, options: options, to: url, settings: settings,
                                              progress: report)
                return nil
            }

        case .crop, .adjust, .annotate, .redact, .background:
            guard first.kind == .image else { break }
            let format = tool == .background ? .png : ImageTools.toolOutputFormat(for: first.format)
            let options = request.options
            return try await single(format: format) { url in
                var decoded = try ImageCodec.decode(first.url, format: first.format)
                report(0.3)
                var keepMetadata = settings.keepMetadata
                switch options {
                case .crop(let rect): decoded.image = try ImageCrop.crop(decoded.image, to: rect)
                case .adjust(let p): decoded.image = try ImageAdjuster.render(p, image: decoded.image)
                case .annotate(let a): decoded.image = try AnnotationRenderer.render(decoded.image, annotations: a)
                case .redact(let r):
                    decoded.image = try Redactor.render(decoded.image, redactions: r)
                    keepMetadata = false
                case .background(let style):
                    decoded.image = try Framer.render(decoded.image, style: style)
                    decoded.hasAlpha = true
                default:
                    throw JobFailure("Nothing to save.")
                }
                report(0.8)
                try await ImageCodec.encode(decoded, as: format, to: url, settings: settings,
                                            quality: format == .jpg || format == .heic ? 0.95 : nil,
                                            keepMetadata: keepMetadata)
                return nil
            }

        case .collage:
            guard case .collage(let style) = request.options else { throw JobFailure("Choose a collage layout.") }
            return try await engines.withOutput(for: first, base: "Collage", extension: "png", request: request) { url in
                var images: [CGImage] = []
                for (i, item) in request.inputs.enumerated() {
                    // Collage cells are small: decode downsized to save memory.
                    images.append(try ImageCodec.decode(item.url, format: item.format).image)
                    report(Double(i + 1) / Double(request.inputs.count) * 0.7)
                }
                let image = try Collage.render(images, style: style)
                try ImageCodec.write(image, as: .png, to: url)
            }

        case .organizePDF:
            guard case .organizePDF(let pages) = request.options else { throw JobFailure("Nothing to save.") }
            return try await single(format: .pdf) { url in
                let tmp = try TempDirectory(prefix: "clementine-organize")
                defer { tmp.remove() }
                var sources: [PDFDocument] = []
                for (i, item) in request.inputs.enumerated() {
                    if item.kind == .pdf {
                        sources.append(try PDFEngine.open(item.url))
                    } else {
                        let page = tmp.file("insert-\(i).pdf")
                        try PDFTools.merge([item], to: page)
                        sources.append(try PDFEngine.open(page))
                    }
                }
                try PDFOrganizer.write(sources: sources, pages: pages, to: url)
                return nil
            }

        case .metadata:
            guard case .metadata(let fields) = request.options else { throw JobFailure("Nothing to save.") }
            return try await single(suffix: "edited", format: sameFormat) { url in
                try await MetadataInspector.write(first, fields: fields, to: url)
                return nil
            }

        default:
            break
        }
        throw JobFailure("\(tool.displayName) isn't available for this file in this version yet.")
    }

    /// Output container for video tools: the source's when writable.
    static func videoOutput(_ format: Format?) -> Format {
        guard let format, [.mp4, .mov, .mkv, .webm, .avi, .wmv].contains(format) else { return .mp4 }
        return format
    }

    static func audioOutput(_ format: Format?) -> Format {
        guard let format, ConversionMatrix.audioTargets.contains(format) else { return .m4a }
        return format
    }
}
#endif
