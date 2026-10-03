import Foundation

/// What ffprobe knows about a media file.
public struct MediaInfo: Sendable, Equatable {
    public struct Stream: Sendable, Equatable {
        public var index: Int
        /// "video", "audio", "subtitle", "data", "attachment"
        public var type: String
        public var codec: String
        public var width: Int?
        public var height: Int?
        public var pixelFormat: String?
        public var sampleRate: Int?
        public var channels: Int?
        public var bitRate: Int?
        /// Average frames per second (video).
        public var frameRate: Double?
        public var duration: Double?
        /// Cover art / thumbnail rather than real video.
        public var isAttachedPicture: Bool
        /// Display rotation in degrees (0, 90, 180, 270).
        public var rotation: Int
        public var language: String?
        public var title: String?

        public init(index: Int, type: String, codec: String, width: Int? = nil, height: Int? = nil,
                    pixelFormat: String? = nil, sampleRate: Int? = nil, channels: Int? = nil, bitRate: Int? = nil,
                    frameRate: Double? = nil, duration: Double? = nil, isAttachedPicture: Bool = false,
                    rotation: Int = 0, language: String? = nil, title: String? = nil) {
            self.index = index
            self.type = type
            self.codec = codec
            self.width = width
            self.height = height
            self.pixelFormat = pixelFormat
            self.sampleRate = sampleRate
            self.channels = channels
            self.bitRate = bitRate
            self.frameRate = frameRate
            self.duration = duration
            self.isAttachedPicture = isAttachedPicture
            self.rotation = rotation
            self.language = language
            self.title = title
        }
    }

    public var formatName: String
    public var duration: Double?
    public var bitRate: Int?
    public var size: Int64?
    public var streams: [Stream]
    public var tags: [String: String]

    public init(formatName: String, duration: Double?, bitRate: Int? = nil, size: Int64? = nil,
                streams: [Stream], tags: [String: String] = [:]) {
        self.formatName = formatName
        self.duration = duration
        self.bitRate = bitRate
        self.size = size
        self.streams = streams
        self.tags = tags
    }

    /// The main (first real) video stream.
    public var video: Stream? { streams.first { $0.type == "video" && !$0.isAttachedPicture } }
    public var audio: [Stream] { streams.filter { $0.type == "audio" } }
    public var subtitles: [Stream] { streams.filter { $0.type == "subtitle" } }
    public var coverArt: Stream? { streams.first { $0.type == "video" && $0.isAttachedPicture } }
    public var hasVideo: Bool { video != nil }
    public var hasAudio: Bool { !audio.isEmpty }

    /// Displayed video size (rotation applied).
    public var displaySize: (width: Int, height: Int)? {
        guard let v = video, let w = v.width, let h = v.height else { return nil }
        return v.rotation % 180 == 0 ? (w, h) : (h, w)
    }
}

/// Runs ffprobe and parses its JSON.
public enum MediaProbe {
    public static func probe(_ url: URL) async throws -> MediaInfo {
        guard let ffprobe = FFmpegLocator.ffprobe else {
            throw JobFailure("The audio/video reader (ffprobe) is missing from this copy of Clementine.")
        }
        let result = try await ProcessRunner.run(ffprobe, ["-v", "error", "-print_format", "json",
                                                           "-show_format", "-show_streams", url.path])
        guard result.status == 0 else {
            throw JobFailure("This file can't be read as audio or video. It may be damaged.",
                             details: ProcessRunner.tail(result.stderrString))
        }
        return try parse(result.stdout)
    }

    /// Parses `ffprobe -print_format json -show_format -show_streams`.
    public static func parse(_ data: Data) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JobFailure("Couldn't read the media information.")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = (root["streams"] as? [[String: Any]] ?? []).map(parseStream)
        var tags: [String: String] = [:]
        for (k, v) in format["tags"] as? [String: Any] ?? [:] { tags[k.lowercased()] = "\(v)" }
        return MediaInfo(formatName: format["format_name"] as? String ?? "",
                         duration: double(format["duration"]),
                         bitRate: int(format["bit_rate"]),
                         size: int(format["size"]).map(Int64.init),
                         streams: streams, tags: tags)
    }

    static func parseStream(_ s: [String: Any]) -> MediaInfo.Stream {
        let disposition = s["disposition"] as? [String: Any] ?? [:]
        let tags = s["tags"] as? [String: Any] ?? [:]
        var rotation = 0
        if let r = int(tags["rotate"]) { rotation = r }
        for side in s["side_data_list"] as? [[String: Any]] ?? [] {
            if let r = int(side["rotation"]) { rotation = r }
        }
        rotation = ((rotation % 360) + 360) % 360
        return MediaInfo.Stream(
            index: int(s["index"]) ?? 0,
            type: s["codec_type"] as? String ?? "",
            codec: s["codec_name"] as? String ?? "",
            width: int(s["width"]),
            height: int(s["height"]),
            pixelFormat: s["pix_fmt"] as? String,
            sampleRate: int(s["sample_rate"]),
            channels: int(s["channels"]),
            bitRate: int(s["bit_rate"]),
            frameRate: rational(s["avg_frame_rate"]) ?? rational(s["r_frame_rate"]),
            duration: double(s["duration"]),
            isAttachedPicture: (int(disposition["attached_pic"]) ?? 0) == 1,
            rotation: rotation,
            language: tags["language"] as? String,
            title: tags["title"] as? String)
    }

    static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as Int: return n
        case let n as Double: return Int(n)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Double(s).map { Int($0) }
        default: return nil
        }
    }

    static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// "30000/1001" → 29.97; "0/0" → nil.
    static func rational(_ v: Any?) -> Double? {
        guard let s = v as? String else { return nil }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0, n > 0 { return n / d }
        return Double(s).flatMap { $0 > 0 ? $0 : nil }
    }
}
