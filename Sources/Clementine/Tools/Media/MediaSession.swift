import AppKit
import AVFoundation
import ClementineCore
import SwiftUI

/// Playback and pictures for a media editor. Formats AVFoundation can't play
/// (MKV, WebM, OGG, WMA…) get a small ffmpeg preview copy first. Everything
/// is released in `close()` (the editor calls it when it disappears).
@MainActor
final class MediaSession: ObservableObject {
    enum State: Equatable {
        case loading(String)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .loading("Opening…")
    @Published private(set) var loadProgress: Double?
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    /// Displayed (rotation-applied) size of the original video, in pixels.
    @Published private(set) var displaySize: CGSize = .zero
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var waveform: CGImage?
    /// First frame, shown under the player until it draws.
    @Published private(set) var poster: CGImage?

    let item: InputItem
    let wantsVideo: Bool
    let wantsWaveform: Bool
    let player = AVPlayer()
    private(set) var frameRate: Double = 30
    private(set) var hasAudio = false
    /// Playback pauses here (Trim plays only the selection).
    var playbackEnd: Double?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var work: TempDirectory?
    private var loadTask: Task<Void, Never>?
    private var closed = false

    init(item: InputItem, video: Bool, waveform: Bool) {
        self.item = item
        self.wantsVideo = video
        self.wantsWaveform = waveform
        player.actionAtItemEnd = .pause
        loadTask = Task { await load() }
    }

    var frameDuration: Double { 1 / max(1, frameRate) }

    // MARK: Loading

    private func load() async {
        do {
            let work = try TempDirectory(prefix: "clementine-preview")
            self.work = work
            let info = try await MediaProbe.probe(item.url)
            guard !closed else { return }
            guard let total = info.duration, total > 0 else { throw JobFailure("This file's length is unknown.") }
            duration = total
            hasAudio = info.hasAudio
            if let size = info.displaySize { displaySize = CGSize(width: size.width, height: size.height) }
            frameRate = info.video?.frameRate ?? 30
            if wantsVideo && !info.hasVideo { throw JobFailure("This file has no video.") }
            if wantsWaveform && !info.hasAudio { throw JobFailure("This file has no sound.") }

            var playable = item.url
            if !(await Self.canPlay(item.url, video: wantsVideo)) {
                state = .loading("Preparing a preview…")
                let proxy = work.file(wantsVideo ? "preview.mp4" : "preview.m4a")
                try await MediaAnalysis.previewProxy(item.url, to: proxy, hasVideo: wantsVideo,
                                                     settings: Preferences.conversionSettings()) { p in
                    Task { @MainActor [weak self] in self?.loadProgress = p }
                }
                playable = proxy
            }
            guard !closed else { return }
            let asset = AVURLAsset(url: playable)
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            observePlayback()
            loadProgress = nil
            state = .ready
            if wantsWaveform {
                let png = work.file("wave.png")
                try? await MediaAnalysis.waveform(item.url, to: png, width: 1600, height: 200)
                if !closed { waveform = try? ImageCodec.decode(png, format: .png).image }
            }
            if wantsVideo {
                poster = await Self.frame(of: asset, at: 0, maxSize: 1600)
                await makeThumbnails(asset)
            }
        } catch {
            if !closed { state = .failed(JobFailure.from(error).message) }
        }
    }

    static func canPlay(_ url: URL, video: Bool) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        let tracks = (try? await asset.loadTracks(withMediaType: video ? .video : .audio)) ?? []
        return !tracks.isEmpty
    }

    static func frame(of asset: AVURLAsset, at seconds: Double, maxSize: CGFloat) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    private func makeThumbnails(_ asset: AVURLAsset) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let count = 12
        var images: [CGImage] = []
        for i in 0..<count {
            guard !closed else { return }
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let frame = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                images.append(frame.image)
                thumbnails = images
            }
        }
    }

    private func observePlayback() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                if self.isPlaying, let end = self.playbackEnd, self.currentTime >= end {
                    self.pause()
                    self.seek(to: end)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    // MARK: Transport

    func togglePlay(from start: Double? = nil) {
        if isPlaying { pause() } else { play(from: start) }
    }

    func play(from start: Double? = nil) {
        guard state == .ready else { return }
        if let start, abs(start - currentTime) > 0.01 { seek(to: start) }
        if let end = playbackEnd, currentTime >= end - 0.02 { seek(to: start ?? 0) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Exact (frame-accurate) seek.
    func seek(to time: Double) {
        let t = max(0, min(duration, time))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Moves by whole frames (video) or tenths of a second (audio).
    func step(_ count: Int) {
        pause()
        if wantsVideo, let item = player.currentItem, item.canStepForward || count < 0 {
            item.step(byCount: count)
            currentTime = max(0, min(duration, currentTime + Double(count) * frameDuration))
        } else {
            seek(to: currentTime + Double(count) * (wantsVideo ? frameDuration : 0.1))
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        loadTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        thumbnails = []
        waveform = nil
        poster = nil
        work?.remove()
        work = nil
    }

    static func clock(_ t: Double, precise: Bool = true) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return precise ? base + String(format: ".%03d", f) : base
    }

    /// Parses "1:02.5", "62.5", "1:00:02" into seconds.
    static func parseClock(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

/// Shows the player's video, scaled to fit with the same geometry the
/// overlays use (`FitGeometry`).
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let displaySize: CGSize

    func makeNSView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.playerLayer.player = player
        view.displaySize = displaySize
        return view
    }

    func updateNSView(_ view: PlayerSurfaceView, context: Context) {
        if view.displaySize != displaySize {
            view.displaySize = displaySize
            view.needsLayout = true
        }
    }

    static func dismantleNSView(_ view: PlayerSurfaceView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerSurfaceView: NSView {
    let playerLayer = AVPlayerLayer()
    var displaySize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resize
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = FitGeometry(imageSize: displaySize, viewSize: bounds.size).rect
        CATransaction.commit()
    }
}

/// Loading / error placeholder shared by the media editors.
struct MediaStatusView: View {
    @ObservedObject var session: MediaSession

    var body: some View {
        switch session.state {
        case .ready:
            EmptyView()
        case .loading(let text):
            VStack(spacing: 10) {
                if let p = session.loadProgress {
                    ProgressView(value: p).frame(width: 220)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(text).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .padding(30)
        }
    }
}

/// Play/pause, frame stepping and the clock.
struct TransportBar: View {
    @ObservedObject var session: MediaSession
    var playFrom: (() -> Double?)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button { session.step(session.wantsVideo ? -1 : -10) } label: { Image(systemName: "backward.frame").accessibilityLabel("Back") }
                .help(session.wantsVideo ? "Previous frame (←)" : "Back 1 s (←)")
            Button { session.togglePlay(from: playFrom?()) } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .help("Play / pause (space)")
            Button { session.step(session.wantsVideo ? 1 : 10) } label: { Image(systemName: "forward.frame").accessibilityLabel("Forward") }
                .help(session.wantsVideo ? "Next frame (→)" : "Forward 1 s (→)")
            Text("\(MediaSession.clock(session.currentTime)) / \(MediaSession.clock(session.duration, precise: false))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
        .disabled(session.state != .ready)
    }
}

/// A time text field (m:ss.mmm) bound to seconds.
struct TimeField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State var text = ""
    @FocusState var focused: Bool

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: $text)
                .font(.callout.monospacedDigit())
                .frame(width: 84)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
        .onAppear { text = MediaSession.clock(value) }
        .onChange(of: value) { _, v in if !focused { text = MediaSession.clock(v) } }
    }

    private func commit() {
        if let v = MediaSession.parseClock(text) { value = min(max(v, range.lowerBound), range.upperBound) }
        text = MediaSession.clock(value)
    }
}
