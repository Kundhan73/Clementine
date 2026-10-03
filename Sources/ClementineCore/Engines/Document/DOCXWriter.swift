import Foundation

/// A simple word-processing document: styled paragraphs, images and page
/// breaks. Written as Office Open XML (.docx) by `DOCXWriter`.
public struct DOCXDocument: Sendable {
    public struct Run: Sendable, Equatable {
        public var text: String
        public var bold = false
        public var italic = false
        public var underline = false
        /// Points; nil = document default (11 pt).
        public var fontSize: Double?
        /// "RRGGBB"
        public var color: String?
        public var fontName: String?

        public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                    fontSize: Double? = nil, color: String? = nil, fontName: String? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.fontSize = fontSize
            self.color = color
            self.fontName = fontName
        }
    }

    public enum Alignment: String, Sendable { case left, center, right, both }

    public enum Block: Sendable {
        /// heading: 0 = body text, 1…3 = heading levels.
        case paragraph([Run], heading: Int = 0, alignment: Alignment = .left)
        /// An inline picture, `format` "png" or "jpeg", size in points.
        case image(Data, format: String, width: Double, height: Double)
        case pageBreak
    }

    public enum PageSize: Sendable {
        case a4, letter
        /// Width and height in points.
        public var points: (Double, Double) { self == .a4 ? (595.3, 841.9) : (612, 792) }
        /// Letter in the US and Canada, A4 elsewhere.
        public static var forCurrentRegion: PageSize {
            let region = Locale.current.region?.identifier ?? ""
            return ["US", "CA", "MX", "PH"].contains(region) ? .letter : .a4
        }
    }

    public var blocks: [Block]
    public var title: String?
    public var pageSize: PageSize
    /// Page margins in points.
    public var margin: Double

    public init(blocks: [Block] = [], title: String? = nil, pageSize: PageSize = .forCurrentRegion, margin: Double = 72) {
        self.blocks = blocks
        self.title = title
        self.pageSize = pageSize
        self.margin = margin
    }

    /// Usable width/height inside the margins, in points.
    public var contentSize: (width: Double, height: Double) {
        let (w, h) = pageSize.points
        return (w - 2 * margin, h - 2 * margin)
    }

    /// Image size in points fitted inside the content area, keeping aspect.
    public func fittedImageSize(width: Double, height: Double) -> (Double, Double) {
        let (cw, ch) = contentSize
        guard width > 0, height > 0 else { return (cw, ch) }
        let scale = min(1, cw / width, (ch - 2) / height)
        return (width * scale, height * scale)
    }
}

public enum DOCXWriter {
    private static let ns = """
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
    """

    public static func data(for doc: DOCXDocument, date: Date = Date()) -> Data {
        var zip = ZipWriter(date: date)
        var media: [(name: String, data: Data)] = []
        var body = ""
        for block in doc.blocks {
            switch block {
            case let .paragraph(runs, heading, alignment):
                body += paragraph(runs, heading: heading, alignment: alignment)
            case let .image(data, format, width, height):
                let index = media.count + 1
                let ext = format == "jpeg" || format == "jpg" ? "jpeg" : "png"
                media.append(("image\(index).\(ext)", data))
                body += imageParagraph(rId: "rIdImg\(index)", index: index, name: "image\(index).\(ext)",
                                       width: width, height: height)
            case .pageBreak:
                body += #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#
            }
        }
        if body.isEmpty { body = "<w:p/>" }
        let (pw, ph) = doc.pageSize.points
        let twips = { (pt: Double) in Int((pt * 20).rounded()) }
        let m = twips(doc.margin)
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(ns)><w:body>\(body)<w:sectPr><w:pgSz w:w="\(twips(pw))" w:h="\(twips(ph))"/>\
        <w:pgMar w:top="\(m)" w:right="\(m)" w:bottom="\(m)" w:left="\(m)" w:header="708" w:footer="708" w:gutter="0"/>\
        </w:sectPr></w:body></w:document>
        """

        var rels = #"<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        for (i, item) in media.enumerated() {
            rels += #"<Relationship Id="rIdImg\#(i + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\#(item.name)"/>"#
        }

        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", packageRels)
        zip.add("docProps/core.xml", coreProperties(title: doc.title, date: date))
        zip.add("docProps/app.xml", appProperties)
        zip.add("word/document.xml", document)
        zip.add("word/styles.xml", styles)
        zip.add("word/_rels/document.xml.rels", relationships(rels))
        for item in media { zip.add("word/media/\(item.name)", item.data, method: .stored) }
        return zip.finish()
    }

    // MARK: Parts

    static func paragraph(_ runs: [DOCXDocument.Run], heading: Int, alignment: DOCXDocument.Alignment) -> String {
        var ppr = ""
        if heading > 0 { ppr += #"<w:pStyle w:val="Heading\#(min(heading, 3))"/>"# }
        if alignment != .left { ppr += #"<w:jc w:val="\#(alignment.rawValue)"/>"# }
        var xml = "<w:p>" + (ppr.isEmpty ? "" : "<w:pPr>\(ppr)</w:pPr>")
        for run in runs where !run.text.isEmpty { xml += self.run(run) }
        return xml + "</w:p>"
    }

    static func run(_ run: DOCXDocument.Run) -> String {
        var rpr = ""
        if let font = run.fontName {
            let f = escape(font)
            rpr += #"<w:rFonts w:ascii="\#(f)" w:hAnsi="\#(f)" w:cs="\#(f)"/>"#
        }
        if run.bold { rpr += "<w:b/>" }
        if run.italic { rpr += "<w:i/>" }
        if run.underline { rpr += #"<w:u w:val="single"/>"# }
        if let color = run.color { rpr += #"<w:color w:val="\#(color)"/>"# }
        if let size = run.fontSize {
            let half = Int((size * 2).rounded())
            rpr += #"<w:sz w:val="\#(half)"/><w:szCs w:val="\#(half)"/>"#
        }
        var xml = "<w:r>" + (rpr.isEmpty ? "" : "<w:rPr>\(rpr)</w:rPr>")
        // Line breaks and tabs become their own elements.
        var first = true
        for line in run.text.components(separatedBy: "\n") {
            if !first { xml += "<w:br/>" }
            first = false
            let parts = line.components(separatedBy: "\t")
            for (i, part) in parts.enumerated() {
                if i > 0 { xml += "<w:tab/>" }
                if !part.isEmpty { xml += #"<w:t xml:space="preserve">\#(escape(part))</w:t>"# }
            }
        }
        return xml + "</w:r>"
    }

    static func imageParagraph(rId: String, index: Int, name: String, width: Double, height: Double) -> String {
        let cx = Int((width * 12_700).rounded()), cy = Int((height * 12_700).rounded())
        return """
        <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
        <wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(index)" name="Picture \(index)"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
        <pic:nvPicPr><pic:cNvPr id="\(index)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(rId)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>\
        </wp:inline></w:drawing></w:r></w:p>
        """
    }

    /// XML-escapes text and drops characters XML 1.0 forbids.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                let v = scalar.value
                if v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000 {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Default Extension="png" ContentType="image/png"/>\
    <Default Extension="jpeg" ContentType="image/jpeg"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
    </Types>
    """

    private static let packageRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
    </Relationships>
    """

    private static func relationships(_ inner: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(inner)</Relationships>
        """
    }

    private static func coreProperties(title: String?, date: Date) -> String {
        let iso = ISO8601DateFormatter().string(from: date)
        let titleXML = title.map { "<dc:title>\(escape($0))</dc:title>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\(titleXML)<dc:creator>Clementine</dc:creator>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(iso)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(iso)</dcterms:modified></cp:coreProperties>
        """
    }

    private static let appProperties = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Clementine</Application></Properties>
    """

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/>\
    <w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>\
    </w:styles>
    """
}
