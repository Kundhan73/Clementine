import AppKit
import ClementineCore

/// UserDefaults keys. SwiftUI settings views bind to the same keys with
/// @AppStorage, so values are always read fresh from UserDefaults.
enum PrefKey {
    static let shiftDragEnabled = "shiftDragEnabled"
    static let modifierScheme = "modifierScheme"
    static let wheelSize = "wheelSize"
    static let completionSound = "completionSound"
    static let revealInFinder = "revealInFinder"
    static let outputLocation = "outputLocation"
    static let customOutputFolder = "customOutputFolder"
    static let keepMetadata = "keepMetadata"
    static let keepFileDates = "keepFileDates"
    static let jpegQuality = "jpegQuality"
    static let heicQuality = "heicQuality"
    static let webpQuality = "webpQuality"
    static let avifQuality = "avifQuality"
    static let pdfDPI = "pdfDPI"
    static let videoCodec = "videoCodec"
    static let videoQuality = "videoQuality"
    static let hardwareEncoding = "hardwareEncoding"
    static let gifFPS = "gifFPS"
    static let gifMaxWidth = "gifMaxWidth"
    static let maxMediaJobs = "maxMediaJobs"
    static let ffmpegFolder = "ffmpegFolder"
    static let loginItemInitialized = "loginItemInitialized"
    static let onboardingDone = "onboardingDone"
    static let hiddenChips = "hiddenChips"
    static let autoUpdateCheck = "autoUpdateCheck"
    static let finderHotKey = "finderHotKey"
    static let notifyLongJobs = "notifyLongJobs"
    static let recentOutputs = "recentOutputs"
}

enum ModifierScheme: String, CaseIterable {
    /// Convert = ⇧, Tools = ⇧⌥
    case shift
    /// Convert = ⌃, Tools = ⌃⌥
    case control

    var convertFlags: NSEvent.ModifierFlags { self == .shift ? [.shift] : [.control] }
    var toolsFlags: NSEvent.ModifierFlags { self == .shift ? [.shift, .option] : [.control, .option] }
    var convertSymbol: String { self == .shift ? "⇧" : "⌃" }
    var toolsSymbol: String { self == .shift ? "⇧⌥" : "⌃⌥" }
}

enum WheelSize: String, CaseIterable {
    case small, medium, large
    var scale: CGFloat {
        switch self {
        case .small: return 0.86
        case .medium: return 1
        case .large: return 1.18
        }
    }
}

/// Typed access to settings. Reads are cheap and thread-safe (UserDefaults).
enum Preferences {
    static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            PrefKey.shiftDragEnabled: true,
            PrefKey.modifierScheme: ModifierScheme.shift.rawValue,
            PrefKey.wheelSize: WheelSize.medium.rawValue,
            PrefKey.completionSound: true,
            PrefKey.revealInFinder: false,
            PrefKey.outputLocation: "beside",
            PrefKey.keepMetadata: true,
            PrefKey.keepFileDates: false,
            PrefKey.jpegQuality: 85,
            PrefKey.heicQuality: 80,
            PrefKey.webpQuality: 80,
            PrefKey.avifQuality: 70,
            PrefKey.pdfDPI: 300,
            PrefKey.videoCodec: "h264",
            PrefKey.videoQuality: 65,
            PrefKey.hardwareEncoding: true,
            PrefKey.gifFPS: 15,
            PrefKey.gifMaxWidth: 720,
            PrefKey.maxMediaJobs: 1,
        ])
    }

    static var shiftDragEnabled: Bool {
        get { defaults.bool(forKey: PrefKey.shiftDragEnabled) }
        set { defaults.set(newValue, forKey: PrefKey.shiftDragEnabled) }
    }

    static var modifierScheme: ModifierScheme {
        ModifierScheme(rawValue: defaults.string(forKey: PrefKey.modifierScheme) ?? "") ?? .shift
    }

    static var wheelSize: WheelSize {
        WheelSize(rawValue: defaults.string(forKey: PrefKey.wheelSize) ?? "") ?? .medium
    }

    static var completionSound: Bool { defaults.bool(forKey: PrefKey.completionSound) }
    static var revealInFinder: Bool { defaults.bool(forKey: PrefKey.revealInFinder) }

    static var hiddenChips: Set<String> {
        Set(defaults.stringArray(forKey: PrefKey.hiddenChips) ?? [])
    }

    // MARK: Wheel customization (per kind of file and mode)

    static func wheelKey(_ base: String, kind: FileKind, mode: WheelMode) -> String {
        "\(base).\(mode.rawValue).\(kind.rawValue)"
    }

    /// Chips hidden for this kind of file (plus any hidden everywhere).
    static func hiddenChipKeys(kind: FileKind, mode: WheelMode) -> Set<String> {
        hiddenChips.union(defaults.stringArray(forKey: wheelKey(PrefKey.hiddenChips, kind: kind, mode: mode)) ?? [])
    }

    static func setHiddenChips(_ keys: Set<String>, kind: FileKind, mode: WheelMode) {
        defaults.set(keys.sorted(), forKey: wheelKey(PrefKey.hiddenChips, kind: kind, mode: mode))
    }

    static func chipOrder(kind: FileKind, mode: WheelMode) -> [String] {
        defaults.stringArray(forKey: wheelKey("chipOrder", kind: kind, mode: mode)) ?? []
    }

    static func setChipOrder(_ keys: [String], kind: FileKind, mode: WheelMode) {
        defaults.set(keys, forKey: wheelKey("chipOrder", kind: kind, mode: mode))
    }

    static func resetWheel() {
        defaults.removeObject(forKey: PrefKey.hiddenChips)
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(PrefKey.hiddenChips + ".") || key.hasPrefix("chipOrder.") {
            defaults.removeObject(forKey: key)
        }
    }

    static var onboardingDone: Bool {
        get { defaults.bool(forKey: PrefKey.onboardingDone) }
        set { defaults.set(newValue, forKey: PrefKey.onboardingDone) }
    }

    static var outputLocation: OutputLocation {
        switch defaults.string(forKey: PrefKey.outputLocation) {
        case "downloads": return .downloads
        case "custom":
            if let path = defaults.string(forKey: PrefKey.customOutputFolder), !path.isEmpty {
                return .folder(URL(fileURLWithPath: path, isDirectory: true))
            }
            return .besideOriginal
        default: return .besideOriginal
        }
    }

    static func conversionSettings() -> ConversionSettings {
        var s = ConversionSettings()
        let d = defaults
        s.jpegQuality = Double(clamp(d.integer(forKey: PrefKey.jpegQuality), 1, 100)) / 100
        s.heicQuality = Double(clamp(d.integer(forKey: PrefKey.heicQuality), 1, 100)) / 100
        s.webpQuality = clamp(d.integer(forKey: PrefKey.webpQuality), 1, 100)
        s.avifQuality = clamp(d.integer(forKey: PrefKey.avifQuality), 1, 100)
        s.keepMetadata = d.bool(forKey: PrefKey.keepMetadata)
        s.keepFileDates = d.bool(forKey: PrefKey.keepFileDates)
        s.pdfDPI = clamp(d.integer(forKey: PrefKey.pdfDPI), 72, 600)
        s.videoCodec = ConversionSettings.VideoCodec(rawValue: d.string(forKey: PrefKey.videoCodec) ?? "") ?? .h264
        s.videoQuality = clamp(d.integer(forKey: PrefKey.videoQuality), 1, 100)
        s.hardwareEncoding = d.bool(forKey: PrefKey.hardwareEncoding)
        s.gifFPS = clamp(d.integer(forKey: PrefKey.gifFPS), 1, 50)
        s.gifMaxWidth = clamp(d.integer(forKey: PrefKey.gifMaxWidth), 64, 3840)
        s.maxConcurrentMediaJobs = clamp(d.integer(forKey: PrefKey.maxMediaJobs), 1, 3)
        return s
    }

    static func outputPlanner() -> OutputPlanner {
        OutputPlanner(location: outputLocation)
    }

    /// Applies the ffmpeg override folder to the locator.
    static func applyFFmpegOverride() {
        if let path = defaults.string(forKey: PrefKey.ffmpegFolder), !path.isEmpty {
            FFmpegLocator.overrideDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            FFmpegLocator.overrideDirectory = nil
        }
    }

    // MARK: Recent outputs

    static var recentOutputs: [URL] {
        (defaults.stringArray(forKey: PrefKey.recentOutputs) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func addRecent(_ urls: [URL]) {
        var list = defaults.stringArray(forKey: PrefKey.recentOutputs) ?? []
        for url in urls {
            list.removeAll { $0 == url.path }
            list.insert(url.path, at: 0)
        }
        defaults.set(Array(list.prefix(10)), forKey: PrefKey.recentOutputs)
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
