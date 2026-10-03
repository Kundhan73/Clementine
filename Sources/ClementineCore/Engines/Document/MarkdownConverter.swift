#if canImport(AppKit)
import AppKit
import Foundation

/// Markdown ↔ styled text. Import uses Foundation's CommonMark parser and maps
/// its presentation intents to fonts and paragraph styles; export writes
/// headings, emphasis, links, lists and code.
public enum MarkdownConverter {
    static let base = DocumentEngine.bodyFontSize

    public static func attributedString(from markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true,
                                                              interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return DocumentEngine.plainAttributed(markdown)
        }
        let out = NSMutableAttributedString()
        var lastBlock: Int?
        var lastListItem: Int?
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let intent = run.presentationIntent
            let blockID = intent?.components.first?.identity ?? -1
            var heading = 0
            var isCode = false
            var isQuote = false
            var listDepth = 0
            var listItem: (ordinal: Int, ordered: Bool, id: Int)?
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level): heading = level
                case .codeBlock: isCode = true
                case .blockQuote: isQuote = true
                case .listItem(let ordinal):
                    if listItem == nil { listItem = (ordinal, false, component.identity) }
                case .orderedList:
                    listDepth += 1
                    if let item = listItem, !item.ordered { listItem = (item.ordinal, true, item.id) }
                case .unorderedList:
                    listDepth += 1
                default: break
                }
            }
            if let last = lastBlock, last != blockID {
                out.append(NSAttributedString(string: "\n"))
            }
            // Bullet or number at the start of each list item.
            if let item = listItem, item.id != lastListItem {
                let marker = item.ordered ? "\(item.ordinal).\t" : "•\t"
                out.append(NSAttributedString(string: marker, attributes: [.font: NSFont.systemFont(ofSize: base),
                                                                         .paragraphStyle: listStyle(depth: listDepth)]))
                lastListItem = item.id
            }
            lastBlock = blockID

            var font: NSFont
            if heading > 0 {
                let sizes: [CGFloat] = [22, 18, 15, 13.5, 12.5, 12]
                font = NSFont.boldSystemFont(ofSize: sizes[min(heading, 6) - 1])
            } else if isCode {
                font = NSFont.monospacedSystemFont(ofSize: base - 1, weight: .regular)
            } else {
                font = NSFont.systemFont(ofSize: base)
            }
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black]
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = adding(.bold, to: font) }
                if inline.contains(.emphasized) { font = adding(.italic, to: font) }
                if inline.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
                if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor(srgbRed: 0.1, green: 0.35, blue: 0.85, alpha: 1)
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attrs[.font] = font
            let style: NSMutableParagraphStyle
            if listItem != nil {
                style = listStyle(depth: listDepth)
            } else {
                style = NSMutableParagraphStyle()
                style.paragraphSpacing = heading > 0 ? 6 : 8
                style.paragraphSpacingBefore = heading > 0 ? 10 : 0
            }
            if isQuote {
                style.headIndent = 18
                style.firstLineHeadIndent = 18
                attrs[.foregroundColor] = NSColor.darkGray
            }
            if isCode {
                attrs[.backgroundColor] = NSColor(white: 0.95, alpha: 1)
            }
            attrs[.paragraphStyle] = style
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    static func adding(_ trait: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func listStyle(depth: Int) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        let indent = CGFloat(max(1, depth)) * 18
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.headIndent = indent
        style.firstLineHeadIndent = indent - 14
        style.paragraphSpacing = 3
        return style
    }

    // MARK: Export

    /// Markdown for styled text: headings from large bold paragraphs,
    /// **bold**, *italic*, `code`, [links](url) and "- " bullets.
    public static func markdown(from text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var lines: [String] = []
        var bodySize: CGFloat = base
        // The most common font size is the body size.
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let f = value as? NSFont { counts[f.pointSize.rounded(), default: 0] += range.length }
        }
        if let common = counts.max(by: { $0.value < $1.value })?.key { bodySize = common }

        var location = 0
        while location < ns.length {
            let paragraphRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraphRange)
            var body = NSRange(location: paragraphRange.location, length: paragraphRange.length)
            while body.length > 0, let scalar = UnicodeScalar(ns.character(at: NSMaxRange(body) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                body.length -= 1
            }
            if body.length == 0 {
                lines.append("")
                continue
            }
            let paragraph = text.attributedSubstring(from: body)
            var prefix = ""
            if let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.bold), font.pointSize >= bodySize * 1.25 {
                let ratio = font.pointSize / bodySize
                prefix = ratio >= 1.7 ? "# " : ratio >= 1.4 ? "## " : "### "
                lines.append(prefix + escape(paragraph.string))
                continue
            }
            var line = inlineMarkdown(paragraph)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for bullet in ["•\t", "• ", "◦\t", "▪\t", "–\t", "- "] where trimmed.hasPrefix(bullet) {
                line = "- " + trimmed.dropFirst(bullet.count)
                break
            }
            lines.append(line)
        }
        // Blank line between paragraphs, collapsed.
        var result: [String] = []
        for line in lines {
            if line.isEmpty {
                if result.last?.isEmpty == false { result.append("") }
            } else {
                if let last = result.last, !last.isEmpty, !(last.hasPrefix("- ") && line.hasPrefix("- ")) {
                    result.append("")
                }
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func inlineMarkdown(_ paragraph: NSAttributedString) -> String {
        var out = ""
        paragraph.enumerateAttributes(in: NSRange(location: 0, length: paragraph.length)) { attrs, range, _ in
            let raw = (paragraph.string as NSString).substring(with: range)
            guard !raw.isEmpty else { return }
            var piece = escape(raw)
            let font = attrs[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                if font?.isFixedPitch == true || traits.contains(.monoSpace) {
                    piece = piece.replacingOccurrences(of: trimmed, with: "`\(raw.trimmingCharacters(in: .whitespaces))`")
                } else {
                    if traits.contains(.bold) { piece = piece.replacingOccurrences(of: trimmed, with: "**\(trimmed)**") }
                    if traits.contains(.italic) { piece = piece.replacingOccurrences(of: trimmed, with: "*\(trimmed)*") }
                }
                if let link = attrs[.link] {
                    let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                    if !url.isEmpty { piece = "[\(piece)](\(url))" }
                }
            }
            out += piece
        }
        return out
    }

    /// Escapes characters that would otherwise turn into Markdown syntax.
    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\`*_[]#<>|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
#endif
