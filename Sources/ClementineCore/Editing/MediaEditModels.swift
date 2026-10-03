import Foundation

// Options for the media editors (0.5). Platform-neutral so they can be
// unit-tested anywhere; the ffmpeg side lives in `MediaEditing`.

/// Keep `start…end` (seconds) of a video or audio file.
public struct TrimOptions: Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// Re-encode for frame-exact cuts. Otherwise streams are copied (instant,
    /// lossless) and video cuts land on the nearest earlier keyframe.
    public var precise: Bool
    /// Audio fades in seconds (0 = none).
    public var fadeIn: Double
    public var fadeOut: Double

    public init(start: Double, end: Double, precise: Bool = false, fadeIn: Double = 0, fadeOut: Double = 0) {
        self.start = start
        self.end = end
        self.precise = precise
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public var duration: Double { max(0, end - start) }
    public var hasFades: Bool { fadeIn > 0 || fadeOut > 0 }
}

/// Replace parts of the sound with a tone or silence.
public struct BleepOptions: Sendable, Equatable {
    public enum Sound: Sendable, Equatable {
        case tone(frequency: Double)
        case silence
    }

    public var intervals: [ClosedRange<Double>]
    public var sound: Sound
    /// Tone level, 0…1 of full scale.
    public var level: Double

    public init(intervals: [ClosedRange<Double>], sound: Sound = .tone(frequency: 1000), level: Double = 0.3) {
        self.intervals = intervals
        self.sound = sound
        self.level = level
    }

    /// Sorted, non-overlapping intervals clipped to the file's length.
    public func merged(duration: Double?) -> [ClosedRange<Double>] {
        var clipped: [ClosedRange<Double>] = []
        for r in intervals {
            let lo = max(0, r.lowerBound)
            let hi = duration.map { min($0, r.upperBound) } ?? r.upperBound
            if hi - lo >= 0.01 { clipped.append(lo...hi) }
        }
        clipped.sort { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Double>] = []
        for r in clipped {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}

/// Turn audio into a video with a moving visual.
public struct VisualizerOptions: Sendable, Equatable {
    public enum Style: String, Sendable, CaseIterable {
        case waveform, bars, circle, spectrogram
        public var displayName: String {
            switch self {
            case .waveform: return "Waveform"
            case .bars: return "Bars"
            case .circle: return "Circle"
            case .spectrogram: return "Spectrogram"
            }
        }
    }

    public enum Background: Sendable, Equatable {
        case solid(RGBA)
        case gradient(RGBA, RGBA)
        /// The file's cover art, or the gradient when it has none.
        case coverArt
        /// Blurred and darkened cover art (gradient when there is none).
        case blurredCover
    }

    public enum Shape: String, Sendable, CaseIterable {
        case landscape, square, portrait
        public var size: (width: Int, height: Int) {
            switch self {
            case .landscape: return (1920, 1080)
            case .square: return (1080, 1080)
            case .portrait: return (1080, 1920)
            }
        }
        public var displayName: String {
            switch self {
            case .landscape: return "16:9 (1920 × 1080)"
            case .square: return "Square (1080 × 1080)"
            case .portrait: return "9:16 (1080 × 1920)"
            }
        }
    }

    public var style: Style
    public var color: RGBA
    public var background: Background
    /// Shown at the top; empty for none.
    public var title: String
    public var shape: Shape

    public init(style: Style = .waveform, color: RGBA = .orange, background: Background = .blurredCover,
                title: String = "", shape: Shape = .landscape) {
        self.style = style
        self.color = color
        self.background = background
        self.title = title
        self.shape = shape
    }
}

public extension RGBA {
    /// "0xRRGGBB" for ffmpeg colour options.
    var ffmpegHex: String {
        func byte(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "0x%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
