import AppKit
import AVFoundation
import ClementineCore
import SwiftUI

// MARK: Keyboard

/// Space, ←/→ (⇧ for a second), and editor-specific letters.
struct MediaKeys: ViewModifier {
    let session: MediaSession
    let letters: [Character: () -> Void]
    let playFrom: (() -> Double?)?
    @FocusState var focused: Bool

    init(session: MediaSession, letters: [Character: () -> Void] = [:], playFrom: (() -> Double?)? = nil) {
        self.session = session
        self.letters = letters
        self.playFrom = playFrom
    }

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(phases: [.down, .repeat]) { press in
                let shift = press.modifiers.contains(.shift)
                let perSecond = session.wantsVideo ? max(1, Int(session.frameRate.rounded())) : 10
                switch press.key {
                case .space:
                    session.togglePlay(from: playFrom?())
                    return .handled
                case .leftArrow:
                    session.step(shift ? -perSecond : -1)
                    return .handled
                case .rightArrow:
                    session.step(shift ? perSecond : 1)
                    return .handled
                default:
                    guard press.modifiers.isEmpty || press.modifiers == .shift,
                          let c = press.characters.lowercased().first, let action = letters[c] else { return .ignored }
                    action()
                    return .handled
                }
            }
    }
}

/// The video (or a waveform for audio) with the loading/error state on top.
struct MediaStage<Overlay: View>: View {
    @ObservedObject var session: MediaSession
    @ViewBuilder var overlay: (FitGeometry) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let fit = FitGeometry(imageSize: session.displaySize, viewSize: geo.size)
            ZStack(alignment: .topLeading) {
                if session.wantsVideo {
                    PlayerSurface(player: session.player, displaySize: session.displaySize)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Color.black.opacity(0.85)
                }
                if session.state == .ready {
                    overlay(fit)
                }
                MediaStatusView(session: session)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color.black.opacity(0.9))
    }
}

extension ToolUI {
    /// Media editors; returns false when the tool has none for this file.
    static func openMediaEditor(_ tool: Tool, item: InputItem) -> Bool {
        let video = item.kind == .video
        let size = video ? NSSize(width: 980, height: 720) : NSSize(width: 900, height: 520)
        let name = item.url.lastPathComponent
        let controller = EditorWindowController(title: "\(tool.displayName) — \(name)", size: size)
        let close: () -> Void = { [weak controller] in controller?.close() }
        switch tool {
        case .trim: controller.setContent(TrimEditor(item: item, close: close))
        case .crop where video: controller.setContent(VideoCropEditor(item: item, close: close))
        case .redact where video: controller.setContent(VideoRedactEditor(item: item, close: close))
        case .split where item.kind != .pdf: controller.setContent(SplitMediaEditor(item: item, close: close))
        case .snapshot where video: controller.setContent(SnapshotEditor(item: item, close: close))
        case .bleep: controller.setContent(BleepEditor(item: item, close: close))
        default: return false
        }
        controller.show()
        return true
    }
}

// MARK: Trim

struct TrimEditor: View {
    let item: InputItem
    let close: () -> Void
    @StateObject var session: MediaSession
    @State var range: ClosedRange<Double> = 0...0
    @AppStorage("tool.trim.precise") var precise = false
    @State var fadeIn = 0.0
    @State var fadeOut = 0.0
    @State var analysing = false

    init(item: InputItem, close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _session = StateObject(wrappedValue: MediaSession(item: item, video: item.kind == .video, waveform: item.kind == .audio))
    }

    private var isVideo: Bool { item.kind == .video }

    var body: some View {
        VStack(spacing: 0) {
            if isVideo {
                MediaStage(session: session) { _ in EmptyView() }
            }
            VStack(alignment: .leading, spacing: 10) {
                if !isVideo {
                    ZStack {
                        Timeline(session: session, selection: $range, height: 200)
                        MediaStatusView(session: session)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Timeline(session: session, selection: $range)
                }
                HStack(spacing: 14) {
                    TransportBar(session: session, playFrom: playStart)
                    Spacer()
                    TimeField(title: "In", value: inBinding, range: 0...max(0, session.duration))
                    TimeField(title: "Out", value: outBinding, range: 0...max(0, session.duration))
                    Button("Set In (I)") { setIn() }
                    Button("Set Out (O)") { setOut() }
                }
                HStack(spacing: 14) {
                    if isVideo {
                        Picker("", selection: $precise) {
                            Text("Fast (no re-encoding)").tag(false)
                            Text("Precise (frame-exact)").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 330)
                        .help("Fast cuts at the nearest keyframe without any quality loss. Precise re-encodes for frame-exact cuts.")
                    } else {
                        Button(analysing ? "Finding silence…" : "Trim Silence") { trimSilence() }
                            .disabled(analysing || session.state != .ready)
                    }
                    LabeledSlider(title: "Fade in", value: $fadeIn, range: 0...5).frame(width: 190)
                        .help("Sound fades in over this many seconds")
                    LabeledSlider(title: "Fade out", value: $fadeOut, range: 0...5).frame(width: 190)
                        .help("Sound fades out over this many seconds")
                    Spacer()
                }
            }
            .padding(12)
            EditorBottomBar(note: "Keeps \(MediaSession.clock(range.upperBound - range.lowerBound)) · Space plays, I / O set the ends",
                            action: "Trim", enabled: session.state == .ready && range.upperBound - range.lowerBound > 0.04,
                            cancel: close) {
                ToolUI.export(.trim, items: [item], options: .trim(TrimOptions(start: range.lowerBound, end: range.upperBound,
                                                                               precise: precise, fadeIn: fadeIn, fadeOut: fadeOut)))
                close()
            }
        }
        .modifier(MediaKeys(session: session, letters: ["i": setIn, "o": setOut], playFrom: playStart))
        .onChange(of: session.duration) { _, d in
            if range.upperBound <= 0 { range = 0...d }
        }
        .onChange(of: range) { _, r in session.playbackEnd = r.upperBound }
        .onDisappear { session.close() }
    }

    private func playStart() -> Double? {
        let t = session.currentTime
        return (t < range.lowerBound || t >= range.upperBound - 0.02) ? range.lowerBound : nil
    }

    private var inBinding: Binding<Double> {
        Binding(get: { range.lowerBound }, set: { v in range = min(v, range.upperBound - 0.05)...range.upperBound })
    }

    private var outBinding: Binding<Double> {
        Binding(get: { range.upperBound }, set: { v in range = range.lowerBound...max(v, range.lowerBound + 0.05) })
    }

    private func setIn() {
        let t = min(session.currentTime, range.upperBound - 0.05)
        range = max(0, t)...range.upperBound
    }

    private func setOut() {
        let t = max(session.currentTime, range.lowerBound + 0.05)
        range = range.lowerBound...min(session.duration, t)
    }

    private func trimSilence() {
        analysing = true
        Task {
            let silences = (try? await MediaAnalysis.silences(item.url)) ?? []
            let bounds = MediaAnalysis.trimmedBounds(duration: session.duration, silences: silences)
            range = bounds.start...bounds.end
            session.seek(to: bounds.start)
            analysing = false
        }
    }
}

// MARK: Video crop

struct VideoCropEditor: View {
    let item: InputItem
    let close: () -> Void
    @StateObject var session: MediaSession
    @State var crop: CGRect = .zero
    @State var aspect: CropAspect = .free

    init(item: InputItem, close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _session = StateObject(wrappedValue: MediaSession(item: item, video: true, waveform: false))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Aspect", selection: $aspect) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                .onChange(of: aspect) { _, new in
                    if let ratio = new.ratio(original: session.displaySize) {
                        crop = ImageCrop.centred(aspect: ratio, in: session.displaySize)
                    }
                }
                Spacer()
                PixelField(title: "X", value: field(\.origin.x))
                PixelField(title: "Y", value: field(\.origin.y))
                PixelField(title: "W", value: field(\.size.width))
                PixelField(title: "H", value: field(\.size.height))
                Button("Reset") { crop = CGRect(origin: .zero, size: session.displaySize) }
            }
            .padding(10)
            .disabled(session.state != .ready)
            MediaStage(session: session) { fit in
                if crop.width > 0 {
                    CropOverlay(crop: $crop, geometry: fit, aspect: aspect.ratio(original: session.displaySize))
                }
            }
            VStack(spacing: 10) {
                Timeline(session: session)
                HStack {
                    TransportBar(session: session)
                    Spacer()
                }
            }
            .padding(12)
            EditorBottomBar(note: "\(Int(crop.width)) × \(Int(crop.height)) px · sound is kept", action: "Crop",
                            enabled: session.state == .ready && crop.width >= 16 && crop.height >= 16, cancel: close) {
                ToolUI.export(.crop, items: [item], options: .crop(crop.integral))
                close()
            }
        }
        .modifier(MediaKeys(session: session))
        .onChange(of: session.displaySize) { _, size in
            if crop == .zero { crop = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.05, dy: size.height * 0.05) }
        }
        .onDisappear { session.close() }
    }

    private func field(_ key: WritableKeyPath<CGRect, CGFloat>) -> Binding<Int> {
        Binding(get: { Int(crop[keyPath: key].rounded()) }, set: { v in
            var r = crop
            r[keyPath: key] = CGFloat(max(0, v))
            let clipped = r.intersection(CGRect(origin: .zero, size: session.displaySize))
            if !clipped.isNull, clipped.width >= 1, clipped.height >= 1 { crop = clipped }
        })
    }
}

// MARK: Split (video / audio)

struct SplitMediaEditor: View {
    enum Mode: String, CaseIterable, Identifiable {
        case markers = "At markers", parts = "Equal parts", every = "Every"
        var id: String { rawValue }
    }

    let item: InputItem
    let close: () -> Void
    @StateObject var session: MediaSession
    @State var mode: Mode = .markers
    @State var markers: [Double] = []
    @AppStorage("tool.split.parts") var parts = 2
    @AppStorage("tool.split.seconds") var seconds = 60.0

    init(item: InputItem, markers: [Double] = [], close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _session = StateObject(wrappedValue: MediaSession(item: item, video: item.kind == .video, waveform: item.kind != .video))
        _markers = State(initialValue: markers)
    }

    private var options: SplitMediaOptions {
        switch mode {
        case .markers: return SplitMediaOptions(mode: .at(markers))
        case .parts: return SplitMediaOptions(mode: .parts(parts))
        case .every: return SplitMediaOptions(mode: .every(seconds: max(1, seconds)))
        }
    }

    private var segments: [(start: Double, duration: Double)] { options.segments(duration: session.duration) }

    var body: some View {
        VStack(spacing: 0) {
            if item.kind == .video {
                MediaStage(session: session) { _ in EmptyView() }
            }
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Timeline(session: session, markers: mode == .markers ? $markers : nil,
                             cuts: mode == .markers ? [] : segments.dropFirst().map { $0.start },
                             height: item.kind == .video ? 56 : 180)
                    MediaStatusView(session: session)
                }
                .frame(maxHeight: item.kind == .video ? 56 : .infinity)
                HStack(spacing: 14) {
                    TransportBar(session: session)
                    Spacer()
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 290)
                    switch mode {
                    case .markers:
                        Button("Add Marker (M)") { addMarker() }
                        Button("Clear") { markers.removeAll() }.disabled(markers.isEmpty)
                    case .parts:
                        Stepper("\(parts) parts", value: $parts, in: 2...100)
                    case .every:
                        HStack(spacing: 4) {
                            TextField("", value: $seconds, format: .number).frame(width: 60)
                            Text("seconds")
                        }
                    }
                }
            }
            .padding(12)
            EditorBottomBar(note: "\(segments.count) parts · cut without re-encoding, at the nearest keyframe",
                            action: "Split", enabled: session.state == .ready && segments.count > 1, cancel: close) {
                ToolUI.export(.split, items: [item], options: .splitMedia(options))
                close()
            }
        }
        .modifier(MediaKeys(session: session, letters: ["m": addMarker]))
        .onDisappear { session.close() }
    }

    private func addMarker() {
        mode = .markers
        let t = session.currentTime
        guard t > 0.05, t < session.duration - 0.05, !markers.contains(where: { abs($0 - t) < 0.05 }) else { return }
        markers.append(t)
        markers.sort()
    }
}

// MARK: Snapshot

struct SnapshotEditor: View {
    let item: InputItem
    let close: () -> Void
    @StateObject var session: MediaSession
    @State var saved = 0

    init(item: InputItem, close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _session = StateObject(wrappedValue: MediaSession(item: item, video: true, waveform: false))
    }

    var body: some View {
        VStack(spacing: 0) {
            MediaStage(session: session) { _ in EmptyView() }
            VStack(spacing: 10) {
                Timeline(session: session)
                HStack {
                    TransportBar(session: session)
                    Spacer()
                }
            }
            .padding(12)
            HStack {
                Text(saved == 0 ? "Pick a frame with ← →, then Save Frame (full resolution PNG)"
                     : "\(saved) frame\(saved == 1 ? "" : "s") saved next to the video")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
                Button("Save Frame") { capture() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.state != .ready)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .modifier(MediaKeys(session: session, letters: ["c": capture]))
        .onDisappear { session.close() }
    }

    private func capture() {
        session.pause()
        ToolUI.export(.snapshot, items: [item], options: .snapshot(session.currentTime))
        saved += 1
    }
}

// MARK: Video redact

@MainActor
final class VideoRedactModel: ObservableObject {
    @Published var regions: [Redaction] = []
    @Published var selected: UUID?
    @Published var style: Redaction.Style = .blur
    private var undoStack: [[Redaction]] = []

    func commit(_ new: [Redaction]) {
        undoStack.append(regions)
        regions = new
    }

    func undo() { if let last = undoStack.popLast() { regions = last } }
    var canUndo: Bool { !undoStack.isEmpty }

    func deleteSelected() {
        guard let selected else { return }
        commit(regions.filter { $0.id != selected })
        self.selected = nil
    }

    var selectedIndex: Int? { regions.firstIndex { $0.id == selected } }

    func updateSelected(_ change: (inout Redaction) -> Void) {
        guard let i = selectedIndex else { return }
        var list = regions
        change(&list[i])
        commit(list)
    }

    static func isActive(_ r: Redaction, at t: Double) -> Bool {
        t >= (r.start ?? 0) - 0.001 && t <= (r.end ?? .greatestFiniteMagnitude)
    }
}

/// Draws and edits regions over the video (display pixels, top-left origin).
final class VideoRegionCanvasView: NSView {
    weak var model: VideoRedactModel?
    var currentTime: Double = 0
    var displaySize: CGSize = .zero
    private var start: CGPoint?
    private var creating: CGRect?
    private var moving: (index: Int, original: CGRect, resize: Bool)?
    private var live: [Redaction]?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var fit: FitGeometry { FitGeometry(imageSize: displaySize, viewSize: bounds.size) }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        for region in live ?? model.regions {
            let v = fit.toView(region.rect)
            let active = VideoRedactModel.isActive(region, at: currentTime)
            let isSelected = region.id == model.selected
            if active {
                switch region.style {
                case .solid: region.color.nsColor.withAlphaComponent(0.85).setFill()
                case .blur, .pixelate: NSColor(white: 0.5, alpha: 0.45).setFill()
                }
                v.fill()
            }
            let path = NSBezierPath(rect: v)
            path.lineWidth = isSelected ? 2 : 1
            (isSelected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(active ? 0.8 : 0.35)).setStroke()
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.stroke()
            if isSelected {
                NSColor.controlAccentColor.setFill()
                NSRect(x: v.maxX - 5, y: v.maxY - 5, width: 10, height: 10).fill()
            }
            if region.style != .solid && active {
                let label = region.style == .blur ? "Blur" : "Pixelate"
                (label as NSString).draw(at: NSPoint(x: v.minX + 4, y: v.minY + 3),
                                         withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                          .foregroundColor: NSColor.white])
            }
        }
        if let creating {
            let path = NSBezierPath(rect: fit.toView(creating))
            path.lineWidth = 1.5
            NSColor.white.setStroke()
            path.stroke()
        }
    }

    private func point(_ e: NSEvent) -> CGPoint { fit.toImage(convert(e.locationInWindow, from: nil)) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model else { return }
        let p = point(event)
        start = p
        let handle = 12 / max(fit.scale, 0.01)
        if let i = model.regions.lastIndex(where: { $0.rect.insetBy(dx: -handle, dy: -handle).contains(p) }) {
            let r = model.regions[i].rect
            model.selected = model.regions[i].id
            moving = (i, r, abs(p.x - r.maxX) < handle && abs(p.y - r.maxY) < handle)
        } else {
            model.selected = nil
            creating = CGRect(origin: p, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let start else { return }
        let p = point(event)
        if let moving {
            var list = model.regions
            if moving.resize {
                list[moving.index].rect = CGRect(x: moving.original.minX, y: moving.original.minY,
                                                 width: max(8, p.x - moving.original.minX), height: max(8, p.y - moving.original.minY))
            } else {
                list[moving.index].rect = moving.original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            }
            live = list
        } else {
            creating = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        if let creating, creating.width > 6, creating.height > 6 {
            var region = Redaction(rect: creating, style: model.style)
            region.start = currentTime > 0.05 ? currentTime : nil
            model.commit(model.regions + [region])
            model.selected = region.id
        } else if let live {
            model.commit(live)
        }
        creating = nil
        live = nil
        moving = nil
        start = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            model?.deleteSelected()
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }
}

struct VideoRegionCanvas: NSViewRepresentable {
    @ObservedObject var model: VideoRedactModel
    let currentTime: Double
    let displaySize: CGSize

    func makeNSView(context: Context) -> VideoRegionCanvasView {
        let view = VideoRegionCanvasView()
        view.model = model
        return view
    }

    func updateNSView(_ view: VideoRegionCanvasView, context: Context) {
        _ = (model.regions.count, model.selected)
        view.currentTime = currentTime
        view.displaySize = displaySize
        view.needsDisplay = true
    }
}

struct VideoRedactEditor: View {
    let item: InputItem
    let close: () -> Void
    @StateObject var session: MediaSession
    @StateObject var model: VideoRedactModel

    init(item: InputItem, regions: [Redaction] = [], close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _session = StateObject(wrappedValue: MediaSession(item: item, video: true, waveform: false))
        let model = VideoRedactModel()
        model.regions = regions
        model.selected = regions.first?.id
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $model.style) {
                    Text("Blur").tag(Redaction.Style.blur)
                    Text("Pixelate").tag(Redaction.Style.pixelate)
                    Text("Solid").tag(Redaction.Style.solid)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                .onChange(of: model.style) { _, style in model.updateSelected { $0.style = style } }
                Divider().frame(height: 18)
                Button("Starts Here") { model.updateSelected { $0.start = session.currentTime } }
                Button("Ends Here") { model.updateSelected { $0.end = session.currentTime } }
                Button("Whole Video") { model.updateSelected { $0.start = nil; $0.end = nil } }
                Spacer()
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                    .disabled(model.selected == nil)
            }
            .disabled(session.state != .ready)
            .padding(10)
            MediaStage(session: session) { _ in
                VideoRegionCanvas(model: model, currentTime: session.currentTime, displaySize: session.displaySize)
            }
            VStack(spacing: 10) {
                Timeline(session: session, ranges: model.regions.map { r in
                    (range: (r.start ?? 0)...max(r.start ?? 0, r.end ?? session.duration), highlighted: r.id == model.selected)
                })
                HStack {
                    TransportBar(session: session)
                    Spacer()
                    if let i = model.selectedIndex {
                        let r = model.regions[i]
                        Text("Hidden \(MediaSession.clock(r.start ?? 0, precise: false)) – \(r.end.map { MediaSession.clock($0, precise: false) } ?? "end")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            EditorBottomBar(note: "Drag over the video to hide an area from the current time on · metadata is removed",
                            action: "Save", enabled: session.state == .ready && !model.regions.isEmpty, cancel: close) {
                ToolUI.export(.redact, items: [item], options: .redact(model.regions))
                close()
            }
        }
        .modifier(MediaKeys(session: session))
        .onDisappear { session.close() }
    }
}

// MARK: Bleep

struct BleepEditor: View {
    enum Sound: String, CaseIterable, Identifiable {
        case beep = "Beep", custom = "Tone", silence = "Silence"
        var id: String { rawValue }
    }

    let item: InputItem
    let close: () -> Void
    @StateObject var session: MediaSession
    @State var intervals: [ClosedRange<Double>] = []
    @State var selected: Int?
    @AppStorage("tool.bleep.sound") var sound: Sound = .beep
    @AppStorage("tool.bleep.frequency") var frequency = 1000.0
    @StateObject var previewer = AudioPreviewer()

    init(item: InputItem, intervals: [ClosedRange<Double>] = [], close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _session = StateObject(wrappedValue: MediaSession(item: item, video: false, waveform: true))
        _intervals = State(initialValue: intervals)
    }

    private var options: BleepOptions {
        let s: BleepOptions.Sound
        switch sound {
        case .beep: s = .tone(frequency: 1000)
        case .custom: s = .tone(frequency: frequency)
        case .silence: s = .silence
        }
        return BleepOptions(intervals: intervals, sound: s)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Timeline(session: session, intervals: $intervals, selectedInterval: $selected, height: 220)
                MediaStatusView(session: session)
            }
            .padding(12)
            .frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                TransportBar(session: session)
                Spacer()
                Picker("", selection: $sound) {
                    ForEach(Sound.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                if sound == .custom {
                    HStack(spacing: 4) {
                        TextField("", value: $frequency, format: .number).frame(width: 60)
                        Text("Hz")
                    }
                }
                Button(previewer.state == .idle ? "Preview" : previewer.state == .rendering ? "Preparing…" : "Stop") {
                    togglePreview()
                }
                .disabled(intervals.isEmpty || session.state != .ready || previewer.state == .rendering)
            }
            .padding(.horizontal, 12)
            if !intervals.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(intervals.enumerated()), id: \.offset) { index, r in
                            HStack(spacing: 6) {
                                Text("\(MediaSession.clock(r.lowerBound)) – \(MediaSession.clock(r.upperBound))")
                                    .font(.callout.monospacedDigit())
                                Button { remove(index) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red.opacity(selected == index ? 0.3 : 0.12)))
                            .onTapGesture {
                                selected = index
                                session.seek(to: r.lowerBound)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 34)
                .padding(.top, 8)
            }
            Spacer().frame(height: 10)
            EditorBottomBar(note: "Drag across the waveform to mark a part · Delete removes the selected part",
                            action: "Save", enabled: session.state == .ready && !intervals.isEmpty, cancel: close) {
                stopPreview()
                ToolUI.export(.bleep, items: [item], options: .bleep(options))
                close()
            }
        }
        .modifier(MediaKeys(session: session, letters: ["\u{7F}": deleteSelected, "\u{8}": deleteSelected]))
        .onChange(of: intervals) { _, _ in stopPreview() }
        .onDisappear {
            stopPreview()
            session.close()
        }
    }

    private func remove(_ index: Int) {
        guard intervals.indices.contains(index) else { return }
        intervals.remove(at: index)
        selected = nil
    }

    private func deleteSelected() {
        if let selected { remove(selected) }
    }

    private func togglePreview() {
        if previewer.state != .idle { stopPreview(); return }
        guard let first = options.merged(duration: session.duration).first else { return }
        session.pause()
        let options = self.options, source = item.url, settings = Preferences.conversionSettings()
        previewer.play(from: first.lowerBound - 1) { out in
            try await MediaEditing.bleep(source, format: .m4a, options: options, to: out, settings: settings) { _ in }
        }
    }

    private func stopPreview() {
        previewer.stop()
    }
}
