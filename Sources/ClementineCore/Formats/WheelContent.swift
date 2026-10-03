import Foundation

public enum WheelMode: String, Sendable {
    case convert, tools
}

/// One selectable item on the wheel.
public enum WheelChip: Hashable, Sendable {
    case format(Format)
    case tool(Tool)

    public var title: String {
        switch self {
        case .format(let f): return f.displayName
        case .tool(let t): return t.displayName
        }
    }

    public var caption: String {
        switch self {
        case .format(let f): return f.caption
        case .tool(let t): return t.caption
        }
    }

    /// Stable key for settings ("format.jpg", "tool.crop").
    public var key: String {
        switch self {
        case .format(let f): return "format.\(f.rawValue)"
        case .tool(let t): return "tool.\(t.rawValue)"
        }
    }
}

/// Computes which chips the wheel shows for a set of dragged files.
public enum WheelContent {
    public static let toolOrder: [FileKind: [Tool]] = [
        .image: [.compress, .resize, .crop, .rotate, .adjust, .annotate, .redact, .background,
                 .removeMetadata, .readQR, .createPDF, .metadata],
        .video: [.compress, .trim, .crop, .extractAudio, .mute, .resize, .rotate, .speed, .split,
                 .snapshot, .redact, .normalize, .bleep, .removeMetadata, .metadata],
        .audio: [.compress, .trim, .normalize, .speed, .split, .channels, .bleep, .visualizer,
                 .removeMetadata, .metadata],
        .pdf: [.compress, .split, .organizePDF, .rotate, .readQR, .removeMetadata, .metadata],
        .document: [.metadata],
    ]
    /// Tools that take several files; shown first when several are dragged.
    public static let multiInputTools: [Tool] = [.collage, .createPDF, .mergePDF, .join]

    /// - Parameters:
    ///   - isAvailable: filters out chips whose engine isn't available (or
    ///     that the user hid in Settings).
    public static func chips(for items: [InputItem], mode: WheelMode,
                             isAvailable: (WheelChip) -> Bool = { _ in true }) -> [WheelChip] {
        guard let first = items.first else { return [] }
        switch mode {
        case .convert:
            return convertTargets(for: items).map(WheelChip.format).filter(isAvailable)
        case .tools:
            var tools: [Tool] = []
            if items.count > 1 { tools += multiInputTools }
            tools += toolOrder[first.kind] ?? []
            for t in Tool.allCases where !tools.contains(t) { tools.append(t) }
            return tools.filter { $0.accepts(items) }.map(WheelChip.tool).filter(isAvailable)
        }
    }

    /// Applies the user's preferred order (chip keys, from Settings → Wheel):
    /// listed chips first in that order, the rest after in their usual order.
    public static func applyingOrder(_ chips: [WheelChip], order: [String]) -> [WheelChip] {
        guard !order.isEmpty else { return chips }
        var rank: [String: Int] = [:]
        for (i, key) in order.enumerated() where rank[key] == nil { rank[key] = i }
        return chips.enumerated().sorted { a, b in
            let ra = rank[a.element.key] ?? Int.max, rb = rank[b.element.key] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Chips a category can show, for Settings → Wheel (every target or tool
    /// for that kind of file, in the default order).
    public static func catalogue(for kind: FileKind, mode: WheelMode) -> [WheelChip] {
        switch mode {
        case .convert:
            let samples: [FileKind: [String]] = [
                .image: ["png", "jpg", "heic", "webp", "gif", "svg"],
                .audio: ["wav", "mp3", "m4a", "flac"],
                .video: ["mov", "mp4", "mkv", "gif"],
                .pdf: ["pdf"],
                .document: ["docx", "txt", "rtf", "md"],
                .subtitle: ["srt", "vtt"],
                .archive: ["zip", "rar", "tgz"],
                .folder: ["Folder"],
            ]
            var seen: [Format] = []
            for name in samples[kind] ?? [] {
                let item = InputItem(url: URL(fileURLWithPath: "/tmp/sample.\(name)"), isDirectory: name == "Folder")
                guard item.kind == kind || kind == .folder else { continue }
                for f in ConversionMatrix.allTargets(for: item) where !seen.contains(f) { seen.append(f) }
            }
            // The kind's usual targets first, in their usual order.
            let usual = peerTargets(for: kind)
            let ranked = seen.enumerated().sorted { a, b in
                let ra = usual.firstIndex(of: a.element) ?? Int.max, rb = usual.firstIndex(of: b.element) ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            return ranked.map { WheelChip.format($0.element) }
        case .tools:
            var tools = toolOrder[kind] ?? []
            for t in multiInputTools where t.kinds.contains(kind) && !tools.contains(t) { tools.append(t) }
            return tools.map(WheelChip.tool)
        }
    }

    /// Targets valid for every item. A file that is already in a target
    /// format is skipped for that target rather than ruling the target out,
    /// so dragging a JPG and a PNG still offers "JPG" (converts the PNG).
    public static func convertTargets(for items: [InputItem]) -> [Format] {
        guard let first = items.first else { return [] }
        var ordered = ConversionMatrix.allTargets(for: first)
        if items.count > 1, let f = first.format, isPeerTarget(f, of: first) {
            let peers = peerTargets(for: first.kind)
            ordered = peers + ordered.filter { !peers.contains($0) }
        }
        let sets = items.map { item -> Set<Format> in
            var s = Set(ConversionMatrix.allTargets(for: item))
            if let f = item.format, isPeerTarget(f, of: item) { s.insert(f) }
            return s
        }
        let common = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }
        return ordered.filter { target in
            common.contains(target) && !items.allSatisfy { $0.format == target }
        }
    }

    /// Whether `format` is a target for other files of the same kind
    /// (e.g. JPG for images), so a mixed selection can use it.
    private static func isPeerTarget(_ format: Format, of item: InputItem) -> Bool {
        peerTargets(for: item.kind).contains(format)
    }

    private static func peerTargets(for kind: FileKind) -> [Format] {
        switch kind {
        case .image: return ConversionMatrix.imageTargets
        case .audio: return ConversionMatrix.audioTargets
        case .video: return ConversionMatrix.videoTargets
        case .document: return ConversionMatrix.richDocumentTargets
        default: return []
        }
    }
}
