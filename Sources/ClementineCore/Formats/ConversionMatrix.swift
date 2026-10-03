import Foundation

/// A dragged or chosen file, classified once.
public struct InputItem: Hashable, Sendable {
    public let url: URL
    public let format: Format?
    public let kind: FileKind

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        let format = Format.detect(url: url)
        // .rtfd is a document package (a folder on disk).
        if isDirectory && format != .rtfd {
            self.format = nil
            self.kind = .folder
        } else {
            self.format = format
            self.kind = format?.kind ?? .other
        }
    }

    /// Classifies a file on disk.
    public static func inspect(_ url: URL) -> InputItem {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return InputItem(url: url, isDirectory: isDir.boolValue)
    }

    /// Classifies a file promise (no file on disk yet) by its type's extension.
    public init(promisedName: String) {
        self.init(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(promisedName), isDirectory: false)
    }
}

/// Which engine handles a (source, target) pair.
public enum EngineKind: String, Sendable {
    case image, imageToPDF, imageToSVG, imageToDOCX
    case media
    case pdfToImages, pdfToText, pdfToDOCX
    case document, textToImages
    case subtitle, textToSubtitle
    case archive, extract
}

/// The single source of truth for conversions: (source format → ordered
/// targets). The wheel, tests and docs read it.
public enum ConversionMatrix {
    public static let imageSources: [Format] = [.jpg, .png, .heic, .webp, .avif, .tiff, .bmp, .gif, .svg,
                                                .psd, .ico, .icns, .jp2, .tga, .cameraRaw]
    public static let imageTargets: [Format] = [.jpg, .png, .heic, .webp, .pdf, .avif, .gif, .tiff, .bmp,
                                                .svg, .docx]
    public static let audioSources: [Format] = [.mp3, .m4a, .aac, .wav, .flac, .ogg, .opus, .aiff, .wma,
                                                .caf, .amr, .ac3]
    public static let audioTargets: [Format] = [.mp3, .m4a, .wav, .flac, .aiff, .ogg, .opus, .wma]
    public static let videoSources: [Format] = [.mp4, .mov, .m4v, .mkv, .webm, .avi, .wmv, .flv, .mpeg,
                                                .threeGP, .ts]
    public static let videoTargets: [Format] = [.mp4, .mov, .gif, .mp3, .webm, .mkv, .m4a, .avi, .wav, .wmv]
    /// GIF → video (an animated GIF is also a short silent video).
    public static let gifVideoTargets: [Format] = [.mp4, .mov, .webm, .mkv, .avi, .wmv]
    public static let richDocumentSources: [Format] = [.docx, .doc, .rtf, .rtfd, .odt, .html, .md]
    public static let richDocumentTargets: [Format] = [.pdf, .docx, .txt, .rtf, .html, .odt, .md]
    public static let archiveSources: [Format] = [.zip, .tar, .tgz, .gz, .rar, .sevenZip, .bz2, .xz]

    /// Ordered conversion targets for one source format (without archiving).
    public static func targets(for source: Format) -> [Format] {
        switch source {
        case .gif:
            return [.mp4, .png, .jpg, .webp, .mov, .webm, .heic, .avif, .pdf, .mkv, .avi, .wmv, .tiff, .bmp,
                    .svg, .docx]
        case _ where imageSources.contains(source):
            return imageTargets.filter { $0 != source }
        case _ where audioSources.contains(source):
            return audioTargets.filter { $0 != source }
        case _ where videoSources.contains(source):
            return videoTargets.filter { $0 != source }
        case .pdf:
            return [.docx, .jpg, .png, .txt, .tiff]
        case .txt:
            return [.pdf, .docx, .jpg, .png, .srt, .vtt, .rtf, .html, .md]
        case .docx:
            return [.pdf, .txt, .rtf, .html, .odt, .md, .jpg, .png]
        case _ where richDocumentSources.contains(source):
            return richDocumentTargets.filter { $0 != source }
        case .srt:
            return [.vtt, .txt]
        case .vtt:
            return [.srt, .txt]
        case .ass:
            return [.srt, .vtt]
        case .zip:
            return [.extract, .tar, .tgz]
        case .tar:
            return [.extract, .zip, .tgz]
        case .tgz:
            return [.extract, .zip, .tar]
        case .rar, .sevenZip:
            return [.extract, .zip, .tar, .tgz]
        case .gz, .bz2, .xz:
            return [.extract]
        default:
            return []
        }
    }

    /// Archive targets offered for an item, appended after its conversions.
    public static func archiveTargets(for kind: FileKind) -> [Format] {
        switch kind {
        case .folder, .other: return [.zip, .tar, .tgz]
        case .archive: return []
        default: return [.zip]
        }
    }

    /// Every target for an item: conversions, then archiving.
    public static func allTargets(for item: InputItem) -> [Format] {
        var result = item.format.map(targets(for:)) ?? []
        for t in archiveTargets(for: item.kind) where !result.contains(t) { result.append(t) }
        if item.kind == .other { result.append(.gz) }
        return result
    }

    /// Every (source, target) pair, including archiving each source to ZIP.
    public static var pairs: [(source: Format, target: Format)] {
        var result: [(Format, Format)] = []
        for source in Format.allCases where source != .extract {
            var targets = Self.targets(for: source)
            for t in archiveTargets(for: source.kind) where !targets.contains(t) { targets.append(t) }
            result += targets.map { (source, $0) }
        }
        return result
    }

    /// Every format that can be produced.
    public static let allTargets: Set<Format> = Set(pairs.map(\.target))

    /// Which engine converts `source` to `target`; nil if unsupported.
    public static func engine(from source: Format?, kind: FileKind, to target: Format) -> EngineKind? {
        if target == .extract { return kind == .archive ? .extract : nil }
        if [.zip, .tar, .tgz, .gz].contains(target) && kind != .archive { return .archive }
        guard let source else { return nil }
        guard targets(for: source).contains(target) else { return nil }
        switch (source.kind, target.kind) {
        case (.image, .image): return target == .svg ? .imageToSVG : .image
        case (.image, .pdf): return .imageToPDF
        case (.image, .document): return .imageToDOCX
        case (.image, .video): return .media // animated GIF → video
        case (.audio, _), (.video, _): return .media
        case (.pdf, .image): return .pdfToImages
        case (.pdf, .document): return target == .txt ? .pdfToText : .pdfToDOCX
        case (.document, .image): return .textToImages
        case (.document, .subtitle): return .textToSubtitle
        case (.document, _): return .document
        case (.subtitle, _): return .subtitle
        case (.archive, .archive): return .archive
        default: return nil
        }
    }

}
