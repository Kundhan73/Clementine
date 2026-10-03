import Foundation

/// Finder-style output names: "photo.jpg", "photo 2.jpg", "video (trimmed).mp4",
/// "video (trimmed) 2.mp4". Never returns a name that already exists.
public enum OutputNamer {
    /// Builds a file or folder name. `number` 1 means no number.
    public static func name(base: String, suffix: String? = nil, number: Int = 1, extension ext: String) -> String {
        var name = base
        if let suffix, !suffix.isEmpty { name += " (\(suffix))" }
        if number > 1 { name += " \(number)" }
        if !ext.isEmpty { name += ".\(ext)" }
        return name
    }

    /// First free URL in `directory` for the given parts.
    public static func uniqueURL(in directory: URL, base: String, suffix: String? = nil, extension ext: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var n = 1
        while true {
            let url = directory.appendingPathComponent(name(base: base, suffix: suffix, number: n, extension: ext))
            if !exists(url) { return url }
            n += 1
        }
    }

    /// Base name of a source file: "report.pdf" → "report", "a.tar.gz" → "a".
    public static func baseName(of url: URL) -> String {
        let base = Format.baseName(of: url.lastPathComponent)
        return base.isEmpty ? "Untitled" : base
    }

    /// Two-digit-or-more zero padding for page/part numbers: "Page 001".
    public static func pageName(_ index: Int, of count: Int, prefix: String = "Page") -> String {
        let width = max(3, String(count).count)
        let digits = String(index)
        return "\(prefix) \(String(repeating: "0", count: max(0, width - digits.count)))\(digits)"
    }
}
