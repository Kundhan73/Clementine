import Foundation

/// Broad category of a file, used to pick engines, lanes and wheel contents.
public enum FileKind: String, CaseIterable, Codable, Sendable {
    case image, audio, video, pdf, document, subtitle, archive, folder, other
}

/// Every format Clementine reads or writes. Raw values are stable (settings).
public enum Format: String, CaseIterable, Codable, Sendable {
    // Images
    case jpg, png, heic, webp, avif, tiff, bmp, gif, svg
    case psd, ico, icns, jp2, tga, cameraRaw = "raw"
    // PDF and documents
    case pdf, docx, doc, txt, rtf, rtfd, odt, html, md
    // Subtitles
    case srt, vtt, ass
    // Audio
    case mp3, m4a, aac, wav, flac, ogg, opus, aiff, wma, caf, amr, ac3
    // Video
    case mp4, mov, m4v, mkv, webm, avi, wmv, flv, mpeg, threeGP = "3gp", ts
    // Archives
    case zip, tar, tgz, gz, rar, sevenZip = "7z", bz2, xz
    /// Pseudo target: unpack an archive into a folder.
    case extract

    public var kind: FileKind {
        switch self {
        case .jpg, .png, .heic, .webp, .avif, .tiff, .bmp, .gif, .svg,
             .psd, .ico, .icns, .jp2, .tga, .cameraRaw:
            return .image
        case .pdf:
            return .pdf
        case .docx, .doc, .txt, .rtf, .rtfd, .odt, .html, .md:
            return .document
        case .srt, .vtt, .ass:
            return .subtitle
        case .mp3, .m4a, .aac, .wav, .flac, .ogg, .opus, .aiff, .wma, .caf, .amr, .ac3:
            return .audio
        case .mp4, .mov, .m4v, .mkv, .webm, .avi, .wmv, .flv, .mpeg, .threeGP, .ts:
            return .video
        case .zip, .tar, .tgz, .gz, .rar, .sevenZip, .bz2, .xz, .extract:
            return .archive
        }
    }

    /// Short label shown on wheel chips.
    public var displayName: String {
        switch self {
        case .jpg: return "JPG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        case .tiff: return "TIFF"
        case .bmp: return "BMP"
        case .gif: return "GIF"
        case .svg: return "SVG"
        case .psd: return "PSD"
        case .ico: return "ICO"
        case .icns: return "ICNS"
        case .jp2: return "JPEG 2000"
        case .tga: return "TGA"
        case .cameraRaw: return "RAW"
        case .pdf: return "PDF"
        case .docx: return "DOCX"
        case .doc: return "DOC"
        case .txt: return "TXT"
        case .rtf: return "RTF"
        case .rtfd: return "RTFD"
        case .odt: return "ODT"
        case .html: return "HTML"
        case .md: return "MD"
        case .srt: return "SRT"
        case .vtt: return "VTT"
        case .ass: return "ASS"
        case .mp3: return "MP3"
        case .m4a: return "M4A"
        case .aac: return "AAC"
        case .wav: return "WAV"
        case .flac: return "FLAC"
        case .ogg: return "OGG"
        case .opus: return "Opus"
        case .aiff: return "AIFF"
        case .wma: return "WMA"
        case .caf: return "CAF"
        case .amr: return "AMR"
        case .ac3: return "AC3"
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .m4v: return "M4V"
        case .mkv: return "MKV"
        case .webm: return "WebM"
        case .avi: return "AVI"
        case .wmv: return "WMV"
        case .flv: return "FLV"
        case .mpeg: return "MPEG"
        case .threeGP: return "3GP"
        case .ts: return "TS"
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .tgz: return "TGZ"
        case .gz: return "GZIP"
        case .rar: return "RAR"
        case .sevenZip: return "7Z"
        case .bz2: return "BZ2"
        case .xz: return "XZ"
        case .extract: return "Extract"
        }
    }

    /// Extension used when writing this format (without the dot).
    public var fileExtension: String {
        switch self {
        case .cameraRaw: return "dng"
        case .tgz: return "tar.gz"
        case .threeGP: return "3gp"
        case .sevenZip: return "7z"
        case .extract: return ""
        default: return rawValue
        }
    }

    /// One-line hint shown under the hub while a chip is hovered.
    public var caption: String {
        switch self {
        case .jpg: return "JPG · small, universal"
        case .png: return "PNG · lossless"
        case .heic: return "HEIC · small, Apple"
        case .webp: return "WebP · small, web"
        case .avif: return "AVIF · smallest"
        case .tiff: return "TIFF · lossless, print"
        case .bmp: return "BMP · uncompressed"
        case .gif: return kind == .image ? "GIF · 256 colours" : "GIF"
        case .svg: return "SVG · embeds the image"
        case .pdf: return "PDF · document"
        case .docx: return "DOCX · Word"
        case .txt: return "TXT · plain text"
        case .rtf: return "RTF · rich text"
        case .odt: return "ODT · OpenDocument"
        case .html: return "HTML · web page"
        case .md: return "Markdown"
        case .srt: return "SRT · subtitles"
        case .vtt: return "VTT · web subtitles"
        case .mp3: return "MP3 · universal"
        case .m4a: return "M4A · AAC, Apple"
        case .wav: return "WAV · uncompressed"
        case .flac: return "FLAC · lossless"
        case .ogg: return "OGG · Vorbis"
        case .opus: return "Opus · small, voice"
        case .aiff: return "AIFF · uncompressed"
        case .wma: return "WMA · Windows"
        case .mp4: return "MP4 · H.264, universal"
        case .mov: return "MOV · QuickTime"
        case .mkv: return "MKV · Matroska"
        case .webm: return "WebM · VP9, web"
        case .avi: return "AVI · legacy"
        case .wmv: return "WMV · Windows"
        case .zip: return "ZIP archive"
        case .tar: return "TAR archive"
        case .tgz: return "TAR.GZ archive"
        case .gz: return "GZIP · single file"
        case .extract: return "Extract here"
        default: return displayName
        }
    }

    /// Whether files in this format can be produced (as opposed to read-only inputs).
    public var isWritable: Bool { ConversionMatrix.allTargets.contains(self) }

    // MARK: Detection

    private static let byExtension: [String: Format] = {
        var map: [String: Format] = [:]
        func add(_ format: Format, _ exts: String...) { for e in exts { map[e] = format } }
        add(.jpg, "jpg", "jpeg", "jpe", "jfif", "pjpeg")
        add(.png, "png", "apng")
        add(.heic, "heic", "heif", "hif", "heics")
        add(.webp, "webp")
        add(.avif, "avif")
        add(.tiff, "tif", "tiff")
        add(.bmp, "bmp", "dib")
        add(.gif, "gif")
        add(.svg, "svg")
        add(.psd, "psd")
        add(.ico, "ico", "cur")
        add(.icns, "icns")
        add(.jp2, "jp2", "j2k", "jpf", "jpx", "jpm")
        add(.tga, "tga")
        add(.cameraRaw, "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
            "rw2", "pef", "srw", "erf", "3fr", "mef", "mos", "x3f", "raw", "rwl", "iiq")
        add(.pdf, "pdf")
        add(.docx, "docx", "docm", "dotx")
        add(.doc, "doc", "dot")
        add(.txt, "txt", "text")
        add(.rtf, "rtf")
        add(.rtfd, "rtfd")
        add(.odt, "odt")
        add(.html, "html", "htm", "xhtml")
        add(.md, "md", "markdown", "mdown", "mkd")
        add(.srt, "srt")
        add(.vtt, "vtt", "webvtt")
        add(.ass, "ass", "ssa")
        add(.mp3, "mp3")
        add(.m4a, "m4a", "m4b", "m4r")
        add(.aac, "aac", "adts")
        add(.wav, "wav", "wave")
        add(.flac, "flac")
        add(.ogg, "ogg", "oga")
        add(.opus, "opus")
        add(.aiff, "aif", "aiff", "aifc")
        add(.wma, "wma")
        add(.caf, "caf")
        add(.amr, "amr", "awb")
        add(.ac3, "ac3", "eac3")
        add(.mp4, "mp4")
        add(.mov, "mov", "qt")
        add(.m4v, "m4v")
        add(.mkv, "mkv", "mk3d")
        add(.webm, "webm")
        add(.avi, "avi", "divx")
        add(.wmv, "wmv", "asf")
        add(.flv, "flv", "f4v")
        add(.mpeg, "mpg", "mpeg", "m2v", "vob", "mpe")
        add(.threeGP, "3gp", "3g2")
        add(.ts, "ts", "mts", "m2ts", "m2t")
        add(.zip, "zip")
        add(.tar, "tar")
        add(.tgz, "tgz")
        add(.gz, "gz", "gzip")
        add(.rar, "rar")
        add(.sevenZip, "7z")
        add(.bz2, "bz2", "tbz", "tbz2")
        add(.xz, "xz", "txz")
        return map
    }()

    /// Detects the format from a file name. Handles `.tar.gz`-style double
    /// extensions. Returns nil for unknown extensions.
    public static func detect(fileName: String) -> Format? {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".tar.gz") { return .tgz }
        if lower.hasSuffix(".tar.bz2") { return .bz2 }
        if lower.hasSuffix(".tar.xz") { return .xz }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return nil }
        let ext = String(lower[lower.index(after: dot)...])
        return byExtension[ext]
    }

    public static func detect(url: URL) -> Format? { detect(fileName: url.lastPathComponent) }

    /// File name without its (possibly double) extension: "a.tar.gz" → "a".
    public static func baseName(of fileName: String) -> String {
        let lower = fileName.lowercased()
        for double in [".tar.gz", ".tar.bz2", ".tar.xz"] where lower.hasSuffix(double) && lower.count > double.count {
            return String(fileName.dropLast(double.count))
        }
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        return String(fileName[..<dot])
    }
}
