#if canImport(PDFKit)
import AppKit
import Foundation
import PDFKit
#if canImport(Vision)
import Vision
#endif

/// PDF reading, rendering and text extraction (with OCR for scanned pages).
public enum PDFEngine {
    public static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw JobFailure("This PDF can't be opened. It may be damaged.")
        }
        if doc.isLocked {
            throw JobFailure("This PDF is password-protected.")
        }
        guard doc.pageCount > 0 else { throw JobFailure("This PDF has no pages.") }
        return doc
    }

    // MARK: Rendering

    /// Renders a page (crop box, rotation applied) on white at `dpi`.
    public static func render(_ page: PDFPage, dpi: CGFloat) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard w <= 30_000, h <= 30_000, w * h <= 300_000_000 else {
            throw JobFailure("This page is too large to render at \(Int(dpi)) dpi. Try a lower resolution in Settings.")
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw JobFailure("Not enough memory to render this page.")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        page.transform(ctx, for: .cropBox)
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { throw JobFailure("Couldn't render the page.") }
        return image
    }

    // MARK: Text

    /// Text of each page; pages without a text layer are read with OCR.
    public static func pageTexts(_ doc: PDFDocument, ocr: Bool = true,
                                 progress: (Double) -> Void = { _ in }) throws -> [String] {
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            try autoreleasepool {
                guard let page = doc.page(at: i) else { pages.append(""); return }
                var text = page.string ?? ""
                if ocr && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = try recognizeText(in: render(page, dpi: 200))
                }
                pages.append(text)
            }
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        return pages
    }

    /// Vision text recognition, lines in reading order.
    public static func recognizeText(in image: CGImage) throws -> String {
        #if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted {
            let a = $0.boundingBox, b = $1.boundingBox
            if abs(a.midY - b.midY) > min(a.height, b.height) * 0.5 { return a.midY > b.midY }
            return a.minX < b.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        #else
        return ""
        #endif
    }

    // MARK: PDF → DOCX

    /// A Word document with each page's text (keeping bold/italic/size),
    /// separated by page breaks. Scanned pages are OCR'd.
    public static func docx(from doc: PDFDocument, title: String?, progress: (Double) -> Void = { _ in }) throws -> Data {
        var document = DOCXDocument(title: title)
        for i in 0..<doc.pageCount {
            try autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                if i > 0 { document.blocks.append(.pageBreak) }
                let plain = page.string ?? ""
                if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let text = try recognizeText(in: render(page, dpi: 200))
                    for line in text.components(separatedBy: "\n") where !line.isEmpty {
                        document.blocks.append(.paragraph([.init(line)]))
                    }
                    return
                }
                if let attributed = page.attributedString {
                    document.blocks += paragraphs(from: attributed)
                } else {
                    for line in plain.components(separatedBy: "\n") {
                        document.blocks.append(.paragraph([.init(line)]))
                    }
                }
            }
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        return DOCXWriter.data(for: document)
    }

    /// Splits styled text into DOCX paragraphs with runs.
    static func paragraphs(from text: NSAttributedString) -> [DOCXDocument.Block] {
        var blocks: [DOCXDocument.Block] = []
        let ns = text.string as NSString
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            var runs: [DOCXDocument.Run] = []
            text.enumerateAttributes(in: range) { attrs, sub, _ in
                var s = ns.substring(with: sub)
                s = s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                guard !s.isEmpty else { return }
                var run = DOCXDocument.Run(s)
                if let font = attrs[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    run.bold = traits.contains(.bold)
                    run.italic = traits.contains(.italic)
                    run.fontSize = Double(font.pointSize.rounded())
                }
                if let color = attrs[.foregroundColor] as? NSColor, let rgb = color.usingColorSpace(.sRGB) {
                    let hex = String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                                     Int(rgb.blueComponent * 255))
                    if hex != "000000" { run.color = hex }
                }
                runs.append(run)
            }
            blocks.append(.paragraph(runs))
        }
        return blocks
    }
}
#endif
