import Foundation

/// The ⇧⌥ wheel's tools. Raw values are stable (settings, tests).
public enum Tool: String, CaseIterable, Codable, Sendable {
    case compress, resize, rotate, crop, adjust, annotate, redact, background, collage
    case createPDF, readQR, metadata, removeMetadata
    case trim, speed, split, join, mergePDF, organizePDF, snapshot, mute, extractAudio
    case normalize, channels, bleep, visualizer

    public enum Interaction: Sendable {
        /// Runs immediately with defaults.
        case instant
        /// Small panel with a few options.
        case dialog
        /// Full editor window with a live preview.
        case editor
    }

    public var displayName: String {
        switch self {
        case .compress: return "Compress"
        case .resize: return "Resize"
        case .rotate: return "Rotate"
        case .crop: return "Crop"
        case .adjust: return "Adjust"
        case .annotate: return "Annotate"
        case .redact: return "Redact"
        case .background: return "Background"
        case .collage: return "Collage"
        case .createPDF: return "Create PDF"
        case .readQR: return "Read QR"
        case .metadata: return "Metadata"
        case .removeMetadata: return "Remove Metadata"
        case .trim: return "Trim"
        case .speed: return "Speed"
        case .split: return "Split"
        case .join: return "Join"
        case .mergePDF: return "Merge PDF"
        case .organizePDF: return "Organize"
        case .snapshot: return "Snapshot"
        case .mute: return "Mute"
        case .extractAudio: return "Extract Audio"
        case .normalize: return "Normalize"
        case .channels: return "Channels"
        case .bleep: return "Bleep"
        case .visualizer: return "Visualizer"
        }
    }

    /// Longer description shown under the hub while hovered.
    public var caption: String {
        switch self {
        case .compress: return "Compress · pick a size"
        case .resize: return "Resize"
        case .rotate: return "Rotate or flip"
        case .crop: return "Crop"
        case .adjust: return "Adjust colours"
        case .annotate: return "Draw and add text"
        case .redact: return "Hide faces, text, areas"
        case .background: return "Frame and background"
        case .collage: return "Make a collage"
        case .createPDF: return "Combine into a PDF"
        case .readQR: return "Read QR / barcode"
        case .metadata: return "Inspect metadata"
        case .removeMetadata: return "Remove metadata"
        case .trim: return "Trim"
        case .speed: return "Change speed"
        case .split: return "Split into parts"
        case .join: return "Join into one"
        case .mergePDF: return "Merge PDFs"
        case .organizePDF: return "Reorder pages"
        case .snapshot: return "Save a frame"
        case .mute: return "Remove audio"
        case .extractAudio: return "Extract audio"
        case .normalize: return "Even out loudness"
        case .channels: return "Mono, stereo, swap"
        case .bleep: return "Bleep words"
        case .visualizer: return "Audio to video"
        }
    }

    /// SF Symbol shown on the chip.
    public var symbolName: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .resize: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .rotate: return "rotate.right"
        case .crop: return "crop"
        case .adjust: return "slider.horizontal.3"
        case .annotate: return "pencil.tip.crop.circle"
        case .redact: return "eye.slash"
        case .background: return "photo.artframe"
        case .collage: return "square.grid.2x2"
        case .createPDF: return "doc.richtext"
        case .readQR: return "qrcode.viewfinder"
        case .metadata: return "info.circle"
        case .removeMetadata: return "eraser"
        case .trim: return "timeline.selection"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .split: return "scissors"
        case .join: return "link"
        case .mergePDF: return "doc.on.doc"
        case .organizePDF: return "square.grid.3x3.square"
        case .snapshot: return "camera"
        case .mute: return "speaker.slash"
        case .extractAudio: return "waveform"
        case .normalize: return "dial.medium"
        case .channels: return "speaker.wave.2"
        case .bleep: return "exclamationmark.bubble"
        case .visualizer: return "waveform.path.ecg.rectangle"
        }
    }

    public var interaction: Interaction {
        switch self {
        case .readQR, .removeMetadata, .mergePDF, .mute:
            return .instant
        case .compress, .resize, .rotate, .createPDF, .speed, .split, .join, .extractAudio,
             .normalize, .channels, .visualizer:
            return .dialog
        case .crop, .adjust, .annotate, .redact, .background, .collage, .metadata, .trim,
             .organizePDF, .snapshot, .bleep:
            return .editor
        }
    }

    /// File kinds the tool accepts (every dragged file must be one of these).
    public var kinds: Set<FileKind> {
        switch self {
        case .compress: return [.image, .video, .audio, .pdf]
        case .resize: return [.image, .video]
        case .rotate: return [.image, .video, .pdf]
        case .crop: return [.image, .video]
        case .adjust, .annotate, .background: return [.image]
        case .redact: return [.image, .video]
        case .collage: return [.image]
        case .createPDF: return [.image, .pdf]
        case .readQR: return [.image, .pdf]
        case .metadata: return [.image, .audio, .video, .pdf, .document]
        case .removeMetadata: return [.image, .audio, .video, .pdf]
        case .trim, .speed, .split: return self == .split ? [.video, .audio, .pdf] : [.video, .audio]
        case .join: return [.video, .audio]
        case .mergePDF: return [.pdf, .image]
        case .organizePDF: return [.pdf]
        case .snapshot, .mute, .extractAudio: return [.video]
        case .normalize, .bleep: return [.audio, .video]
        case .channels, .visualizer: return [.audio]
        }
    }

    /// Minimum and maximum number of dragged files the tool takes.
    public var inputRange: ClosedRange<Int> {
        switch self {
        case .collage: return 2...36
        case .join: return 2...50
        case .mergePDF: return 2...500
        case .createPDF: return 1...500
        case .crop, .adjust, .annotate, .redact, .background, .metadata, .trim, .organizePDF,
             .snapshot, .bleep, .split, .visualizer:
            return 1...1
        default: return 1...500
        }
    }

    /// Extra constraints beyond `kinds`: Create PDF needs at least one image,
    /// Merge needs at least one PDF, Join needs all files of one kind.
    public func accepts(_ items: [InputItem]) -> Bool {
        guard inputRange.contains(items.count), items.allSatisfy({ kinds.contains($0.kind) }) else { return false }
        switch self {
        case .createPDF: return items.contains { $0.kind == .image }
        case .mergePDF: return items.contains { $0.kind == .pdf }
        case .join: return Set(items.map(\.kind)).count == 1
        case .split: return true
        default: return true
        }
    }

    /// Suffix added to output names: "video (trimmed).mp4".
    public var outputSuffix: String? {
        switch self {
        case .compress: return "compressed"
        case .resize: return "resized"
        case .rotate: return "rotated"
        case .crop: return "cropped"
        case .adjust: return "adjusted"
        case .annotate: return "annotated"
        case .redact: return "redacted"
        case .background: return "framed"
        case .removeMetadata: return "no metadata"
        case .trim: return "trimmed"
        case .split: return "split"
        case .organizePDF: return "organized"
        case .mute: return "muted"
        case .normalize: return "normalized"
        case .bleep: return "bleeped"
        case .channels: return "channels"
        case .visualizer: return "visualizer"
        case .speed, .collage, .createPDF, .readQR, .metadata, .join, .mergePDF, .snapshot, .extractAudio:
            return nil
        }
    }
}
