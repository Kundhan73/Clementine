#if canImport(CoreImage)
import CoreGraphics
import CoreImage
import Foundation

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

/// Applies `AdjustParameters` with Core Image.
public enum ImageAdjuster {
    /// Shared context (Metal-backed when available); safe to use from any thread.
    public static let context = CIContext(options: [.cacheIntermediates: false])

    public static func apply(_ p: AdjustParameters, to input: CIImage) -> CIImage {
        var image = input
        let extent = input.extent
        if p.noiseReduction > 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02 + 0.06 * p.noiseReduction,
                                                                          "inputSharpness": 0.4])
        }
        if p.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: p.exposure])
        }
        if p.highlights != 0 || p.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + min(0, p.highlights),
                "inputShadowAmount": p.shadows,
            ])
            if p.highlights > 0 {
                // Brighten highlights with a gentle tone curve.
                image = image.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.12 * p.highlights),
                    "inputPoint4": CIVector(x: 1, y: 1),
                ])
            }
        }
        if p.dehaze > 0 {
            // Dehaze ≈ pull the black point down and add local contrast and colour.
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.08 * p.dehaze, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.22),
                "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: 0.77),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
            image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 40.0, kCIInputIntensityKey: 0.4 * p.dehaze])
        }
        if p.brightness != 0 || p.contrast != 0 || p.saturation != 0 || p.dehaze > 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: p.brightness * 0.25,
                kCIInputContrastKey: 1 + p.contrast * 0.5,
                kCIInputSaturationKey: 1 + p.saturation + 0.15 * p.dehaze,
            ])
        }
        if p.vibrance != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": p.vibrance])
        }
        if p.warmth != 0 || p.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - p.warmth * 2500, y: p.tint * 60),
            ])
        }
        if p.clarity > 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 20.0, kCIInputIntensityKey: 0.8 * p.clarity])
        }
        if p.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 1.5 * p.sharpness,
                                                                            kCIInputRadiusKey: 1.5])
        }
        if p.vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 1.5 * p.vignette,
                                                                    kCIInputRadiusKey: 1.6])
        }
        if p.grain > 0 {
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.12 * p.grain),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ])
                .cropped(to: extent)
            image = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
        }
        return image.cropped(to: extent)
    }

    /// Full-resolution render for export.
    public static func render(_ p: AdjustParameters, image: CGImage) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let output = apply(p, to: input)
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : ImageCodec.sRGB
        guard let cg = context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: space) else {
            throw JobFailure("Couldn't apply the adjustments.")
        }
        return cg
    }
}
#endif
