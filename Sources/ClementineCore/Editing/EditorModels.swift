#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// Plain data models for the editors. They are platform-neutral so tool
// options (and their tests) compile everywhere; rendering lives in the
// AppKit/Core Image engines.

/// A colour that can be stored in documents and settings (sRGB, 0…1).
public struct RGBA: Codable, Equatable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
    public static let white = RGBA(1, 1, 1), black = RGBA(0, 0, 0), red = RGBA(0.93, 0.2, 0.17)
    public static let orange = RGBA(0.96, 0.5, 0.1), yellow = RGBA(1, 0.85, 0.1), blue = RGBA(0.1, 0.45, 0.95)
    public static let green = RGBA(0.2, 0.7, 0.3)
}

/// One drawing on top of an image. Coordinates are pixels, top-left origin.
public struct Annotation: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case pen, highlighter, line, arrow, rectangle, ellipse, text, marker }
    public var id = UUID()
    public var kind: Kind
    public var points: [CGPoint]
    public var color: RGBA
    public var lineWidth: Double
    public var filled = false
    public var text = ""
    public var fontSize: Double = 32
    public var number = 1

    public init(kind: Kind, points: [CGPoint], color: RGBA, lineWidth: Double) {
        self.kind = kind
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
    }

    public var markerDiameter: Double { max(28, fontSize * 1.3) }
}

/// An area to hide. `rect` in pixels, top-left origin.
public struct Redaction: Codable, Identifiable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable, CaseIterable { case solid, blur, pixelate }
    public var id = UUID()
    public var rect: CGRect
    public var style: Style
    public var color: RGBA = .black
    /// Video only: visible from…to seconds (nil = whole clip).
    public var start: Double?
    public var end: Double?

    public init(rect: CGRect, style: Style) {
        self.rect = rect
        self.style = style
    }
}

public struct FrameStyle: Codable, Equatable, Sendable {
    public enum Aspect: String, Codable, Sendable, CaseIterable {
        case original, square, portrait4x5, landscape16x9, story9x16, photo3x2
        public var ratio: CGFloat? {
            switch self {
            case .original: return nil
            case .square: return 1
            case .portrait4x5: return 4.0 / 5.0
            case .landscape16x9: return 16.0 / 9.0
            case .story9x16: return 9.0 / 16.0
            case .photo3x2: return 3.0 / 2.0
            }
        }
    }
    public enum Fill: Codable, Equatable, Sendable {
        case none
        case solid(RGBA)
        case gradient(RGBA, RGBA)
        case blurredSelf
    }
    /// Padding as a fraction of the image's longer side.
    public var padding: Double = 0.08
    /// Corner radius as a fraction of the image's shorter side.
    public var cornerRadius: Double = 0.04
    public var shadow: Double = 0.5
    public var aspect: Aspect = .original
    public var fill: Fill = .gradient(RGBA(1.0, 0.62, 0.25), RGBA(0.93, 0.33, 0.45))
    public var removeBackground = false
    public init() {}
}

public struct CollageStyle: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, Sendable, CaseIterable { case grid, row, column, featured }
    public var layout: Layout = .grid
    public var spacing: Double = 12
    public var padding: Double = 24
    public var cornerRadius: Double = 10
    public var background: RGBA = .white
    public var outputWidth: Int = 2400
    public init() {}
}

/// Slider values for the Adjust editor. 0 means "unchanged" for every field.
public struct AdjustParameters: Codable, Equatable, Sendable {
    public var exposure: Double = 0       // −2…2 EV
    public var brightness: Double = 0     // −1…1
    public var contrast: Double = 0       // −1…1
    public var highlights: Double = 0     // −1…1
    public var shadows: Double = 0        // −1…1
    public var saturation: Double = 0     // −1…1
    public var vibrance: Double = 0       // −1…1
    public var warmth: Double = 0         // −1…1
    public var tint: Double = 0           // −1…1
    public var sharpness: Double = 0      // 0…1
    public var clarity: Double = 0        // 0…1
    public var dehaze: Double = 0         // 0…1
    public var grain: Double = 0          // 0…1
    public var noiseReduction: Double = 0 // 0…1
    public var vignette: Double = 0       // 0…1

    public init() {}

    public var isIdentity: Bool { self == AdjustParameters() }

    /// Field names and ranges for building the editor UI.
    public static let fields: [(key: WritableKeyPath<AdjustParameters, Double>, title: String, range: ClosedRange<Double>)] = [
        (\.exposure, "Exposure", -2...2), (\.brightness, "Brightness", -1...1), (\.contrast, "Contrast", -1...1),
        (\.highlights, "Highlights", -1...1), (\.shadows, "Shadows", -1...1), (\.saturation, "Saturation", -1...1),
        (\.vibrance, "Vibrance", -1...1), (\.warmth, "Warmth", -1...1), (\.tint, "Tint", -1...1),
        (\.sharpness, "Sharpness", 0...1), (\.clarity, "Clarity", 0...1), (\.dehaze, "Dehaze", 0...1),
        (\.grain, "Grain", 0...1), (\.noiseReduction, "Noise Reduction", 0...1), (\.vignette, "Vignette", 0...1),
    ]
}

/// Fields the inspector can edit (saved as a copy).
public struct EditableMetadata: Equatable, Sendable {
    public var title = ""
    public var author = ""
    public var comment = ""
    public var copyright = ""

    public init() {}
}

/// Page operations for Organize PDF.
public struct PageRef: Identifiable, Hashable, Sendable {
    public var id = UUID()
    /// Index into the source documents.
    public var source: Int
    /// 0-based page index in that source.
    public var page: Int
    /// Extra rotation in degrees (multiples of 90).
    public var rotation: Int

    public init(source: Int, page: Int, rotation: Int = 0) {
        self.source = source
        self.page = page
        self.rotation = rotation
    }
}
