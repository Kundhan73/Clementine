import Foundation

/// Audio/video tools built on ffmpeg.
public enum MediaTools {
    /// Remove audio, copy video.
    public static func mute(_ input: URL, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await MediaProbe.probe(input)
        guard info.hasVideo else { throw JobFailure("This file has no video.") }
        try await MediaEngine.run([FFmpegAttempt("mute", output: ["-map", "0", "-map", "-0:a", "-c", "copy", "-map_metadata", "0"]),
                                   FFmpegAttempt("mute-v", output: ["-map", "0:V", "-c", "copy"])],
                                  input: input, output: output, duration: info.duration,
                                  failure: "Couldn't remove the sound.", progress: progress)
    }

    /// Drop tags, chapters and cover art; streams are copied unchanged.
    public static func stripMetadata(_ input: URL, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await MediaProbe.probe(input)
        try await MediaEngine.run([FFmpegAttempt("strip", output: ["-map", "0:V?", "-map", "0:a?", "-map", "0:s?", "-c", "copy",
                                                                    "-map_metadata", "-1", "-map_chapters", "-1",
                                                                    "-fflags", "+bitexact", "-flags:v", "+bitexact",
                                                                    "-flags:a", "+bitexact"]),
                                   FFmpegAttempt("strip-av", output: ["-map", "0:V?", "-map", "0:a?", "-c", "copy",
                                                                       "-map_metadata", "-1", "-map_chapters", "-1"])],
                                  input: input, output: output, duration: info.duration,
                                  failure: "Couldn't remove the metadata.", progress: progress)
    }

    // MARK: Compress

    /// Video: presets map to quality and size caps; an exact size sets the
    /// total bitrate to target×8/duration×0.96 (audio 128k, less if tight),
    /// lowering the resolution below ~300 kbps, and re-runs once if the
    /// result overshoots. Always H.264/AAC MP4.
    public static func compressVideo(_ input: URL, to output: URL, options: CompressOptions, settings: ConversionSettings,
                                     progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        let info = try await MediaProbe.probe(input)
        guard info.hasVideo, let duration = info.duration, duration > 0 else {
            throw JobFailure("This file has no video to compress.")
        }
        let target = options.targetBytes ?? options.presetLimitBytes
        if let target, let size = fileSize(input), size <= target, info.video.map({ MediaPlanner.mp4Video.contains($0.codec) }) == true {
            try await MediaEngine.run([FFmpegAttempt("copy", output: ["-map", "0:V:0", "-map", "0:a?", "-c", "copy", "-movflags", "+faststart"])],
                                      input: input, output: output, duration: duration, failure: "Couldn't copy the video.", progress: progress)
            return "Already under \(ByteCountFormatter.string(fromByteCount: target, countStyle: .file))."
        }
        let (srcW, srcH) = info.displaySize ?? (1280, 720)
        if let target {
            var totalKbps = Double(target) * 8 / duration * 0.96 / 1000
            for pass in 0..<2 {
                let audioKbps: Double = info.hasAudio ? (totalKbps > 1000 ? 128 : totalKbps > 400 ? 96 : 64) : 0
                let videoKbps = max(50, totalKbps - audioKbps)
                let maxHeight: Int? = videoKbps < 300 ? 480 : videoKbps < 900 ? 720 : nil
                let args = encodeArgs(info: info, width: srcW, height: srcH, maxHeight: maxHeight,
                                      video: ["-b:v", "\(Int(videoKbps))k", "-maxrate", "\(Int(videoKbps * 1.25))k",
                                              "-bufsize", "\(Int(videoKbps * 2))k"],
                                      audioKbps: Int(audioKbps), settings: settings)
                try await MediaEngine.run(args, input: input, output: output, duration: duration,
                                          failure: "Couldn't compress the video.", progress: progress)
                guard let size = fileSize(output), size > target, pass == 0 else { break }
                totalKbps *= Double(target) / Double(size) * 0.95
            }
            if let size = fileSize(output), size > target {
                return "Smallest possible: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))."
            }
            return nil
        }
        let (quality, maxHeight): (Int, Int?) = {
            switch options.preset {
            case .high: return (62, nil)
            case .medium: return (52, 1080)
            default: return (42, 720)
            }
        }()
        let bpp = options.preset == .high ? 0.09 : options.preset == .medium ? 0.06 : 0.04
        let h = min(maxHeight ?? srcH, srcH)
        let w = Int(Double(srcW) * Double(h) / Double(max(1, srcH)))
        let kbps = Int(Double(w * h) * min(info.video?.frameRate ?? 30, 60) * bpp / 1000)
        let args = encodeArgs(info: info, width: srcW, height: srcH, maxHeight: maxHeight,
                              video: ["-q:v", "\(quality)"], fallbackVideo: ["-b:v", "\(max(300, kbps))k"],
                              audioKbps: options.preset == .small ? 96 : 128, settings: settings)
        try await MediaEngine.run(args, input: input, output: output, duration: duration,
                                  failure: "Couldn't compress the video.", progress: progress)
        return nil
    }

    /// Attempts for an H.264/AAC MP4 encode with the given rate control.
    static func encodeArgs(info: MediaInfo, width: Int, height: Int, maxHeight: Int?, video: [String],
                           fallbackVideo: [String]? = nil, audioKbps: Int, settings: ConversionSettings) -> [FFmpegAttempt] {
        var filters: [String] = []
        if let maxHeight, height > maxHeight {
            filters.append("scale=-2:\(maxHeight)")
        }
        filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        let vf = ["-vf", filters.joined(separator: ","), "-pix_fmt", "yuv420p"]
        let audio = info.hasAudio ? ["-c:a", "aac_at", "-b:a", "\(max(32, audioKbps))k"] : ["-an"]
        let base = ["-map", "0:V:0", "-map", "0:a:0?", "-map_metadata", "0", "-movflags", "+faststart", "-sn", "-dn"]
        var attempts: [FFmpegAttempt] = []
        if settings.hardwareEncoding {
            attempts.append(FFmpegAttempt("vt", output: base + ["-c:v", "h264_videotoolbox", "-allow_sw", "1"] + video + vf + audio))
            if let fallbackVideo {
                attempts.append(FFmpegAttempt("vt-bitrate", output: base + ["-c:v", "h264_videotoolbox", "-allow_sw", "1"] +
                                              fallbackVideo + vf + audio))
            }
        }
        let software = (fallbackVideo ?? video).contains("-q:v") ? ["-q:v", "5"] : (fallbackVideo ?? video)
        attempts.append(FFmpegAttempt("mpeg4", output: base + ["-c:v", "mpeg4", "-tag:v", "mp4v"] + software + vf + audio))
        return attempts
    }

    /// Audio: bitrate = target×8/duration (clamped to codec-valid values),
    /// MP3 stays MP3, everything else becomes AAC (.m4a).
    public static func compressAudio(_ input: URL, format: Format, to output: URL, options: CompressOptions,
                                     progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        let info = try await MediaProbe.probe(input)
        guard info.hasAudio, let duration = info.duration, duration > 0 else {
            throw JobFailure("This file has no sound to compress.")
        }
        var kbps: Int
        if let target = options.targetBytes ?? options.presetLimitBytes {
            kbps = Int(Double(target) * 8 / duration * 0.97 / 1000)
            if kbps < 24 { throw JobFailure("That size is too small for this much audio.") }
        } else {
            kbps = options.preset == .high ? 192 : options.preset == .medium ? 128 : 96
        }
        let valid = format == .mp3 ? [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                                   : [24, 32, 48, 64, 80, 96, 112, 128, 160, 192, 256, 320]
        kbps = valid.last { $0 <= kbps } ?? valid[0]
        let codec = format == .mp3 ? ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"] : ["-c:a", "aac_at", "-b:a", "\(kbps)k"]
        var extra: [String] = []
        if let rate = info.audio.first?.sampleRate, rate > 48_000 { extra += ["-ar", "48000"] }
        if kbps <= 64, (info.audio.first?.channels ?? 2) > 1 { extra += ["-ac", "1"] }
        try await MediaEngine.run([FFmpegAttempt("audio", output: ["-map", "0:a:0", "-vn", "-map_metadata", "0"] + codec + extra)],
                                  input: input, output: output, duration: duration,
                                  failure: "Couldn't compress the audio.", progress: progress)
        return nil
    }

    // MARK: Speed

    /// atempo filters (each within 0.5…2) whose product is `factor`.
    public static func atempoChain(_ factor: Double) -> [String] {
        var remaining = factor
        var filters: [String] = []
        while remaining > 2.0001 { filters.append("atempo=2"); remaining /= 2 }
        while remaining < 0.4999 { filters.append("atempo=0.5"); remaining /= 0.5 }
        filters.append(String(format: "atempo=%.6g", remaining))
        return filters
    }

    /// Changes playback speed; audio pitch is preserved.
    public static func speed(_ input: URL, format: Format, factor: Double, to output: URL, settings: ConversionSettings,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        guard factor > 0.1, factor < 10 else { throw JobFailure("Choose a speed between 0.25× and 4×.") }
        let info = try await MediaProbe.probe(input)
        let duration = info.duration.map { $0 / factor }
        let tempo = atempoChain(factor).joined(separator: ",")
        if info.hasVideo && format.kind == .video {
            var graph = "[0:V:0]setpts=PTS/\(factor),scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p[v]"
            var maps = ["-map", "[v]"]
            if info.hasAudio {
                graph += ";[0:a:0]\(tempo)[a]"
                maps += ["-map", "[a]"]
            }
            let target: Format = [.mp4, .mov, .mkv].contains(format) ? format : .mp4
            let audio = info.hasAudio ? MediaPlanner.audioEncoder(for: target, stream: info.audio.first, settings: settings) : []
            let common = ["-filter_complex", graph] + maps + ["-map_metadata", "0"]
            var attempts: [FFmpegAttempt] = []
            if settings.hardwareEncoding {
                attempts.append(FFmpegAttempt("vt", output: common + ["-c:v", "h264_videotoolbox", "-q:v",
                                                                      "\(settings.videoQuality)", "-allow_sw", "1"] + audio))
            }
            attempts.append(FFmpegAttempt("mpeg4", output: common + ["-c:v", "mpeg4", "-q:v", "3"] + audio))
            try await MediaEngine.run(attempts, input: input, output: output, duration: duration,
                                      failure: "Couldn't change the speed.", progress: progress)
        } else {
            guard info.hasAudio else { throw JobFailure("This file has no sound.") }
            let codec = MediaPlanner.audioEncoder(for: format, stream: info.audio.first, settings: settings)
            try await MediaEngine.run([FFmpegAttempt("audio", output: ["-map", "0:a:0", "-vn", "-af", tempo,
                                                                         "-map_metadata", "0"] + codec)],
                                      input: input, output: output, duration: duration,
                                      failure: "Couldn't change the speed.", progress: progress)
        }
    }

    // MARK: Normalize (EBU R128, two passes)

    public struct Loudness: Equatable, Sendable {
        public var integrated: Double
        public var truePeak: Double
        public var range: Double
        public var threshold: Double
        public var offset: Double
    }

    /// Parses the JSON block loudnorm prints at the end of stderr.
    public static func parseLoudnorm(_ log: String, prefix: String = "input") -> Loudness? {
        guard let open = log.range(of: "{", options: .backwards),
              let close = log.range(of: "}", options: .backwards), open.lowerBound < close.lowerBound,
              let data = String(log[open.lowerBound...close.lowerBound]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        func value(_ key: String) -> Double? { json[key].flatMap(Double.init) }
        guard let i = value("\(prefix)_i"), let tp = value("\(prefix)_tp"), let lra = value("\(prefix)_lra") else { return nil }
        return Loudness(integrated: i, truePeak: tp, range: lra, threshold: value("\(prefix)_thresh") ?? -70,
                        offset: value("target_offset") ?? 0)
    }

    /// Measures, then normalises to the target loudness. Returns a note like
    /// "−23.1 → −16.0 LUFS".
    public static func normalize(_ input: URL, format: Format, options: NormalizeOptions, to output: URL,
                                 settings: ConversionSettings, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let info = try await MediaProbe.probe(input)
        guard info.hasAudio else { throw JobFailure("This file has no sound to normalise.") }
        guard let ffmpeg = FFmpegLocator.ffmpeg else { throw JobFailure("ffmpeg is missing.") }
        let target = "I=\(options.integratedLUFS):TP=\(options.truePeak):LRA=\(options.loudnessRange)"
        let measure = try await ProcessRunner.run(ffmpeg, ["-nostdin", "-hide_banner", "-i", MediaEngine.ffmpegPath(input),
                                                           "-map", "0:a:0", "-af", "loudnorm=\(target):print_format=json",
                                                           "-f", "null", "-"])
        progress(0.4)
        guard measure.status == 0, let m = parseLoudnorm(measure.stderrString) else {
            throw JobFailure("Couldn't measure the loudness.", details: ProcessRunner.tail(measure.stderrString))
        }
        guard m.integrated > -70 else { throw JobFailure("This file is silent.") }
        let filter = "loudnorm=\(target):measured_I=\(m.integrated):measured_TP=\(m.truePeak):measured_LRA=\(m.range)" +
            ":measured_thresh=\(m.threshold):offset=\(m.offset):linear=true:print_format=summary"
        let rate = "\(min(info.audio.first?.sampleRate ?? 48_000, 48_000))"
        var attempts: [FFmpegAttempt]
        if info.hasVideo && format.kind == .video {
            let target: Format = [.mp4, .mov, .mkv, .webm].contains(format) ? format : .mkv
            let audio = MediaPlanner.audioEncoder(for: target, stream: info.audio.first, settings: settings)
            attempts = [FFmpegAttempt("video", output: ["-map", "0:V?", "-map", "0:a:0", "-map", "0:s?", "-c:v", "copy",
                                                         "-c:s", "copy", "-af", filter, "-ar", rate, "-map_metadata", "0"] + audio),
                        FFmpegAttempt("video-nosubs", output: ["-map", "0:V?", "-map", "0:a:0", "-c:v", "copy", "-af", filter,
                                                                "-ar", rate, "-map_metadata", "0"] + audio)]
        } else {
            let codec = MediaPlanner.audioEncoder(for: format, stream: info.audio.first, settings: settings)
            attempts = [FFmpegAttempt("audio", output: ["-map", "0:a:0", "-vn", "-af", filter, "-ar", rate,
                                                         "-map_metadata", "0"] + codec)]
        }
        try await MediaEngine.run(attempts, input: input, output: output, duration: info.duration,
                                  failure: "Couldn't normalise the loudness.") { progress(0.4 + 0.6 * $0) }
        return String(format: "%.1f → %.1f LUFS", m.integrated, options.integratedLUFS)
    }

    // MARK: Channels

    public static func channels(_ input: URL, format: Format, options: ChannelOptions, to output: URL,
                                settings: ConversionSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await MediaProbe.probe(input)
        guard let stream = info.audio.first else { throw JobFailure("This file has no sound.") }
        let gl = pow(10, options.leftGainDB / 20), gr = pow(10, options.rightGainDB / 20)
        let stereo = (stream.channels ?? 2) >= 2
        let pan: String
        switch options.mode {
        case .mono: pan = stereo ? "pan=mono|c0=\(0.5 * gl)*c0+\(0.5 * gr)*c1" : "pan=mono|c0=\(gl)*c0"
        case .stereo: pan = stereo ? "pan=stereo|c0=\(gl)*c0|c1=\(gr)*c1" : "pan=stereo|c0=\(gl)*c0|c1=\(gr)*c0"
        case .leftOnly: pan = "pan=mono|c0=\(gl)*c0"
        case .rightOnly: pan = stereo ? "pan=mono|c0=\(gr)*c1" : "pan=mono|c0=\(gr)*c0"
        case .swap: pan = stereo ? "pan=stereo|c0=\(gl)*c1|c1=\(gr)*c0" : "pan=stereo|c0=\(gl)*c0|c1=\(gr)*c0"
        }
        let codec = removingOption("-ac", from: MediaPlanner.audioEncoder(for: format, stream: stream, settings: settings))
        try await MediaEngine.run([FFmpegAttempt("pan", output: ["-map", "0:a:0", "-vn", "-af", pan, "-map_metadata", "0"] + codec)],
                                  input: input, output: output, duration: info.duration,
                                  failure: "Couldn't change the channels.", progress: progress)
    }

    // MARK: Rotate / flip / resize video

    /// Lossless for MP4/MOV (display matrix); other containers re-encode.
    public static func rotate(_ input: URL, format: Format, options: RotateOptions, to output: URL,
                              settings: ConversionSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await MediaProbe.probe(input)
        guard let video = info.video else { throw JobFailure("This file has no video.") }
        var attempts: [FFmpegAttempt] = []
        if [.mp4, .mov, .m4v].contains(format) {
            // ffprobe/ffmpeg rotation is counter-clockwise; "right" turns clockwise.
            let delta: Int
            switch options.turn {
            case .none: delta = 0
            case .right: delta = -90
            case .half: delta = 180
            case .left: delta = 90
            }
            var input: [String] = ["-display_rotation:v:0", "\(((video.rotation + delta) % 360 + 360) % 360)"]
            if options.flipHorizontal { input += ["-display_hflip:v:0"] }
            if options.flipVertical { input += ["-display_vflip:v:0"] }
            attempts.append(FFmpegAttempt("matrix", input: input, output: ["-map", "0", "-c", "copy", "-map_metadata", "0"]))
        }
        var filters: [String] = []
        switch options.turn {
        case .none: break
        case .right: filters.append("transpose=1")
        case .half: filters += ["hflip", "vflip"]
        case .left: filters.append("transpose=2")
        }
        if options.flipHorizontal { filters.append("hflip") }
        if options.flipVertical { filters.append("vflip") }
        filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        attempts += reencodeAttempts(format: format, info: info, filters: filters, settings: settings)
        try await MediaEngine.run(attempts, input: input, output: output, duration: info.duration,
                                  failure: "Couldn't rotate the video.", progress: progress)
    }

    public static func resize(_ input: URL, format: Format, options: ResizeOptions, to output: URL,
                              settings: ConversionSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await MediaProbe.probe(input)
        guard let (w, h) = info.displaySize else { throw JobFailure("This file has no video.") }
        let (nw, nh) = ImageGeometry.resized(width: w, height: h, mode: options.mode)
        let filters = ["scale=\(nw - nw % 2):\(nh - nh % 2):flags=lanczos"]
        try await MediaEngine.run(reencodeAttempts(format: format, info: info, filters: filters, settings: settings),
                                  input: input, output: output, duration: info.duration,
                                  failure: "Couldn't resize the video.", progress: progress)
    }

    /// Video re-encode in the same container (audio copied when it fits).
    static func reencodeAttempts(format: Format, info: MediaInfo, filters: [String],
                                 settings: ConversionSettings) -> [FFmpegAttempt] {
        let target: Format = [.mp4, .mov, .mkv, .webm, .avi, .wmv].contains(format) ? format : .mp4
        let vf = ["-vf", filters.joined(separator: ","), "-pix_fmt", "yuv420p"]
        let base = ["-map", "0:V:0", "-map", "0:a?", "-map_metadata", "0", "-sn", "-dn"] +
            ([.mp4, .mov].contains(target) ? ["-movflags", "+faststart"] : [])
        let audioCopy = MediaPlanner.copyRules(for: target).audio
        let audio = info.audio.allSatisfy { audioCopy($0.codec) } ? ["-c:a", "copy"]
            : MediaPlanner.audioEncoder(for: target, stream: info.audio.first, settings: settings)
        return MediaPlanner.videoEncoders(for: target, info: info, settings: settings).map { label, encoder in
            // The encoder's own even-size filter is replaced by ours.
            FFmpegAttempt(label, output: base + removingOption("-vf", from: encoder) + vf + audio)
        }
    }

    // MARK: Split and join

    /// Splits into parts by stream copy (cuts land on keyframes).
    public static func split(_ input: URL, format: Format, options: SplitMediaOptions, into folder: URL, base: String,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        let info = try await MediaProbe.probe(input)
        guard let duration = info.duration, duration > 0 else { throw JobFailure("This file's length is unknown.") }
        let segments = options.segments(duration: duration)
        guard segments.count > 1 else { throw JobFailure("That would make only one part.") }
        for (i, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let out = folder.appendingPathComponent("\(base) part \(i + 1).\(format.fileExtension)")
            try await MediaEngine.run([FFmpegAttempt("copy", input: ["-ss", String(format: "%.3f", segment.start)],
                                                     output: ["-t", String(format: "%.3f", segment.duration), "-map", "0:V?",
                                                              "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero",
                                                              "-map_metadata", "0"])],
                                      input: input, output: out, duration: segment.duration,
                                      failure: "Couldn't split the file.") { p in
                progress((Double(i) + p) / Double(segments.count))
            }
        }
        return segments.count
    }

    /// Joins clips: stream copy when all match, otherwise re-encodes to the
    /// first clip's size (letterboxed), frame rate and a common audio format.
    public static func join(_ inputs: [URL], to output: URL, format: Format, settings: ConversionSettings,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        guard inputs.count > 1 else { throw JobFailure("Choose at least two files to join.") }
        guard let ffmpeg = FFmpegLocator.ffmpeg else { throw JobFailure("ffmpeg is missing.") }
        var infos: [MediaInfo] = []
        for url in inputs { infos.append(try await MediaProbe.probe(url)) }
        let total = infos.compactMap(\.duration).reduce(0, +)
        let isVideo = format.kind == .video
        let tmp = try TempDirectory(prefix: "clementine-join")
        defer { tmp.remove() }

        if canConcatCopy(infos, video: isVideo) {
            let list = tmp.file("list.txt")
            let body = inputs.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
            try Data(body.utf8).write(to: list)
            let result = try await ProcessRunner.run(ffmpeg, ["-nostdin", "-hide_banner", "-y", "-loglevel", "error",
                                                              "-f", "concat", "-safe", "0", "-i", list.path, "-map", "0",
                                                              "-c", "copy", MediaEngine.ffmpegPath(output)])
            if result.status == 0, (fileSize(output) ?? 0) > 0 { progress(1); return }
        }

        var args = ["-nostdin", "-hide_banner", "-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1"]
        for url in inputs { args += ["-i", MediaEngine.ffmpegPath(url)] }
        var graph = ""
        var labels = ""
        let allAudio = infos.allSatisfy(\.hasAudio)
        if isVideo {
            let first = infos.first { $0.hasVideo }
            let (w0, h0) = first?.displaySize ?? (1280, 720)
            let w = w0 - w0 % 2, h = h0 - h0 % 2
            let fps = min(60, first?.video?.frameRate ?? 30)
            for (i, info) in infos.enumerated() {
                guard info.hasVideo else { throw JobFailure("\(inputs[i].lastPathComponent) has no video.") }
                graph += "[\(i):V:0]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2," +
                    "setsar=1,fps=\(String(format: "%.3f", fps)),format=yuv420p[v\(i)];"
                labels += "[v\(i)]"
                if allAudio {
                    graph += "[\(i):a:0]aresample=48000,aformat=channel_layouts=stereo[a\(i)];"
                    labels += "[a\(i)]"
                }
            }
            graph += "\(labels)concat=n=\(inputs.count):v=1:a=\(allAudio ? 1 : 0)[v]" + (allAudio ? "[a]" : "")
            args += ["-filter_complex", graph, "-map", "[v]"] + (allAudio ? ["-map", "[a]"] : [])
            let target: Format = [.mp4, .mov, .mkv].contains(format) ? format : .mp4
            let encoder = settings.hardwareEncoding
                ? ["-c:v", "h264_videotoolbox", "-q:v", "\(settings.videoQuality)", "-allow_sw", "1"]
                : ["-c:v", "mpeg4", "-q:v", "3"]
            args += encoder + (allAudio ? MediaPlanner.audioEncoder(for: target, stream: nil, settings: settings) : [])
            if [.mp4, .mov].contains(target) { args += ["-movflags", "+faststart"] }
        } else {
            for (i, info) in infos.enumerated() {
                guard info.hasAudio else { throw JobFailure("\(inputs[i].lastPathComponent) has no sound.") }
                graph += "[\(i):a:0]aresample=48000,aformat=channel_layouts=stereo[a\(i)];"
                labels += "[a\(i)]"
            }
            graph += "\(labels)concat=n=\(inputs.count):v=0:a=1[a]"
            args += ["-filter_complex", graph, "-map", "[a]"] +
                MediaPlanner.audioEncoder(for: format, stream: nil, settings: settings)
        }
        let result = try await ProcessRunner.run(ffmpeg, args + [MediaEngine.ffmpegPath(output)]) { line in
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), total > 0 {
                progress(min(1, us / 1_000_000 / total))
            }
        }
        guard result.status == 0 else {
            // VideoToolbox unavailable: retry with the software encoder.
            if isVideo, settings.hardwareEncoding {
                var s = settings
                s.hardwareEncoding = false
                return try await join(inputs, to: output, format: format, settings: s, progress: progress)
            }
            throw JobFailure("Couldn't join the files.", details: ProcessRunner.tail(result.stderrString))
        }
    }

    static func canConcatCopy(_ infos: [MediaInfo], video: Bool) -> Bool {
        guard let first = infos.first else { return false }
        func signature(_ i: MediaInfo) -> String {
            let v = i.video.map { "\($0.codec) \($0.width ?? 0)x\($0.height ?? 0) \($0.pixelFormat ?? "")" } ?? "-"
            let a = i.audio.first.map { "\($0.codec) \($0.sampleRate ?? 0) \($0.channels ?? 0)" } ?? "-"
            return (video ? v : "") + " | " + a + " | \(i.streams.filter { $0.type != "data" }.count)"
        }
        let s = signature(first)
        return infos.allSatisfy { signature($0) == s }
    }

    /// Removes every "-name value" pair from an argument list.
    public static func removingOption(_ name: String, from args: [String]) -> [String] {
        var out: [String] = []
        var skip = false
        for arg in args {
            if skip { skip = false; continue }
            if arg == name { skip = true; continue }
            out.append(arg)
        }
        return out
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).map(Int64.init)
    }
}

/// Size calculations shared by image and video resizing.
public enum ImageGeometry {
    public static func resized(width: Int, height: Int, mode: ResizeOptions.Mode) -> (Int, Int) {
        let w = Double(width), h = Double(height)
        var scale: Double
        switch mode {
        case .percent(let p):
            scale = p / 100
        case .fit(let mw, let mh):
            let sw = mw.map { Double($0) / w } ?? .infinity
            let sh = mh.map { Double($0) / h } ?? .infinity
            scale = min(sw, sh)
            if !scale.isFinite { scale = 1 }
        case .longestEdge(let edge):
            scale = Double(edge) / max(w, h)
        }
        scale = max(0.001, scale)
        return (max(1, Int((w * scale).rounded())), max(1, Int((h * scale).rounded())))
    }
}
