import Foundation

/// User-adjustable quality and behaviour settings that engines read. The app
/// builds this from UserDefaults at job creation; tests use the defaults.
public struct ConversionSettings: Codable, Sendable, Equatable {
    // Images
    public var jpegQuality = 0.85
    public var heicQuality = 0.80
    public var webpQuality = 80          // 0…100
    public var avifQuality = 70          // 0…100 (mapped to an encoder CRF)
    public var keepMetadata = true
    public var keepFileDates = false
    /// Pixel density used when rendering PDF pages to images.
    public var pdfDPI = 300

    // Audio
    public var mp3VBRQuality = 2         // LAME V0…V9; V2 ≈ 190 kbps
    public var aacBitrate = 256          // kbps
    public var opusBitrate = 128
    public var vorbisQuality = 6         // 0…10
    public var flacLevel = 5
    public var wmaBitrate = 192

    // Video
    public enum VideoCodec: String, Codable, Sendable, CaseIterable { case h264, hevc }
    public var videoCodec: VideoCodec = .h264
    /// VideoToolbox quality 1…100 (higher = better).
    public var videoQuality = 65
    public var hardwareEncoding = true
    public var gifFPS = 15
    public var gifMaxWidth = 720
    public var maxConcurrentMediaJobs = 1

    public init() {}
}

/// Parameters for tools (filled in by dialogs and editors).
public enum ToolOptions: Sendable {
    case none
    case compress(CompressOptions)
    case resize(ResizeOptions)
    case rotate(RotateOptions)
    case createPDF(CreatePDFOptions)
    case splitPDF(SplitPDFOptions)
    case splitMedia(SplitMediaOptions)
    case join(JoinOptions)
    case speed(Double)
    case normalize(NormalizeOptions)
    case extractAudio(Format)
    case channels(ChannelOptions)
    /// Editors (image): crop rect in pixels, top-left origin.
    case crop(CGRect)
    case adjust(AdjustParameters)
    case annotate([Annotation])
    case redact([Redaction])
    case background(FrameStyle)
    case collage(CollageStyle)
    case organizePDF([PageRef])
    case metadata(EditableMetadata)
    case custom([String: String])
}

public struct CreatePDFOptions: Sendable, Equatable {
    public enum PageSize: String, Sendable, CaseIterable { case fitImage, a4, letter }
    public var pageSize: PageSize
    /// Margin in points (A4/Letter pages).
    public var margin: Double
    public init(pageSize: PageSize = .fitImage, margin: Double = 0) {
        self.pageSize = pageSize
        self.margin = margin
    }
}

public struct SplitPDFOptions: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case everyPage
        case everyN(Int)
        /// "1-3, 5, 7-10": one output per range.
        case ranges(String)
    }
    public var mode: Mode
    public init(mode: Mode = .everyPage) { self.mode = mode }

    /// Page groups (1-based) for a document with `pageCount` pages.
    public func groups(pageCount: Int) throws -> [[Int]] {
        switch mode {
        case .everyPage:
            return (1...max(1, pageCount)).map { [$0] }
        case .everyN(let n):
            let size = max(1, n)
            return stride(from: 1, through: pageCount, by: size).map { start in
                Array(start...min(pageCount, start + size - 1))
            }
        case .ranges(let text):
            return try PageRanges.parse(text, pageCount: pageCount)
        }
    }
}

/// Parses "1-3, 5, 7-10" style page ranges.
public enum PageRanges {
    public static func parse(_ text: String, pageCount: Int) throws -> [[Int]] {
        var groups: [[Int]] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            let bounds = piece.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = Int(bounds[0]) else { throw JobFailure("“\(piece)” isn't a page or a range like 3-5.") }
            let last = bounds.count == 2 ? (bounds[1].isEmpty ? pageCount : Int(bounds[1])) : first
            guard let last else { throw JobFailure("“\(piece)” isn't a page or a range like 3-5.") }
            guard first >= 1, last >= first, last <= pageCount else {
                throw JobFailure("“\(piece)” is outside pages 1–\(pageCount).")
            }
            groups.append(Array(first...last))
        }
        guard !groups.isEmpty else { throw JobFailure("Enter pages to keep, for example 1-3, 5.") }
        return groups
    }
}

public struct SplitMediaOptions: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case parts(Int)
        case every(seconds: Double)
        /// Split points in seconds (markers).
        case at([Double])
    }
    public var mode: Mode
    public init(mode: Mode = .parts(2)) { self.mode = mode }

    /// (start, duration) segments for a file of `duration` seconds.
    public func segments(duration: Double) -> [(start: Double, duration: Double)] {
        guard duration > 0 else { return [] }
        var points: [Double]
        switch mode {
        case .parts(let n):
            let count = max(1, n)
            points = (1..<count).map { duration * Double($0) / Double(count) }
        case .every(let seconds):
            let step = max(0.5, seconds)
            points = Array(stride(from: step, to: duration, by: step))
        case .at(let marks):
            points = marks.filter { $0 > 0.05 && $0 < duration - 0.05 }.sorted()
        }
        let edges = [0] + points + [duration]
        return zip(edges, edges.dropFirst()).map { ($0, $1 - $0) }.filter { $0.1 > 0.05 }
    }
}

public struct JoinOptions: Sendable, Equatable {
    /// Indexes into the request's inputs, in the order to join.
    public var order: [Int]?
    public init(order: [Int]? = nil) { self.order = order }
}

public struct NormalizeOptions: Sendable, Equatable {
    public var integratedLUFS: Double
    public var truePeak: Double
    public var loudnessRange: Double
    public init(integratedLUFS: Double = -16, truePeak: Double = -1, loudnessRange: Double = 11) {
        self.integratedLUFS = integratedLUFS
        self.truePeak = truePeak
        self.loudnessRange = loudnessRange
    }
}

public struct ChannelOptions: Sendable, Equatable {
    public enum Mode: String, Sendable, CaseIterable { case mono, stereo, leftOnly, rightOnly, swap }
    public var mode: Mode
    public var leftGainDB: Double
    public var rightGainDB: Double
    public init(mode: Mode = .mono, leftGainDB: Double = 0, rightGainDB: Double = 0) {
        self.mode = mode
        self.leftGainDB = leftGainDB
        self.rightGainDB = rightGainDB
    }
}

public struct CompressOptions: Sendable, Equatable {
    public enum Preset: String, Sendable, CaseIterable {
        case high, medium, small, email, discord, whatsapp
    }
    public var preset: Preset
    /// Exact target in bytes; overrides the preset when set.
    public var targetBytes: Int64?

    public init(preset: Preset = .medium, targetBytes: Int64? = nil) {
        self.preset = preset
        self.targetBytes = targetBytes
    }

    /// Size limit implied by a messaging-app preset.
    public var presetLimitBytes: Int64? {
        switch preset {
        case .email: return 25 * 1_000_000
        case .discord: return 10 * 1_000_000
        case .whatsapp: return 16 * 1_000_000
        default: return nil
        }
    }
}

public struct ResizeOptions: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case percent(Double)
        case fit(width: Int?, height: Int?)
        case longestEdge(Int)
    }
    public var mode: Mode
    public init(mode: Mode) { self.mode = mode }
}

public struct RotateOptions: Sendable, Equatable {
    public enum Turn: Int, Sendable { case none = 0, right = 90, half = 180, left = 270 }
    public var turn: Turn
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public init(turn: Turn = .right, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.turn = turn
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }
}
