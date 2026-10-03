import Foundation

/// ffmpeg work for the media editors: trim, video crop, frame snapshots,
/// video redaction, bleeps and the audio visualizer. Argument builders are
/// pure functions (unit-tested on any platform); the `run` functions execute
/// them.
public enum MediaEditing {
    static let videoContainers: [Format] = [.mp4, .mov, .mkv, .webm, .avi, .wmv]

    static func seconds(_ t: Double) -> String { String(format: "%.3f", max(0, t)) }

    // MARK: Trim

    public static func trimAttempts(info: MediaInfo, format: Format, options: TrimOptions,
                                    settings: ConversionSettings) throws -> [FFmpegAttempt] {
        let total = info.duration ?? options.end
        let start = max(0, min(options.start, total))
        let end = min(options.end, total)
        guard end - start >= 0.04 else { throw JobFailure("Choose a longer section to keep.") }
        let length = end - start
        let seek = ["-ss", seconds(start)]
        var fades: [String] = []
        if options.fadeIn > 0 { fades.append("afade=t=in:st=0:d=\(seconds(min(options.fadeIn, length)))") }
        if options.fadeOut > 0 {
            let d = min(options.fadeOut, length)
            fades.append("afade=t=out:st=\(seconds(length - d)):d=\(seconds(d))")
        }
        let fadeArgs = fades.isEmpty ? [] : ["-af", fades.joined(separator: ",")]

        if info.hasVideo && format.kind == .video {
            let target: Format = videoContainers.contains(format) ? format : .mp4
            let faststart = [.mp4, .mov].contains(target) ? ["-movflags", "+faststart"] : []
            let audioEncode = info.hasAudio ? MediaPlanner.audioEncoder(for: target, stream: info.audio.first, settings: settings) : []
            var attempts: [FFmpegAttempt] = []
            if !options.precise {
                let audio = info.hasAudio ? (options.hasFades ? audioEncode + fadeArgs : ["-c:a", "copy"]) : []
                let copy = ["-t", seconds(length), "-map", "0:V", "-map", "0:a?", "-c:v", "copy"] + audio +
                    ["-avoid_negative_ts", "make_zero", "-map_metadata", "0"] + faststart
                attempts.append(FFmpegAttempt("copy", input: seek, output: copy + ["-map", "0:s?", "-c:s", "copy"]))
                attempts.append(FFmpegAttempt("copy-nosubs", input: seek, output: copy + ["-sn"]))
            }
            let audio = info.hasAudio ? audioEncode + fadeArgs : []
            for (label, encoder) in MediaPlanner.videoEncoders(for: target, info: info, settings: settings) {
                attempts.append(FFmpegAttempt(label, input: seek, output: ["-t", seconds(length), "-map", "0:V:0", "-map", "0:a?",
                                                                            "-map_metadata", "0", "-sn", "-dn"] +
                                              encoder + audio + faststart))
            }
            return attempts
        }

        guard info.hasAudio else { throw JobFailure("This file has no sound to trim.") }
        let target = ConversionMatrix.audioTargets.contains(format) ? format : .m4a
        let encode = MediaPlanner.audioEncoder(for: target, stream: info.audio.first, settings: settings)
        let keepCover = info.coverArt != nil && [.mp3, .m4a, .flac].contains(target)
        let cover = keepCover ? ["-map", "0:v:0", "-c:v", "copy", "-disposition:v:0", "attached_pic"] : ["-vn"]
        let common = ["-t", seconds(length), "-map", "0:a:0"]
        var attempts: [FFmpegAttempt] = []
        if !options.precise && !options.hasFades && MediaPlanner.canCopyAudio(info.audio[0].codec, into: target) {
            attempts.append(FFmpegAttempt("copy", input: seek, output: common + cover + ["-c:a", "copy", "-map_metadata", "0"]))
            if keepCover {
                attempts.append(FFmpegAttempt("copy-nocover", input: seek, output: common + ["-vn", "-c:a", "copy", "-map_metadata", "0"]))
            }
        }
        attempts.append(FFmpegAttempt("encode", input: seek, output: common + cover + encode + fadeArgs + ["-map_metadata", "0"]))
        if keepCover {
            attempts.append(FFmpegAttempt("encode-nocover", input: seek, output: common + ["-vn"] + encode + fadeArgs +
                                          ["-map_metadata", "0"]))
        }
        return attempts
    }

    public static func trim(_ input: URL, format: Format, options: TrimOptions, to output: URL, settings: ConversionSettings,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await MediaProbe.probe(input)
        let attempts = try trimAttempts(info: info, format: format, options: options, settings: settings)
        try await MediaEngine.run(attempts, input: input, output: output, duration: options.duration,
                                  failure: "Couldn't trim the file.", progress: progress)
    }

    // MARK: Video crop

    /// `crop=w:h:x:y` for a top-left-origin rect in displayed pixels, clamped
    /// and rounded to even numbers (4:2:0 video needs them).
    public static func cropFilter(_ rect: CGRect, displaySize: (width: Int, height: Int)) throws -> String {
        let bounds = CGRect(x: 0, y: 0, width: displaySize.width, height: displaySize.height)
        let r = rect.intersection(bounds)
        guard !r.isNull else { throw JobFailure("The crop area is outside the video.") }
        func even(_ v: CGFloat) -> Int { Int(v) - Int(v) % 2 }
        let x = even(r.minX), y = even(r.minY)
        let w = min(even(r.width), displaySize.width - x - (displaySize.width - x) % 2)
        let h = min(even(r.height), displaySize.height - y - (displaySize.height - y) % 2)
        guard w >= 16, h >= 16 else { throw JobFailure("The crop area is too small.") }
        return "crop=\(w):\(h):\(x):\(y)"
    }

    public static func cropVideo(_ input: URL, format: Format, rect: CGRect, to output: URL, settings: ConversionSettings,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await MediaProbe.probe(input)
        guard let size = info.displaySize else { throw JobFailure("This file has no video.") }
        let filter = try cropFilter(rect, displaySize: size)
        let attempts = MediaTools.reencodeAttempts(format: format, info: info,
                                                   filters: [filter, "scale=trunc(iw/2)*2:trunc(ih/2)*2"], settings: settings)
        try await MediaEngine.run(attempts, input: input, output: output, duration: info.duration,
                                  failure: "Couldn't crop the video.", progress: progress)
    }

    // MARK: Snapshot

    /// "clip 00-01-23.456" for a frame at 83.456 s.
    public static func snapshotName(base: String, time: Double) -> String {
        let ms = Int((max(0, time) * 1000).rounded())
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        return base + " " + String(format: "%02d-%02d-%02d.%03d", h, m, s, f)
    }

    public static func snapshotAttempts(time: Double) -> [FFmpegAttempt] {
        let image = ["-map", "0:V:0", "-an", "-sn", "-update", "1", "-f", "image2", "-c:v", "png", "-pix_fmt", "rgb24"]
        // A hair before the frame's own timestamp, so rounding never skips to
        // the next frame.
        return [
            FFmpegAttempt("frame", input: ["-ss", String(format: "%.6f", max(0, time - 0.0005))],
                          output: ["-frames:v", "1"] + image),
            // Past the last frame: keep overwriting until the end; the last one stays.
            FFmpegAttempt("last-frame", input: ["-sseof", "-1"], output: image),
        ]
    }

    public static func snapshot(_ input: URL, at time: Double, to output: URL) async throws {
        try await MediaEngine.run(snapshotAttempts(time: time), input: input, output: output, duration: nil,
                                  failure: "Couldn't save that frame.")
    }

    // MARK: Video redaction

    /// A filter graph hiding each region (in displayed pixels) during its
    /// time range; ends in `[v]`.
    public static func redactGraph(_ regions: [Redaction], displaySize: (width: Int, height: Int)) -> String? {
        let bounds = CGRect(x: 0, y: 0, width: displaySize.width, height: displaySize.height)
        func even(_ v: Int) -> Int { max(2, v - v % 2) }
        var chain: [String] = []
        var label = "[0:V:0]"
        var index = 0
        for region in regions {
            let r = region.rect.intersection(bounds)
            guard !r.isNull, r.width >= 4, r.height >= 4 else { continue }
            let x = Int(r.minX), y = Int(r.minY)
            let w = even(min(Int(r.width), displaySize.width - x)), h = even(min(Int(r.height), displaySize.height - y))
            var enable = ""
            if region.start != nil || region.end != nil {
                let s = region.start ?? 0, e = region.end ?? 1e9
                enable = ":enable='between(t,\(seconds(s)),\(e >= 1e9 ? "1e9" : seconds(e)))'"
            }
            let out = "[r\(index)]"
            switch region.style {
            case .solid:
                chain.append("\(label)drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=\(region.color.ffmpegHex)@1:t=fill\(enable)\(out)")
            case .blur, .pixelate:
                let effect: String
                if region.style == .pixelate {
                    let block = max(8, min(w, h) / 10)
                    effect = "scale=\(even(max(2, w / block))):\(even(max(2, h / block))):flags=area," +
                        "scale=\(w):\(h):flags=neighbor"
                } else {
                    // Pixelate first so the blur can't be undone, then soften.
                    effect = "scale=\(even(max(2, w / 6))):\(even(max(2, h / 6))):flags=area,scale=\(w):\(h):flags=bicubic," +
                        "gblur=sigma=\(max(4, min(w, h) / 10))"
                }
                chain.append("\(label)split=2[k\(index)][s\(index)]")
                chain.append("[s\(index)]crop=\(w):\(h):\(x):\(y),\(effect)[f\(index)]")
                chain.append("[k\(index)][f\(index)]overlay=x=\(x):y=\(y)\(enable)\(out)")
            }
            label = out
            index += 1
        }
        guard index > 0 else { return nil }
        chain.append("\(label)scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p[v]")
        return chain.joined(separator: ";")
    }

    /// Re-encode with a filter graph that outputs `[v]`; audio is copied when
    /// the container allows it.
    static func graphAttempts(format: Format, info: MediaInfo, graph: String, settings: ConversionSettings,
                              keepMetadata: Bool) -> [FFmpegAttempt] {
        let target: Format = videoContainers.contains(format) ? format : .mp4
        let metadata = keepMetadata ? ["-map_metadata", "0"] : ["-map_metadata", "-1", "-map_chapters", "-1"]
        let base = ["-filter_complex", graph, "-map", "[v]", "-map", "0:a?"] + metadata + ["-sn", "-dn"] +
            ([.mp4, .mov].contains(target) ? ["-movflags", "+faststart"] : [])
        let audioCopy = MediaPlanner.copyRules(for: target).audio
        let audio = info.audio.allSatisfy { audioCopy($0.codec) } ? ["-c:a", "copy"]
            : MediaPlanner.audioEncoder(for: target, stream: info.audio.first, settings: settings)
        return MediaPlanner.videoEncoders(for: target, info: info, settings: settings).map { label, encoder in
            FFmpegAttempt(label, output: base + MediaTools.removingOption("-vf", from: encoder) + audio)
        }
    }

    public static func redactVideo(_ input: URL, format: Format, regions: [Redaction], to output: URL,
                                   settings: ConversionSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await MediaProbe.probe(input)
        guard let size = info.displaySize else { throw JobFailure("This file has no video.") }
        guard let graph = redactGraph(regions, displaySize: size) else { throw JobFailure("Draw at least one area to hide.") }
        try await MediaEngine.run(graphAttempts(format: format, info: info, graph: graph, settings: settings, keepMetadata: false),
                                  input: input, output: output, duration: info.duration,
                                  failure: "Couldn't redact the video.", progress: progress)
    }

    // MARK: Bleep

    /// Audio graph ending in `[a]`: the intervals are muted and, for a tone,
    /// a sine wave plays instead.
    public static func bleepGraph(_ options: BleepOptions, duration: Double?, channels: Int, sampleRate: Int) -> String? {
        let intervals = options.merged(duration: duration)
        guard !intervals.isEmpty else { return nil }
        let expr = intervals.map { "between(t,\(seconds($0.lowerBound)),\(seconds($0.upperBound)))" }.joined(separator: "+")
        switch options.sound {
        case .silence:
            return "[0:a:0]volume=volume=0:enable='\(expr)'[a]"
        case .tone(let frequency):
            let layout = channels == 1 ? "mono" : "stereo"
            let rate = min(max(sampleRate, 8000), 48_000)
            let length = (duration ?? intervals.last!.upperBound) + 1
            let format = "aformat=sample_fmts=fltp:sample_rates=\(rate):channel_layouts=\(layout)"
            let f = Int(max(100, min(8000, frequency)).rounded())
            // ffmpeg's sine source plays at 1/8 of full scale, hence the 8×.
            return "[0:a:0]\(format),volume=volume=0:enable='\(expr)'[m];" +
                "sine=frequency=\(f):sample_rate=\(rate):duration=\(seconds(length)),\(format)," +
                "volume=volume=0:enable='not(\(expr))',volume=\(String(format: "%.3f", 8 * max(0, min(1, options.level))))[t];" +
                "[m][t]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]"
        }
    }

    public static func bleepAttempts(info: MediaInfo, format: Format, options: BleepOptions,
                                     settings: ConversionSettings) throws -> [FFmpegAttempt] {
        guard let stream = info.audio.first else { throw JobFailure("This file has no sound.") }
        guard let graph = bleepGraph(options, duration: info.duration, channels: stream.channels ?? 2,
                                     sampleRate: stream.sampleRate ?? 48_000) else {
            throw JobFailure("Mark at least one part to bleep.")
        }
        if info.hasVideo && format.kind == .video {
            let target: Format = videoContainers.contains(format) ? format : .mp4
            let audio = removingChannels(MediaPlanner.audioEncoder(for: target, stream: stream, settings: settings))
            let base = ["-filter_complex", graph, "-map", "0:V", "-map", "[a]", "-c:v", "copy"] + audio +
                ["-map_metadata", "0", "-sn", "-dn"] + ([.mp4, .mov].contains(target) ? ["-movflags", "+faststart"] : [])
            return [FFmpegAttempt("video", output: base)]
        }
        let target = ConversionMatrix.audioTargets.contains(format) ? format : .m4a
        let audio = removingChannels(MediaPlanner.audioEncoder(for: target, stream: stream, settings: settings))
        return [FFmpegAttempt("audio", output: ["-filter_complex", graph, "-map", "[a]", "-vn", "-map_metadata", "0"] + audio)]
    }

    /// The bleep graph fixes the layout itself.
    static func removingChannels(_ args: [String]) -> [String] { MediaTools.removingOption("-ac", from: args) }

    public static func bleep(_ input: URL, format: Format, options: BleepOptions, to output: URL, settings: ConversionSettings,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await MediaProbe.probe(input)
        try await MediaEngine.run(try bleepAttempts(info: info, format: format, options: options, settings: settings),
                                  input: input, output: output, duration: info.duration,
                                  failure: "Couldn't add the bleeps.", progress: progress)
    }

    // MARK: Visualizer

    /// Filter graph for the visualizer. Inputs: 0 = background picture (one
    /// frame, looped in memory), 1 = audio, 2 (optional) = title layer (one
    /// frame, repeated by overlay), then the circle style's two remap tables.
    /// Ends in `[v]`.
    public static func visualizerGraph(_ options: VisualizerOptions, hasOverlay: Bool) -> String {
        let (W, H) = options.shape.size
        let color = options.color.ffmpegHex
        func even(_ v: Int) -> Int { v - v % 2 }
        // showwaves/showfreqs draw on a transparent canvas.
        var chain = ["[0:v]loop=loop=-1:size=1:start=0[back]"]
        switch options.style {
        case .waveform:
            chain.append("[1:a:0]aformat=channel_layouts=mono,showwaves=s=\(W)x\(even(H / 3)):mode=cline:rate=30:colors=\(color)" +
                         ":scale=sqrt:draw=full,format=rgba[viz]")
            chain.append("[back][viz]overlay=x=(W-w)/2:y=(H-h)/2:shortest=1[bg]")
        case .bars:
            chain.append("[1:a:0]aformat=channel_layouts=mono,showfreqs=s=\(even(W * 4 / 5))x\(even(H * 2 / 5)):mode=bar" +
                         ":ascale=log:fscale=log:win_size=2048:rate=30:colors=\(color),format=rgba[viz]")
            chain.append("[back][viz]overlay=x=(W-w)/2:y=H-h-H/8:shortest=1[bg]")
        case .circle:
            let side = circleSide(options.shape)
            let input = hasOverlay ? 3 : 2
            chain.append("[1:a:0]aformat=channel_layouts=mono,showwaves=s=\(circleSource.width)x\(circleSource.height)" +
                         ":mode=cline:rate=30:colors=\(color):scale=sqrt:draw=full,format=rgba,pad=w=iw:h=ih+2:color=black@0[wave]")
            chain.append("[wave][\(input):v][\(input + 1):v]remap,format=rgba[viz]")
            chain.append("[back][viz]overlay=x=(W-\(side))/2:y=(H-\(side))/2:shortest=1[bg]")
        case .spectrogram:
            // Drawn narrow and scaled up so it scrolls across in seconds, not
            // minutes; its black floor is keyed out to show the background.
            let h = even(H * 11 / 20)
            chain.append("[1:a:0]showspectrum=s=\(even(W / 3))x\(even(h / 2)):mode=combined:slide=scroll:fscale=log" +
                         ":color=fire:scale=cbrt:legend=0:fps=30,scale=\(W):\(h):flags=bicubic,format=rgba," +
                         "colorkey=0x000000:0.12:0.25[viz]")
            chain.append("[back][viz]overlay=x=0:y=H-h:shortest=1[bg]")
        }
        if hasOverlay {
            // The title layer is one frame; overlay repeats it to the end.
            chain.append("[bg][2:v]overlay=x=0:y=0:eof_action=repeat[top]")
            chain.append("[top]fps=30,format=yuv420p[v]")
        } else {
            chain.append("[bg]fps=30,format=yuv420p[v]")
        }
        return chain.joined(separator: ";")
    }

    /// The waveform strip that the circle style bends into a ring.
    public static let circleSource = (width: 1440, height: 240)

    public static func circleSide(_ shape: VisualizerOptions.Shape) -> Int {
        let (W, H) = shape.size
        let side = min(W, H) * 7 / 10
        return side - side % 2
    }

    /// Remap tables (16-bit binary PGM) bending the waveform strip into a
    /// ring: x follows the angle, y the radius. Pixels off the ring point
    /// below the strip, into the transparent padding row.
    public static func circleMaps(side: Int) -> (x: Data, y: Data) {
        let src = circleSource
        let c = Double(side) / 2
        let inner = c * 0.42, outer = c * 0.98
        let offRing = UInt16(src.height + 1) // the padded transparent row
        var xs = Data(capacity: side * side * 2), ys = Data(capacity: side * side * 2)
        func put(_ v: UInt16, _ data: inout Data) {
            data.append(UInt8(v >> 8))
            data.append(UInt8(v & 0xFF))
        }
        for row in 0..<side {
            for col in 0..<side {
                let dx = Double(col) + 0.5 - c, dy = Double(row) + 0.5 - c
                let r = (dx * dx + dy * dy).squareRoot()
                if r < inner || r > outer {
                    put(0, &xs)
                    put(offRing, &ys)
                    continue
                }
                // Start at 12 o'clock, clockwise.
                var angle = atan2(dx, -dy) / (2 * Double.pi)
                if angle < 0 { angle += 1 }
                let sx = UInt16(min(Double(src.width - 1), angle * Double(src.width - 1)))
                let sy = UInt16(min(Double(src.height - 1), (r - inner) / (outer - inner) * Double(src.height - 1)))
                put(sx, &xs)
                put(sy, &ys)
            }
        }
        let header = Data("P5\n\(side) \(side)\n65535\n".utf8)
        return (header + xs, header + ys)
    }

    /// Runs the visualizer once the pictures exist (they're drawn by the
    /// platform layer: `VisualizerArt`).
    public static func visualize(audio: URL, background: URL, overlay: URL?, options: VisualizerOptions, duration: Double,
                                 workDirectory: URL, to output: URL, settings: ConversionSettings,
                                 progress: @escaping @Sendable (Double) -> Void) async throws {
        var inputs = ["-framerate", "30", "-i", MediaEngine.ffmpegPath(background), "-i", MediaEngine.ffmpegPath(audio)]
        if let overlay { inputs += ["-framerate", "30", "-i", MediaEngine.ffmpegPath(overlay)] }
        if options.style == .circle {
            let maps = circleMaps(side: circleSide(options.shape))
            let xmap = workDirectory.appendingPathComponent("xmap.pgm"), ymap = workDirectory.appendingPathComponent("ymap.pgm")
            try maps.x.write(to: xmap)
            try maps.y.write(to: ymap)
            inputs += ["-loop", "1", "-framerate", "30", "-i", MediaEngine.ffmpegPath(xmap),
                       "-loop", "1", "-framerate", "30", "-i", MediaEngine.ffmpegPath(ymap)]
        }
        let graph = visualizerGraph(options, hasOverlay: overlay != nil)
        let common = ["-filter_complex", graph, "-map", "[v]", "-map", "1:a:0", "-t", seconds(duration),
                      "-c:a", "aac_at", "-b:a", "192k", "-movflags", "+faststart"]
        var encoders: [[String]] = []
        if settings.hardwareEncoding {
            encoders.append(["-c:v", "h264_videotoolbox", "-b:v", "6M", "-allow_sw", "1", "-profile:v", "high"])
        }
        encoders.append(["-c:v", "mpeg4", "-q:v", "4", "-tag:v", "mp4v"])
        var lastError: Error = JobFailure("Couldn't make the video.")
        for encoder in encoders {
            do {
                try await FFmpegRunner.run(inputs + common + encoder + [MediaEngine.ffmpegPath(output)], duration: duration,
                                           failure: "Couldn't make the video.", progress: progress)
                if (MediaTools.fileSize(output) ?? 0) > 0 { return }
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }
}

/// Measurements the media editors need (waveform pictures, silence).
public enum MediaAnalysis {
    /// A white-on-transparent waveform picture of the whole file.
    public static func waveform(_ input: URL, to output: URL, width: Int = 1600, height: Int = 200) async throws {
        try await MediaEngine.run([FFmpegAttempt("wave", output: [
            "-filter_complex", "[0:a:0]aformat=channel_layouts=mono,showwavespic=s=\(width)x\(height):colors=white:scale=sqrt",
            "-frames:v", "1", "-update", "1", "-f", "image2", "-c:v", "png",
        ])], input: input, output: output, duration: nil, failure: "Couldn't draw the waveform.")
    }

    /// Silent stretches (seconds) quieter than `threshold` dB for at least
    /// `minimum` seconds.
    public static func silences(_ input: URL, threshold: Double = -45, minimum: Double = 0.4) async throws -> [ClosedRange<Double>] {
        guard let ffmpeg = FFmpegLocator.ffmpeg else { throw JobFailure("ffmpeg is missing.") }
        let result = try await ProcessRunner.run(ffmpeg, ["-nostdin", "-hide_banner", "-nostats", "-i", MediaEngine.ffmpegPath(input),
                                                          "-map", "0:a:0", "-af",
                                                          "silencedetect=noise=\(Int(threshold))dB:d=\(minimum)",
                                                          "-f", "null", "-"])
        guard result.status == 0 else {
            throw JobFailure("Couldn't analyse the sound.", details: ProcessRunner.tail(result.stderrString))
        }
        return parseSilences(result.stderrString)
    }

    /// Parses silencedetect's "silence_start: x" / "silence_end: y" lines.
    public static func parseSilences(_ log: String) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var open: Double?
        func number(after key: String, in line: Substring) -> Double? {
            guard let r = line.range(of: key) else { return nil }
            let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return Double(rest.prefix { "0123456789.-".contains($0) })
        }
        for line in log.split(separator: "\n") {
            if let s = number(after: "silence_start:", in: line) {
                open = max(0, s)
            } else if let e = number(after: "silence_end:", in: line) {
                let s = open ?? 0
                if e > s { ranges.append(s...e) }
                open = nil
            }
        }
        if let s = open { ranges.append(s...Double.greatestFiniteMagnitude) }
        return ranges
    }

    /// In/out points that drop leading and trailing silence.
    public static func trimmedBounds(duration: Double, silences: [ClosedRange<Double>]) -> (start: Double, end: Double) {
        var start = 0.0, end = duration
        if let first = silences.first, first.lowerBound <= 0.05 { start = min(first.upperBound, duration) }
        if let last = silences.last, last.upperBound >= duration - 0.05, last.lowerBound > start { end = last.lowerBound }
        if end - start < 0.1 { return (0, duration) }
        return (max(0, start - 0.05), min(duration, end + 0.05))
    }

    /// A small H.264/AAC (or AAC-only) copy that AVFoundation can always
    /// play, for previewing formats it can't open.
    public static func previewProxy(_ input: URL, to output: URL, hasVideo: Bool, settings: ConversionSettings,
                                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await MediaProbe.probe(input)
        var attempts: [FFmpegAttempt] = []
        let audio = info.hasAudio ? ["-map", "0:a:0", "-c:a", "aac_at", "-b:a", "160k", "-ac", "2"] : []
        if hasVideo && info.hasVideo {
            let vf = ["-vf", "scale=-2:'min(720,ih)':flags=bilinear,scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p"]
            if settings.hardwareEncoding {
                attempts.append(FFmpegAttempt("vt", output: ["-map", "0:V:0", "-c:v", "h264_videotoolbox", "-b:v", "3M",
                                                              "-allow_sw", "1", "-g", "15"] + vf + audio + ["-sn", "-dn"]))
            }
            attempts.append(FFmpegAttempt("mpeg4", output: ["-map", "0:V:0", "-c:v", "mpeg4", "-q:v", "5", "-g", "15"] + vf +
                                          audio + ["-sn", "-dn"]))
        } else {
            guard info.hasAudio else { throw JobFailure("This file has no sound.") }
            attempts.append(FFmpegAttempt("audio", output: ["-vn"] + audio))
        }
        try await MediaEngine.run(attempts, input: input, output: output, duration: info.duration,
                                  failure: "Couldn't prepare a preview.", progress: progress)
    }
}
