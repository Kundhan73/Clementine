import Foundation

/// One way to run ffmpeg: arguments between `-i <input>` and the output path.
public struct FFmpegAttempt: Sendable, Equatable {
    public var label: String
    public var inputArgs: [String]
    public var outputArgs: [String]

    public init(_ label: String, input: [String] = [], output: [String]) {
        self.label = label
        self.inputArgs = input
        self.outputArgs = output
    }
}

/// Decides how to produce a target format from a probed source: stream copy
/// ("smart remux") whenever the streams fit the target container, otherwise
/// the right encoders (VideoToolbox first, software fallbacks after). Pure
/// logic, unit-tested on any platform.
public enum MediaPlanner {
    // Codecs each container can hold without re-encoding.
    static let mp4Video: Set<String> = ["h264", "hevc", "av1", "mpeg4"]
    static let mp4Audio: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3"]
    static let movVideo: Set<String> = ["h264", "hevc", "prores", "mpeg4", "mjpeg"]
    static let movAudio: Set<String> = ["aac", "alac", "mp3", "ac3", "eac3", "pcm_s16le", "pcm_s16be", "pcm_s24le",
                                        "pcm_s24be", "pcm_f32le"]
    static let webmVideo: Set<String> = ["vp8", "vp9", "av1"]
    static let webmAudio: Set<String> = ["opus", "vorbis"]
    static let aviVideo: Set<String> = ["mpeg4", "msmpeg4v3", "mjpeg"]
    static let aviAudio: Set<String> = ["mp3", "pcm_s16le", "ac3"]
    static let wmvVideo: Set<String> = ["wmv1", "wmv2", "wmv3", "vc1"]
    static let wmvAudio: Set<String> = ["wmav1", "wmav2"]
    static let mkvUnsupportedVideo: Set<String> = ["gif", "apng"]
    static let mkvSubtitles: Set<String> = ["subrip", "ass", "ssa", "webvtt", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"]
    static let textSubtitles: Set<String> = ["subrip", "ass", "ssa", "webvtt", "mov_text", "text"]

    /// Ordered attempts; the engine tries them until one succeeds.
    public static func plan(source: Format?, info: MediaInfo, target: Format,
                            settings: ConversionSettings) throws -> [FFmpegAttempt] {
        switch target {
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma:
            return try audioPlan(source: source, info: info, target: target, settings: settings)
        case .gif:
            return try gifPlan(info: info, settings: settings)
        case .mp4, .mov, .mkv, .webm, .avi, .wmv:
            return try videoPlan(info: info, target: target, settings: settings)
        default:
            throw JobFailure("\(target.displayName) isn't an audio or video format.")
        }
    }

    // MARK: Audio

    static func audioPlan(source: Format?, info: MediaInfo, target: Format,
                          settings: ConversionSettings) throws -> [FFmpegAttempt] {
        guard let stream = info.audio.first else {
            throw JobFailure("This file has no sound to convert.")
        }
        // Cover art goes along where the target supports it (audio sources only).
        let coverTargets: Set<Format> = [.mp3, .m4a, .flac]
        let keepCover = source?.kind != .video && info.coverArt != nil && coverTargets.contains(target)
        var maps = ["-map", "0:a:0"]
        if keepCover { maps += ["-map", "0:v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic"] } else { maps += ["-vn"] }
        maps += ["-map_metadata", "0", "-sn", "-dn"]
        if target == .mp3 { maps += ["-id3v2_version", "3"] }
        if target == .m4a { maps += ["-movflags", "+faststart"] }

        let encode = audioEncoder(for: target, stream: stream, settings: settings)
        var attempts: [FFmpegAttempt] = []
        if canCopyAudio(stream.codec, into: target) {
            attempts.append(FFmpegAttempt("copy", output: maps + ["-c:a", "copy"]))
        }
        attempts.append(FFmpegAttempt("encode", output: maps + encode))
        if keepCover {
            // Some covers can't be stored; retry without.
            var plain = ["-map", "0:a:0", "-vn", "-map_metadata", "0", "-sn", "-dn"]
            if target == .mp3 { plain += ["-id3v2_version", "3"] }
            attempts.append(FFmpegAttempt("encode-nocover", output: plain + encode))
        }
        return attempts
    }

    static func canCopyAudio(_ codec: String, into target: Format) -> Bool {
        switch target {
        case .mp3: return codec == "mp3"
        case .m4a: return codec == "aac" || codec == "alac"
        case .wav: return codec == "pcm_s16le"
        case .flac: return codec == "flac"
        case .ogg: return codec == "vorbis"
        case .opus: return codec == "opus"
        case .aiff: return codec == "pcm_s16be"
        case .wma: return codec == "wmav2" || codec == "wmav1"
        default: return false
        }
    }

    /// Encoder arguments for an audio target (also used for audio tracks in video).
    static func audioEncoder(for target: Format, stream: MediaInfo.Stream?, settings: ConversionSettings) -> [String] {
        let rate = stream?.sampleRate ?? 48_000
        let channels = stream?.channels ?? 2
        var args: [String]
        switch target {
        case .mp3:
            args = ["-c:a", "libmp3lame", "-q:a", "\(max(0, min(9, settings.mp3VBRQuality)))"]
            if rate > 48_000 { args += ["-ar", "48000"] }
            if channels > 2 { args += ["-ac", "2"] }
        case .m4a, .mp4, .mov:
            args = ["-c:a", "aac_at", "-b:a", "\(settings.aacBitrate)k"]
            if rate > 48_000 { args += ["-ar", "48000"] }
            if channels > 6 { args += ["-ac", "2"] }
        case .wav:
            args = ["-c:a", "pcm_s16le"]
        case .aiff:
            args = ["-c:a", "pcm_s16be"]
        case .flac:
            args = ["-c:a", "flac", "-compression_level", "\(max(0, min(12, settings.flacLevel)))"]
        case .ogg:
            args = ["-c:a", "libvorbis", "-q:a", "\(max(0, min(10, settings.vorbisQuality)))"]
        case .opus, .webm:
            args = ["-c:a", "libopus", "-b:a", "\(settings.opusBitrate)k", "-vbr", "on"]
            if channels > 2 { args += ["-ac", "2"] }
        case .wma, .wmv:
            args = ["-c:a", "wmav2", "-b:a", "\(settings.wmaBitrate)k"]
            if rate > 48_000 { args += ["-ar", "48000"] }
            if channels > 2 { args += ["-ac", "2"] }
        case .avi:
            args = ["-c:a", "libmp3lame", "-q:a", "4"]
            if rate > 48_000 { args += ["-ar", "48000"] }
            if channels > 2 { args += ["-ac", "2"] }
        case .mkv:
            args = ["-c:a", "aac_at", "-b:a", "\(settings.aacBitrate)k"]
            if rate > 48_000 { args += ["-ar", "48000"] }
        default:
            args = []
        }
        return args
    }

    // MARK: GIF

    static func gifPlan(info: MediaInfo, settings: ConversionSettings) throws -> [FFmpegAttempt] {
        guard info.hasVideo else { throw JobFailure("This file has no picture to turn into a GIF.") }
        let fps = max(1, min(50, settings.gifFPS))
        let width = max(16, settings.gifMaxWidth)
        let graph = "[0:V:0]fps=\(fps),scale='min(\(width),iw)':-1:flags=lanczos,split[a][b];" +
            "[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
        return [FFmpegAttempt("gif", output: ["-filter_complex", graph, "-an", "-sn", "-loop", "0"])]
    }

    // MARK: Video

    static func videoPlan(info: MediaInfo, target: Format, settings: ConversionSettings) throws -> [FFmpegAttempt] {
        guard let video = info.video else {
            throw JobFailure("This file has no video track.")
        }
        let audio = info.audio
        let (videoCopy, audioCopy) = copyRules(for: target)
        let canCopyVideo = videoCopy(video.codec)
        let canCopyAllAudio = audio.allSatisfy { audioCopy($0.codec) }

        let subtitleArgs = subtitles(for: target, info: info)
        var base = ["-map", "0:V:0", "-map", "0:a?", "-map_metadata", "0", "-dn"]
        if target == .mkv { base = ["-map", "0:V", "-map", "0:a?", "-map_metadata", "0", "-dn"] }
        if [.mp4, .mov].contains(target) { base += ["-movflags", "+faststart"] }

        let audioEncode = audio.isEmpty ? [] : audioEncoder(for: target, stream: audio.first, settings: settings)
        let audioArgs = canCopyAllAudio ? ["-c:a", "copy"] : audioEncode
        var attempts: [FFmpegAttempt] = []

        if canCopyVideo {
            var copy = base + ["-c:v", "copy"] + audioArgs
            if video.codec == "hevc" && [.mp4, .mov].contains(target) { copy += ["-tag:v", "hvc1"] }
            if let subs = subtitleArgs { attempts.append(FFmpegAttempt("remux", output: copy + subs)) }
            attempts.append(FFmpegAttempt("remux-nosubs", output: copy + ["-sn"]))
        }
        for (label, encoder) in videoEncoders(for: target, info: info, settings: settings) {
            let args = base + encoder + audioArgs
            if let subs = subtitleArgs { attempts.append(FFmpegAttempt(label, output: args + subs)) }
            attempts.append(FFmpegAttempt(label + "-nosubs", output: args + ["-sn"]))
            if canCopyAllAudio && !audio.isEmpty {
                // A copied audio track can still be rejected (odd timestamps): re-encode it.
                attempts.append(FFmpegAttempt(label + "-reencode-audio", output: base + encoder + audioEncode + ["-sn"]))
            }
        }
        return attempts
    }

    typealias CodecRule = (String) -> Bool

    static func copyRules(for target: Format) -> (video: CodecRule, audio: CodecRule) {
        switch target {
        case .mp4: return ({ mp4Video.contains($0) }, { mp4Audio.contains($0) })
        case .mov: return ({ movVideo.contains($0) }, { movAudio.contains($0) })
        case .mkv: return ({ !mkvUnsupportedVideo.contains($0) }, { _ in true })
        case .webm: return ({ webmVideo.contains($0) }, { webmAudio.contains($0) })
        case .avi: return ({ aviVideo.contains($0) }, { aviAudio.contains($0) })
        case .wmv: return ({ wmvVideo.contains($0) }, { wmvAudio.contains($0) })
        default: return ({ _ in false }, { _ in false })
        }
    }

    /// Subtitle handling, or nil when subtitles are dropped for this target.
    static func subtitles(for target: Format, info: MediaInfo) -> [String]? {
        let subs = info.subtitles
        guard !subs.isEmpty else { return nil }
        switch target {
        case .mkv:
            if subs.allSatisfy({ mkvSubtitles.contains($0.codec) }) { return ["-map", "0:s?", "-c:s", "copy"] }
            if subs.allSatisfy({ textSubtitles.contains($0.codec) }) { return ["-map", "0:s?", "-c:s", "srt"] }
            return nil
        case .mp4, .mov:
            if subs.allSatisfy({ textSubtitles.contains($0.codec) }) { return ["-map", "0:s?", "-c:s", "mov_text"] }
            return nil
        case .webm:
            if subs.allSatisfy({ textSubtitles.contains($0.codec) }) { return ["-map", "0:s?", "-c:s", "webvtt"] }
            return nil
        default:
            return nil
        }
    }

    /// Video encoder choices in order of preference.
    static func videoEncoders(for target: Format, info: MediaInfo, settings: ConversionSettings) -> [(String, [String])] {
        let even = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p"]
        let bitrate = "\(estimatedBitrateKbps(info: info, quality: settings.videoQuality))k"
        switch target {
        case .mp4, .mov, .mkv:
            var list: [(String, [String])] = []
            let quality = "\(max(1, min(100, settings.videoQuality)))"
            if settings.hardwareEncoding {
                if settings.videoCodec == .hevc {
                    let tag = target == .mkv ? [] : ["-tag:v", "hvc1"]
                    list.append(("vt-hevc", ["-c:v", "hevc_videotoolbox", "-q:v", quality, "-allow_sw", "1"] + tag + even))
                    list.append(("vt-hevc-bitrate", ["-c:v", "hevc_videotoolbox", "-b:v", bitrate, "-allow_sw", "1"] + tag + even))
                }
                list.append(("vt-h264", ["-c:v", "h264_videotoolbox", "-q:v", quality, "-allow_sw", "1",
                                          "-profile:v", "high"] + even))
                list.append(("vt-h264-bitrate", ["-c:v", "h264_videotoolbox", "-b:v", bitrate, "-allow_sw", "1",
                                                  "-profile:v", "high"] + even))
            }
            // Software fallback (no hardware encoder available).
            let tag = target == .mkv ? [] : ["-tag:v", "mp4v"]
            list.append(("mpeg4", ["-c:v", "mpeg4", "-q:v", "3"] + tag + even))
            return list
        case .webm:
            return [("vp9", ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                             "-crf", "32", "-b:v", "0"] + even),
                    ("vp8", ["-c:v", "libvpx", "-crf", "10", "-b:v", bitrate] + even)]
        case .avi:
            return [("mpeg4", ["-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "3"] + even)]
        case .wmv:
            return [("wmv2", ["-c:v", "wmv2", "-q:v", "3"] + even)]
        default:
            return []
        }
    }

    /// Rough target bitrate when constant-quality encoding isn't available.
    static func estimatedBitrateKbps(info: MediaInfo, quality: Int) -> Int {
        let (w, h) = info.displaySize ?? (1280, 720)
        let fps = info.video?.frameRate ?? 30
        let bitsPerPixel = 0.04 + 0.12 * Double(max(1, min(100, quality))) / 100
        let kbps = Double(w * h) * min(fps, 60) * bitsPerPixel / 1000
        return max(300, min(60_000, Int(kbps)))
    }
}
