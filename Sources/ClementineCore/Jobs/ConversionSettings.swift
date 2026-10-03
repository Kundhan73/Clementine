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
    case custom([String: String])
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
