#if canImport(ImageIO) && canImport(PDFKit)
import AppKit
import Foundation
import ImageIO
import PDFKit

/// One row in the metadata inspector.
public struct MetadataEntry: Identifiable, Hashable, Sendable {
    public var id: String { group + "\u{1}" + key }
    public var group: String
    public var key: String
    public var value: String

    public init(group: String, key: String, value: String) {
        self.group = group
        self.key = key
        self.value = value
    }
}


/// Reads metadata of any supported file and writes edited copies.
public enum MetadataInspector {
    public static func read(_ item: InputItem) async -> [MetadataEntry] {
        var rows = fileRows(item.url)
        switch item.kind {
        case .image: rows += imageRows(item.url)
        case .audio, .video: rows += await mediaRows(item.url)
        case .pdf: rows += pdfRows(item.url)
        case .document: rows += documentRows(item.url, format: item.format)
        default: break
        }
        return rows
    }

    /// Current values of the editable fields.
    public static func editable(_ item: InputItem, from rows: [MetadataEntry]) -> EditableMetadata {
        func value(_ keys: [String]) -> String {
            rows.first { keys.contains($0.key.lowercased()) }?.value ?? ""
        }
        var e = EditableMetadata()
        e.title = value(["title", "objectname", "imagedescription"])
        e.author = value(["author", "artist", "byline"])
        e.comment = value(["comment", "subject", "caption/abstract", "usercomment"])
        e.copyright = value(["copyright", "copyrightnotice"])
        return e
    }

    // MARK: Reading

    static func fileRows(_ url: URL) -> [MetadataEntry] {
        var rows = [MetadataEntry(group: "File", key: "Name", value: url.lastPathComponent)]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let size = attrs[.size] as? Int64 {
                rows.append(MetadataEntry(group: "File", key: "Size",
                                          value: "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) (\(size) bytes)"))
            }
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .medium
            if let d = attrs[.creationDate] as? Date { rows.append(MetadataEntry(group: "File", key: "Created", value: f.string(from: d))) }
            if let d = attrs[.modificationDate] as? Date { rows.append(MetadataEntry(group: "File", key: "Modified", value: f.string(from: d))) }
        }
        return rows
    }

    static func imageRows(_ url: URL) -> [MetadataEntry] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [] }
        var rows: [MetadataEntry] = []
        if let type = CGImageSourceGetType(src) { rows.append(MetadataEntry(group: "Image", key: "Type", value: type as String)) }
        rows.append(MetadataEntry(group: "Image", key: "Frames", value: "\(CGImageSourceGetCount(src))"))
        for (key, value) in props.sorted(by: { $0.key < $1.key }) {
            if let dict = value as? [String: Any] {
                let group = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                    rows.append(MetadataEntry(group: group == "Exif" ? "EXIF" : group, key: k, value: describe(v)))
                }
            } else {
                rows.append(MetadataEntry(group: "Image", key: key, value: describe(value)))
            }
        }
        return rows
    }

    static func mediaRows(_ url: URL) async -> [MetadataEntry] {
        guard let info = try? await MediaProbe.probe(url) else { return [] }
        var rows: [MetadataEntry] = [MetadataEntry(group: "Container", key: "Format", value: info.formatName)]
        if let d = info.duration { rows.append(MetadataEntry(group: "Container", key: "Duration", value: formatDuration(d))) }
        if let b = info.bitRate { rows.append(MetadataEntry(group: "Container", key: "Bit rate", value: "\(b / 1000) kbps")) }
        for (k, v) in info.tags.sorted(by: { $0.key < $1.key }) {
            rows.append(MetadataEntry(group: "Tags", key: k, value: v))
        }
        for s in info.streams {
            let group = "Track \(s.index + 1) (\(s.isAttachedPicture ? "cover art" : s.type))"
            rows.append(MetadataEntry(group: group, key: "Codec", value: s.codec))
            if let w = s.width, let h = s.height { rows.append(MetadataEntry(group: group, key: "Size", value: "\(w) × \(h)")) }
            if let f = s.frameRate, s.type == "video" { rows.append(MetadataEntry(group: group, key: "Frame rate", value: String(format: "%.3g fps", f))) }
            if s.rotation != 0 { rows.append(MetadataEntry(group: group, key: "Rotation", value: "\(s.rotation)°")) }
            if let r = s.sampleRate { rows.append(MetadataEntry(group: group, key: "Sample rate", value: "\(r) Hz")) }
            if let c = s.channels { rows.append(MetadataEntry(group: group, key: "Channels", value: "\(c)")) }
            if let l = s.language { rows.append(MetadataEntry(group: group, key: "Language", value: l)) }
            if let t = s.title { rows.append(MetadataEntry(group: group, key: "Title", value: t)) }
        }
        return rows
    }

    static func pdfRows(_ url: URL) -> [MetadataEntry] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var rows = [MetadataEntry(group: "PDF", key: "Version", value: "\(doc.majorVersion).\(doc.minorVersion)"),
                    MetadataEntry(group: "PDF", key: "Pages", value: "\(doc.pageCount)"),
                    MetadataEntry(group: "PDF", key: "Encrypted", value: doc.isEncrypted ? "Yes" : "No"),
                    MetadataEntry(group: "PDF", key: "Locked", value: doc.isLocked ? "Yes" : "No")]
        for (k, v) in (doc.documentAttributes ?? [:]).sorted(by: { "\($0.key)" < "\($1.key)" }) {
            rows.append(MetadataEntry(group: "Document", key: "\(k)", value: describe(v)))
        }
        return rows
    }

    static func documentRows(_ url: URL, format: Format?) -> [MetadataEntry] {
        var attributes: NSDictionary?
        _ = try? NSAttributedString(url: url, options: [:], documentAttributes: &attributes)
        var rows: [MetadataEntry] = []
        for (k, v) in (attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let interesting: [NSAttributedString.DocumentAttributeKey] = [.title, .author, .subject, .company, .keywords,
                                                                          .comment, .copyright, .creationTime, .modificationTime,
                                                                          .editor, .manager, .category]
            if interesting.contains(k) { rows.append(MetadataEntry(group: "Document", key: k.rawValue, value: describe(v))) }
        }
        return rows
    }

    static func describe(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.map(describe).joined(separator: ", ")
        case let d as Date:
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .medium
            return f.string(from: d)
        case let d as [String: Any]: return d.map { "\($0.key)=\(describe($0.value))" }.sorted().joined(separator: "; ")
        default: return "\(value)"
        }
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total / 60) % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Writing (copies)

    /// Writes a copy of `item` with the edited fields.
    public static func write(_ item: InputItem, fields: EditableMetadata, to output: URL) async throws {
        switch item.kind {
        case .image:
            guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil), let type = CGImageSourceGetType(src),
                  let dest = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
                throw JobFailure("This image can't be saved with new metadata.")
            }
            var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
            var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFImageDescription as String] = fields.title.isEmpty ? nil : fields.title
            tiff[kCGImagePropertyTIFFArtist as String] = fields.author.isEmpty ? nil : fields.author
            tiff[kCGImagePropertyTIFFCopyright as String] = fields.copyright.isEmpty ? nil : fields.copyright
            props[kCGImagePropertyTIFFDictionary as String] = tiff
            var iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
            iptc[kCGImagePropertyIPTCObjectName as String] = fields.title.isEmpty ? nil : fields.title
            iptc[kCGImagePropertyIPTCByline as String] = fields.author.isEmpty ? nil : [fields.author]
            iptc[kCGImagePropertyIPTCCaptionAbstract as String] = fields.comment.isEmpty ? nil : fields.comment
            iptc[kCGImagePropertyIPTCCopyrightNotice as String] = fields.copyright.isEmpty ? nil : fields.copyright
            props[kCGImagePropertyIPTCDictionary as String] = iptc
            guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw JobFailure("This image can't be read.") }
            if let f = item.format, [.jpg, .heic].contains(f) {
                props[kCGImageDestinationLossyCompressionQuality as String] = 0.95
            }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw JobFailure("Couldn't save the image.") }
        case .audio, .video:
            var args = ["-map", "0", "-c", "copy", "-map_metadata", "0"]
            for (key, value) in [("title", fields.title), ("artist", fields.author), ("comment", fields.comment),
                                 ("copyright", fields.copyright)] {
                args += ["-metadata", "\(key)=\(value)"]
            }
            try await MediaEngine.run([FFmpegAttempt("tags", output: args)], input: item.url, output: output,
                                      duration: nil, failure: "Couldn't save the new tags.")
        case .pdf:
            let doc = try PDFEngine.open(item.url)
            var attrs = doc.documentAttributes ?? [:]
            attrs[PDFDocumentAttribute.titleAttribute] = fields.title
            attrs[PDFDocumentAttribute.authorAttribute] = fields.author
            attrs[PDFDocumentAttribute.subjectAttribute] = fields.comment
            doc.documentAttributes = attrs
            try? FileManager.default.removeItem(at: output)
            guard doc.write(to: output) else { throw JobFailure("Couldn't save the PDF.") }
        default:
            throw JobFailure("Metadata can't be edited for this kind of file.")
        }
    }
}


public enum PDFOrganizer {
    /// Writes the pages in the given order (with rotations) into a new PDF.
    public static func write(sources: [PDFDocument], pages: [PageRef], to output: URL) throws {
        guard !pages.isEmpty else { throw JobFailure("There are no pages left to save.") }
        let out = PDFDocument()
        for ref in pages {
            guard sources.indices.contains(ref.source),
                  let page = sources[ref.source].page(at: ref.page)?.copy() as? PDFPage else { continue }
            page.rotation = ((page.rotation + ref.rotation) % 360 + 360) % 360
            out.insert(page, at: out.pageCount)
        }
        try? FileManager.default.removeItem(at: output)
        guard out.pageCount > 0, out.write(to: output) else { throw JobFailure("Couldn't save the PDF.") }
    }
}
#endif
