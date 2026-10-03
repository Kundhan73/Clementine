#if canImport(AppKit)
import AppKit
import Foundation

/// Text and rich documents: TXT, RTF, RTFD, DOC, DOCX, ODT, HTML, Markdown
/// in; PDF, DOCX, TXT, RTF, HTML, ODT, Markdown and page images out. No
/// macros or scripts run; remote resources in HTML aren't loaded.
public enum DocumentEngine {
    public static let bodyFontSize: CGFloat = 12

    // MARK: Reading

    /// Loads any supported document as attributed text.
    public static func read(_ url: URL, format: Format) async throws -> NSAttributedString {
        switch format {
        case .txt:
            return plainAttributed(try TextDecoding.read(url))
        case .md:
            return MarkdownConverter.attributedString(from: try TextDecoding.read(url))
        case .html:
            let html = stripRemoteResources(try TextDecoding.read(url))
            // The HTML importer uses WebKit and must run on the main thread.
            let imported = try await MainActor.run {
                Unchecked(try NSAttributedString(data: Data(html.utf8),
                                                 options: [.documentType: NSAttributedString.DocumentType.html,
                                                           .characterEncoding: String.Encoding.utf8.rawValue],
                                                 documentAttributes: nil))
            }
            return imported.value
        case .rtf, .rtfd, .doc, .docx, .odt:
            let type: NSAttributedString.DocumentType
            switch format {
            case .rtf: type = .rtf
            case .rtfd: type = .rtfd
            case .doc: type = .docFormat
            case .docx: type = .officeOpenXML
            default: type = .openDocument
            }
            do {
                return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
            } catch {
                throw JobFailure("This document can't be opened. It may be damaged or password-protected.",
                                 details: error.localizedDescription)
            }
        default:
            throw JobFailure("\(format.displayName) documents can't be read.")
        }
    }

    /// Plain text in a readable font; monospaced when it looks like code or a table.
    public static func plainAttributed(_ text: String) -> NSAttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let structured = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") || $0.contains("\t") }.count
        let mono = lines.count >= 4 && Double(structured) / Double(lines.count) > 0.2
        let font = mono ? NSFont.monospacedSystemFont(ofSize: bodyFontSize - 1, weight: .regular)
                        : NSFont.systemFont(ofSize: bodyFontSize)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = mono ? 1 : 2
        style.paragraphSpacing = mono ? 0 : 4
        return NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style,
                                                             .foregroundColor: NSColor.black])
    }

    /// Neutralises remote URLs so the importer never fetches anything.
    static func stripRemoteResources(_ html: String) -> String {
        var out = html
        for pattern in [#"(?i)(src|href|background|poster)\s*=\s*(["'])\s*(https?:|//|ftp:)"#,
                        #"(?i)url\(\s*(["']?)\s*(https?:|//)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range,
                                                 withTemplate: pattern.contains("url") ? "url($1about:blank#" : "$1=$2about:blank#")
        }
        return out
    }

    // MARK: Writing

    public static func write(_ text: NSAttributedString, as target: Format, to url: URL, title: String?) throws {
        let range = NSRange(location: 0, length: text.length)
        func data(_ type: NSAttributedString.DocumentType) throws -> Data {
            var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if let title { attrs[.title] = title }
            return try text.data(from: range, documentAttributes: attrs)
        }
        switch target {
        case .pdf:
            try TextPaginator.writePDF(text, to: url, title: title)
        case .docx:
            try data(.officeOpenXML).write(to: url)
        case .odt:
            try data(.openDocument).write(to: url)
        case .rtf:
            try data(.rtf).write(to: url)
        case .html:
            try data(.html).write(to: url)
        case .txt:
            try Data(text.string.utf8).write(to: url)
        case .md:
            try Data(MarkdownConverter.markdown(from: text).utf8).write(to: url)
        default:
            throw JobFailure("Documents can't be saved as \(target.displayName).")
        }
    }
}

/// Carries a non-Sendable value across an actor hop we control.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Lays attributed text out on pages with TextKit and draws them into a PDF
/// or into images. Safe off the main thread (objects are private to the call).
public enum TextPaginator {
    public static var pageSize: CGSize {
        DOCXDocument.PageSize.forCurrentRegion == .letter ? CGSize(width: 612, height: 792)
                                                          : CGSize(width: 595.28, height: 841.89)
    }
    public static let margin: CGFloat = 54

    /// Text containers, one per page.
    static func layout(_ text: NSAttributedString, pageSize: CGSize, margin: CGFloat)
        -> (NSTextStorage, NSLayoutManager, [NSTextContainer]) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = false
        storage.addLayoutManager(manager)
        var containers: [NSTextContainer] = []
        let size = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)
        while containers.count < 20_000 {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            containers.append(container)
            let range = manager.glyphRange(for: container)
            if NSMaxRange(range) >= manager.numberOfGlyphs || range.length == 0 { break }
        }
        return (storage, manager, containers)
    }

    public static func pageCount(_ text: NSAttributedString) -> Int {
        layout(text, pageSize: pageSize, margin: margin).2.count
    }

    public static func writePDF(_ text: NSAttributedString, to url: URL, title: String? = nil) throws {
        let size = pageSize
        let (storage, manager, containers) = layout(text, pageSize: size, margin: margin)
        var box = CGRect(origin: .zero, size: size)
        var info: [CFString: Any] = [kCGPDFContextCreator: "Clementine"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw JobFailure("Couldn't create the PDF.")
        }
        for container in containers {
            ctx.beginPDFPage(nil)
            draw(manager, container, in: ctx, pageSize: size)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        withExtendedLifetime(storage) {}
    }

    /// Renders every page to an image at `dpi`.
    public static func renderPages(_ text: NSAttributedString, dpi: Int,
                                   page: (Int, Int, CGImage) throws -> Void) throws {
        let size = pageSize
        let (storage, manager, containers) = layout(text, pageSize: size, margin: margin)
        let scale = CGFloat(dpi) / 72
        for (i, container) in containers.enumerated() {
            try autoreleasepool {
                let w = Int(size.width * scale), h = Int(size.height * scale)
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                    throw JobFailure("Not enough memory to render the page.")
                }
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.scaleBy(x: scale, y: scale)
                draw(manager, container, in: ctx, pageSize: size)
                guard let image = ctx.makeImage() else { throw JobFailure("Couldn't render the page.") }
                try page(i, containers.count, image)
            }
        }
        withExtendedLifetime(storage) {}
    }

    private static func draw(_ manager: NSLayoutManager, _ container: NSTextContainer, in ctx: CGContext, pageSize: CGSize) {
        ctx.saveGState()
        // TextKit draws in flipped (y-down) coordinates.
        ctx.translateBy(x: 0, y: pageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let range = manager.glyphRange(for: container)
        let origin = CGPoint(x: margin, y: margin)
        manager.drawBackground(forGlyphRange: range, at: origin)
        manager.drawGlyphs(forGlyphRange: range, at: origin)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}
#endif
