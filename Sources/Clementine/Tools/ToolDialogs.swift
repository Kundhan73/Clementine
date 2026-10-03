import AppKit
import ClementineCore
import ImageIO
import SwiftUI

/// Opens dialogs and editors for tools that take options. Tools not handled
/// here run instantly with defaults.
@MainActor
enum ToolUI {
    static let dialogTools: Set<Tool> = [.compress, .resize, .rotate, .createPDF, .speed, .split, .join,
                                         .extractAudio, .normalize, .channels, .visualizer]
    static let editorTools: Set<Tool> = [.crop, .adjust, .annotate, .redact, .background, .collage,
                                         .metadata, .organizePDF, .trim, .snapshot, .bleep]
    /// Tools with a player-based editor for a single video or audio file.
    static let mediaEditorTools: Set<Tool> = [.trim, .crop, .redact, .split, .snapshot, .bleep]

    static func handles(_ tool: Tool) -> Bool { dialogTools.contains(tool) || editorTools.contains(tool) }

    static func open(_ tool: Tool, items: [InputItem]) {
        if items.count == 1, let first = items.first, first.kind == .video || first.kind == .audio,
           mediaEditorTools.contains(tool) {
            if !openMediaEditor(tool, item: first) { NSSound.beep() }
            return
        }
        if editorTools.contains(tool) {
            if !openEditor(tool, items: items) { NSSound.beep() }
            return
        }
        let run: (ToolOptions, [InputItem]) -> Void = { options, ordered in
            ToolDialogController.shared.close()
            JobCenter.shared.submit(JobCenter.requests(for: .tool(tool), items: ordered, outputDirectory: nil, options: options))
        }
        let cancel = { ToolDialogController.shared.close() }
        let view = dialog(for: tool, items: items, run: run, cancel: cancel)
        ToolDialogController.shared.present(title: tool.displayName, content: view)
    }

    static func dialog(for tool: Tool, items: [InputItem], run: @escaping (ToolOptions, [InputItem]) -> Void,
                       cancel: @escaping () -> Void) -> AnyView {
        switch tool {
        case .compress: return AnyView(CompressDialog(items: items, run: run, cancel: cancel))
        case .resize: return AnyView(ResizeDialog(items: items, run: run, cancel: cancel))
        case .rotate: return AnyView(RotateDialog(items: items, run: run, cancel: cancel))
        case .createPDF: return AnyView(CreatePDFDialog(items: items, run: run, cancel: cancel))
        case .speed: return AnyView(SpeedDialog(items: items, run: run, cancel: cancel))
        case .split: return AnyView(SplitDialog(items: items, run: run, cancel: cancel))
        case .join: return AnyView(JoinDialog(items: items, run: run, cancel: cancel))
        case .extractAudio: return AnyView(ExtractAudioDialog(items: items, run: run, cancel: cancel))
        case .normalize: return AnyView(NormalizeDialog(items: items, run: run, cancel: cancel))
        case .channels: return AnyView(ChannelsDialog(items: items, run: run, cancel: cancel))
        case .visualizer: return AnyView(VisualizerDialog(items: items, run: run, cancel: cancel))
        default: return AnyView(EmptyView())
        }
    }
}

/// Hosts one tool dialog at a time in a small floating panel near the pointer.
@MainActor
final class ToolDialogController: NSObject, NSWindowDelegate {
    static let shared = ToolDialogController()
    private var panel: NSPanel?

    func present(title: String, content: AnyView) {
        close()
        let hosting = NSHostingController(rootView: content)
        let panel = NSPanel(contentViewController: hosting)
        panel.title = title
        panel.styleMask = [.titled, .closable, .utilityWindow]
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let size = hosting.view.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: mouse.x - frame.width / 2, y: mouse.y - frame.height / 2)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.origin.y, visible.minY + 8), visible.maxY - frame.height - 8)
        }
        panel.setFrame(frame, display: false)
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSPanel) === panel { panel = nil }
    }
}

// MARK: Shared pieces

/// Title line, content, and Cancel / primary buttons.
struct DialogFrame<Content: View>: View {
    let summary: String
    let action: String
    var enabled = true
    let cancel: () -> Void
    let run: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            content
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(action, action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enabled)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

enum DialogText {
    static func summary(_ items: [InputItem]) -> String {
        let size = items.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.url.path)[.size] as? Int).map(Int64.init) ?? 0) }
        let names = items.count == 1 ? items[0].url.lastPathComponent : "\(items.count) files"
        return size > 0 ? "\(names) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))" : names
    }

    static func pixelSize(_ item: InputItem) -> (Int, Int)? {
        guard item.kind == .image, let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = p[kCGImagePropertyPixelWidth as String] as? Int,
              let h = p[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        let o = (p[kCGImagePropertyOrientation as String] as? Int) ?? 1
        return o >= 5 ? (h, w) : (w, h)
    }
}

/// Reorderable list of files (Create PDF, Join).
struct OrderList: View {
    @Binding var items: [InputItem]

    var body: some View {
        List {
            ForEach(items, id: \.url) { item in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
            }
            .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
        }
        .frame(height: min(220, CGFloat(items.count) * 26 + 12))
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }
}

// MARK: Compress

struct CompressDialog: View {
    let items: [InputItem]
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @AppStorage("tool.compress.preset") private var preset = CompressOptions.Preset.medium.rawValue
    @AppStorage("tool.compress.exact") private var exact = false
    @AppStorage("tool.compress.size") private var size = 5.0
    @AppStorage("tool.compress.unit") private var unit = "MB"

    var body: some View {
        DialogFrame(summary: DialogText.summary(items), action: "Compress", enabled: !exact || size > 0,
                    cancel: cancel, run: start) {
            Picker("", selection: $preset) {
                Text("High quality").tag(CompressOptions.Preset.high.rawValue)
                Text("Medium").tag(CompressOptions.Preset.medium.rawValue)
                Text("Small").tag(CompressOptions.Preset.small.rawValue)
                Text("Email (25 MB)").tag(CompressOptions.Preset.email.rawValue)
                Text("Discord (10 MB)").tag(CompressOptions.Preset.discord.rawValue)
                Text("WhatsApp (16 MB)").tag(CompressOptions.Preset.whatsapp.rawValue)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(exact)
            HStack {
                Toggle("Exact size:", isOn: $exact)
                TextField("", value: $size, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 70)
                    .disabled(!exact)
                Picker("", selection: $unit) {
                    Text("KB").tag("KB")
                    Text("MB").tag("MB")
                }
                .labelsHidden()
                .frame(width: 70)
                .disabled(!exact)
            }
            Text("Each file is compressed separately. Originals stay as they are.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func start() {
        let p = CompressOptions.Preset(rawValue: preset) ?? .medium
        let bytes = exact ? Int64(size * (unit == "KB" ? 1_000 : 1_000_000)) : nil
        run(.compress(CompressOptions(preset: p, targetBytes: bytes)), items)
    }
}

// MARK: Resize

struct ResizeDialog: View {
    let items: [InputItem]
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @AppStorage("tool.resize.mode") private var mode = "percent"
    @AppStorage("tool.resize.percent") private var percent = 50.0
    @AppStorage("tool.resize.width") private var width = 1920
    @AppStorage("tool.resize.height") private var height = 1080
    @AppStorage("tool.resize.edge") private var edge = 2048

    var body: some View {
        DialogFrame(summary: DialogText.summary(items), action: "Resize", cancel: cancel, run: start) {
            Picker("", selection: $mode) {
                Text("Percentage").tag("percent")
                Text("Fit within").tag("fit")
                Text("Longest edge").tag("edge")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch mode {
                case "fit":
                    HStack {
                        TextField("Width", value: $width, format: .number).frame(width: 80)
                        Text("×")
                        TextField("Height", value: $height, format: .number).frame(width: 80)
                        Text("pixels")
                    }
                case "edge":
                    HStack {
                        TextField("Pixels", value: $edge, format: .number).frame(width: 90)
                        Text("pixels on the longest side")
                    }
                default:
                    HStack {
                        Slider(value: $percent, in: 5...200, step: 5)
                        Text("\(Int(percent))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Presets:").foregroundStyle(.secondary)
                Button("4K") { mode = "fit"; width = 3840; height = 2160 }
                Button("1080p") { mode = "fit"; width = 1920; height = 1080 }
                Button("720p") { mode = "fit"; width = 1280; height = 720 }
                Button("50%") { mode = "percent"; percent = 50 }
            }
            .controlSize(.small)
            if let first = items.first, let size = DialogText.pixelSize(first) {
                let resized = ImageGeometry.resized(width: size.0, height: size.1, mode: currentMode)
                Text("\(size.0) × \(size.1) → \(resized.0) × \(resized.1)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var currentMode: ResizeOptions.Mode {
        switch mode {
        case "fit": return .fit(width: max(1, width), height: max(1, height))
        case "edge": return .longestEdge(max(1, edge))
        default: return .percent(max(1, percent))
        }
    }

    private func start() { run(.resize(ResizeOptions(mode: currentMode)), items) }
}

// MARK: Rotate

struct RotateDialog: View {
    let items: [InputItem]
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @State private var turn: RotateOptions.Turn = .right
    @State private var flipH = false
    @State private var flipV = false

    var body: some View {
        DialogFrame(summary: DialogText.summary(items), action: "Rotate", enabled: turn != .none || flipH || flipV,
                    cancel: cancel, run: { run(.rotate(RotateOptions(turn: turn, flipHorizontal: flipH, flipVertical: flipV)), items) }) {
            HStack(spacing: 10) {
                turnButton(.left, "rotate.left", "90° left")
                turnButton(.right, "rotate.right", "90° right")
                turnButton(.half, "arrow.triangle.2.circlepath", "180°")
                turnButton(.none, "nosign", "None")
            }
            HStack(spacing: 18) {
                Toggle("Flip horizontally", isOn: $flipH)
                Toggle("Flip vertically", isOn: $flipV)
            }
            if items.contains(where: { $0.format == .jpg || $0.format == .heic || $0.format == .mp4 || $0.format == .mov }) {
                Text("JPG, HEIC, MP4 and MOV are rotated without re-encoding (no quality loss).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func turnButton(_ value: RotateOptions.Turn, _ symbol: String, _ title: String) -> some View {
        Button {
            turn = value
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption)
            }
            .frame(width: 70, height: 52)
            .background(RoundedRectangle(cornerRadius: 8).fill(turn == value ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Create PDF

struct CreatePDFDialog: View {
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @State private var ordered: [InputItem]
    @AppStorage("tool.createPDF.pageSize") private var pageSize = CreatePDFOptions.PageSize.fitImage.rawValue
    @AppStorage("tool.createPDF.margin") private var margin = 0.0

    init(items: [InputItem], run: @escaping (ToolOptions, [InputItem]) -> Void, cancel: @escaping () -> Void) {
        self.run = run
        self.cancel = cancel
        _ordered = State(initialValue: items)
    }

    var body: some View {
        DialogFrame(summary: "\(ordered.count) file\(ordered.count == 1 ? "" : "s") → Images.pdf · drag to reorder",
                    action: "Create PDF", cancel: cancel, run: start) {
            OrderList(items: $ordered)
            Picker("Page size", selection: $pageSize) {
                Text("Fit each image").tag(CreatePDFOptions.PageSize.fitImage.rawValue)
                Text("A4").tag(CreatePDFOptions.PageSize.a4.rawValue)
                Text("US Letter").tag(CreatePDFOptions.PageSize.letter.rawValue)
            }
            Picker("Margins", selection: $margin) {
                Text("None").tag(0.0)
                Text("Small").tag(18.0)
                Text("Medium").tag(36.0)
            }
            .pickerStyle(.segmented)
        }
    }

    private func start() {
        let size = CreatePDFOptions.PageSize(rawValue: pageSize) ?? .fitImage
        run(.createPDF(CreatePDFOptions(pageSize: size, margin: margin)), ordered)
    }
}

// MARK: Speed

struct SpeedDialog: View {
    let items: [InputItem]
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @AppStorage("tool.speed.factor") private var factor = 1.5
    private let presets: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        DialogFrame(summary: DialogText.summary(items), action: "Change Speed", enabled: factor >= 0.25 && factor <= 4 && factor != 1,
                    cancel: cancel, run: { run(.speed(factor), items) }) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(78)), count: 4), spacing: 8) {
                ForEach(presets, id: \.self) { value in
                    Button(String(format: "%g×", value)) { factor = value }
                        .buttonStyle(.bordered)
                        .tint(value == factor ? .accentColor : nil)
                }
            }
            HStack {
                Text("Custom:")
                TextField("", value: $factor, format: .number.precision(.fractionLength(0...2))).frame(width: 60)
                Text("× (0.25–4)")
            }
            Text("Pitch stays natural.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: Split

struct SplitDialog: View {
    let items: [InputItem]
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @AppStorage("tool.split.pdfMode") private var pdfMode = "every"
    @AppStorage("tool.split.pdfN") private var pdfN = 2
    @AppStorage("tool.split.ranges") private var ranges = "1-3, 4-"
    @AppStorage("tool.split.mediaMode") private var mediaMode = "parts"
    @AppStorage("tool.split.parts") private var parts = 2
    @AppStorage("tool.split.seconds") private var seconds = 60.0

    private var isPDF: Bool { items.first?.kind == .pdf }

    var body: some View {
        DialogFrame(summary: DialogText.summary(items), action: "Split", cancel: cancel, run: start) {
            if isPDF {
                Picker("", selection: $pdfMode) {
                    Text("Every page").tag("every")
                    Text("Every").tag("n")
                    Text("Page ranges").tag("ranges")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if pdfMode == "n" {
                    Stepper("\(pdfN) pages per file", value: $pdfN, in: 1...500)
                } else if pdfMode == "ranges" {
                    TextField("e.g. 1-3, 5, 7-", text: $ranges)
                    Text("One PDF per range.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Picker("", selection: $mediaMode) {
                    Text("Equal parts").tag("parts")
                    Text("Every").tag("every")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if mediaMode == "parts" {
                    Stepper("\(parts) parts", value: $parts, in: 2...100)
                } else {
                    HStack {
                        TextField("", value: $seconds, format: .number).frame(width: 70)
                        Text("seconds")
                    }
                }
                Text("Cuts are made without re-encoding, at the nearest keyframe.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func start() {
        if isPDF {
            let mode: SplitPDFOptions.Mode = pdfMode == "n" ? .everyN(pdfN) : pdfMode == "ranges" ? .ranges(ranges) : .everyPage
            run(.splitPDF(SplitPDFOptions(mode: mode)), items)
        } else {
            let mode: SplitMediaOptions.Mode = mediaMode == "parts" ? .parts(parts) : .every(seconds: max(1, seconds))
            run(.splitMedia(SplitMediaOptions(mode: mode)), items)
        }
    }
}

// MARK: Join

struct JoinDialog: View {
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @State private var ordered: [InputItem]

    init(items: [InputItem], run: @escaping (ToolOptions, [InputItem]) -> Void, cancel: @escaping () -> Void) {
        self.run = run
        self.cancel = cancel
        _ordered = State(initialValue: items)
    }

    var body: some View {
        DialogFrame(summary: "\(ordered.count) clips → one file · drag to reorder", action: "Join", cancel: cancel,
                    run: { run(.join(JoinOptions()), ordered) }) {
            OrderList(items: $ordered)
            Text("Clips that differ are matched to the first one's size and frame rate.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Extract audio

struct ExtractAudioDialog: View {
    let items: [InputItem]
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @AppStorage("tool.extractAudio.format") private var format = Format.mp3.rawValue

    var body: some View {
        DialogFrame(summary: DialogText.summary(items), action: "Extract", cancel: cancel,
                    run: { run(.extractAudio(Format(rawValue: format) ?? .mp3), items) }) {
            Picker("Format", selection: $format) {
                Text("MP3").tag(Format.mp3.rawValue)
                Text("M4A (AAC)").tag(Format.m4a.rawValue)
                Text("WAV").tag(Format.wav.rawValue)
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: Normalize

struct NormalizeDialog: View {
    let items: [InputItem]
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @AppStorage("tool.normalize.lufs") private var lufs = -16.0
    @AppStorage("tool.normalize.peak") private var peak = -1.0

    var body: some View {
        DialogFrame(summary: DialogText.summary(items), action: "Normalize", cancel: cancel,
                    run: { run(.normalize(NormalizeOptions(integratedLUFS: lufs, truePeak: peak)), items) }) {
            Picker("Target", selection: $lufs) {
                Text("−14 LUFS · streaming").tag(-14.0)
                Text("−16 LUFS · podcast").tag(-16.0)
                Text("−19 LUFS · voice").tag(-19.0)
                Text("−23 LUFS · broadcast").tag(-23.0)
            }
            HStack {
                Text("True peak limit")
                Slider(value: $peak, in: -3...0, step: 0.5)
                Text(String(format: "%.1f dBTP", peak)).monospacedDigit().frame(width: 72, alignment: .trailing)
            }
            Text("Measures the loudness first, then adjusts it in a second pass (EBU R128).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Channels

struct ChannelsDialog: View {
    let items: [InputItem]
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @AppStorage("tool.channels.mode") private var mode = ChannelOptions.Mode.mono.rawValue
    @AppStorage("tool.channels.left") private var left = 0.0
    @AppStorage("tool.channels.right") private var right = 0.0
    @StateObject private var previewer = AudioPreviewer()

    var body: some View {
        DialogFrame(summary: DialogText.summary(items), action: "Apply", cancel: cancel, run: start) {
            Picker("", selection: $mode) {
                Text("Mono").tag(ChannelOptions.Mode.mono.rawValue)
                Text("Stereo").tag(ChannelOptions.Mode.stereo.rawValue)
                Text("Left only").tag(ChannelOptions.Mode.leftOnly.rawValue)
                Text("Right only").tag(ChannelOptions.Mode.rightOnly.rawValue)
                Text("Swap").tag(ChannelOptions.Mode.swap.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            gainRow("Left", $left)
            gainRow("Right", $right)
            HStack {
                Button(previewer.state == .idle ? "Preview" : previewer.state == .rendering ? "Preparing…" : "Stop") { preview() }
                    .disabled(previewer.state == .rendering || items.count != 1)
                Text("Plays the first 15 seconds").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onChange(of: mode) { _, _ in previewer.stop() }
        .onDisappear { previewer.stop() }
    }

    private func preview() {
        if previewer.state != .idle { previewer.stop(); return }
        guard let item = items.first else { return }
        let options = ChannelOptions(mode: ChannelOptions.Mode(rawValue: mode) ?? .mono, leftGainDB: left, rightGainDB: right)
        let settings = Preferences.conversionSettings()
        previewer.play { out in
            let excerpt = out.deletingLastPathComponent().appendingPathComponent("excerpt.wav")
            try await MediaAnalysis.excerpt(item.url, seconds: 15, to: excerpt)
            try await MediaTools.channels(excerpt, format: .m4a, options: options, to: out, settings: settings) { _ in }
        }
    }

    private func gainRow(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 40, alignment: .leading)
            Slider(value: value, in: -12...12, step: 0.5)
            Text(String(format: "%+.1f dB", value.wrappedValue)).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }

    private func start() {
        let m = ChannelOptions.Mode(rawValue: mode) ?? .mono
        run(.channels(ChannelOptions(mode: m, leftGainDB: left, rightGainDB: right)), items)
    }
}
