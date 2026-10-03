import Foundation

/// Decodes text files: BOM-aware UTF-8/UTF-16, falling back to Windows-1252
/// and Latin-1; normalises line endings to "\n".
public enum TextDecoding {
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(4))
        var text: String?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if looksLikeUTF16(data) {
            text = String(data: data, encoding: .utf16LittleEndian)
        }
        if text == nil { text = String(data: data, encoding: .utf8) }
        if text == nil { text = String(data: data, encoding: .windowsCP1252) }
        if text == nil { text = String(data: data, encoding: .isoLatin1) }
        let s = text ?? String(decoding: data, as: UTF8.self)
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// BOM-less UTF-16LE: lots of zero bytes in odd positions.
    private static func looksLikeUTF16(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let sample = data.prefix(512)
        var zerosOdd = 0, zerosEven = 0
        for (i, b) in sample.enumerated() where b == 0 { if i % 2 == 1 { zerosOdd += 1 } else { zerosEven += 1 } }
        return zerosOdd > sample.count / 4 && zerosEven < sample.count / 20
    }

    public static func read(_ url: URL) throws -> String {
        decode(try Data(contentsOf: url))
    }
}

public struct SubtitleCue: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// SRT / WebVTT / ASS parsing and SRT / VTT / TXT writing.
public enum Subtitles {
    // MARK: Parsing

    public static func parse(_ text: String, format: Format) -> [SubtitleCue] {
        switch format {
        case .vtt: return parseVTT(text)
        case .ass: return parseASS(text)
        default: return parseSRT(text)
        }
    }

    public static func parseSRT(_ text: String) -> [SubtitleCue] {
        parseBlocks(text, isVTT: false)
    }

    public static func parseVTT(_ text: String) -> [SubtitleCue] {
        parseBlocks(text, isVTT: true)
    }

    private static func parseBlocks(_ raw: String, isVTT: Bool) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            if isVTT, let first = lines.first, first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") {
                continue
            }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTime(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = parseTime(parts[1].trimmingCharacters(in: .whitespaces)
                                        .split(separator: " ").first.map(String.init) ?? "") else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: max(end, start), text: body))
        }
        return cues
    }

    /// "01:02:03,456", "01:02:03.456", "02:03.456" (VTT), "0:01:02.34" (ASS).
    public static func parseTime(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0 else { return nil }
            if i < parts.count - 1 && p.contains(".") { return nil }
            seconds = seconds * 60 + v
        }
        return seconds
    }

    public static func parseASS(_ raw: String) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var inEvents = false
        var fields: [String] = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var cues: [SubtitleCue] = []
        for line in text.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inEvents = trimmed.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if trimmed.lowercased().hasPrefix("format:") {
                fields = trimmed.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard trimmed.lowercased().hasPrefix("dialogue:") else { continue }
            let values = trimmed.dropFirst(9).split(separator: ",", maxSplits: max(0, fields.count - 1),
                                                    omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard values.count == fields.count,
                  let si = fields.firstIndex(of: "start"), let ei = fields.firstIndex(of: "end"),
                  let ti = fields.firstIndex(of: "text"),
                  let start = parseTime(values[si]), let end = parseTime(values[ei]) else { continue }
            let body = cleanASSText(values[ti])
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func cleanASSText(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        // Drop override blocks like {\i1}.
        while let open = out.range(of: "{"), let close = out.range(of: "}", range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Writing

    public static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { i, cue in
            "\(i + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(srtText(cue.text))\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(vttText(cue.text))\n"
        }.joined(separator: "\n")
    }

    /// One cue per line, tags removed.
    public static func plainText(_ cues: [SubtitleCue]) -> String {
        cues.map { stripTags($0.text).replacingOccurrences(of: "\n", with: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n") + "\n"
    }

    public static func timestamp(_ seconds: Double, separator: String) -> String {
        let totalMs = Int((max(0, seconds) * 1000).rounded())
        let h = totalMs / 3_600_000, m = (totalMs / 60_000) % 60, s = (totalMs / 1000) % 60, ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }

    /// Removes markup: <b>, <i>, <c.x>, <v Name>, timestamps, {\…} blocks.
    public static func stripTags(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s {
            if ch == "<" { depth += 1; continue }
            if ch == ">" && depth > 0 { depth -= 1; continue }
            if depth == 0 { out.append(ch) }
        }
        return cleanASSText(decodeEntities(out))
    }

    /// SRT keeps <b>, <i>, <u>, <font>; other (VTT-only) tags are removed.
    static func srtText(_ s: String) -> String {
        let allowed = ["b", "i", "u", "font"]
        var out = ""
        var tag = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; tag = ""; continue }
            if inTag {
                if ch == ">" {
                    inTag = false
                    let name = tag.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).split(separator: " ").first
                        .map { String($0).lowercased() } ?? ""
                    if allowed.contains(name) { out += "<\(tag)>" }
                } else {
                    tag.append(ch)
                }
                continue
            }
            out.append(ch)
        }
        return decodeEntities(out)
    }

    /// VTT needs "-->" and lone "&"/"<" escaped.
    static func vttText(_ s: String) -> String {
        s.replacingOccurrences(of: "-->", with: "->")
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Text → cues

    /// One cue per paragraph (or per line when there are no blank lines),
    /// timed at ~15 characters per second, 1.5–7 s each, 0.1 s apart.
    public static func cues(fromPlainText text: String, charactersPerSecond: Double = 15) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasParagraphs = normalized.contains("\n\n")
        let chunks = (hasParagraphs ? normalized.components(separatedBy: "\n\n") : normalized.components(separatedBy: "\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var t = 0.0
        return chunks.map { chunk in
            let duration = min(7, max(1.5, Double(chunk.count) / charactersPerSecond))
            let cue = SubtitleCue(start: t, end: t + duration, text: chunk)
            t += duration + 0.1
            return cue
        }
    }

    // MARK: Conversion

    /// Converts subtitle/text data to `target` (.srt, .vtt or .txt).
    public static func convert(_ data: Data, from source: Format, to target: Format) throws -> String {
        let text = TextDecoding.decode(data)
        let cues = source == .txt ? cues(fromPlainText: text) : parse(text, format: source)
        guard !cues.isEmpty else {
            throw JobFailure(source == .txt ? "This text file is empty." : "No subtitles were found in this file.")
        }
        switch target {
        case .srt: return srt(cues)
        case .vtt: return vtt(cues)
        case .txt: return plainText(cues)
        default: throw JobFailure("Subtitles can't be saved as \(target.displayName).")
        }
    }
}
