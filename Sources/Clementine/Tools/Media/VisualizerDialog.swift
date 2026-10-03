import AppKit
import ClementineCore
import SwiftUI
import UniformTypeIdentifiers

/// Audio → video with a moving waveform, bars, circle or spectrogram.
struct VisualizerDialog: View {
    struct BackgroundChoice: Identifiable {
        let id: String
        let title: String
        let value: VisualizerOptions.Background
    }

    static let colors: [RGBA] = [.white, .orange, .yellow, RGBA(0.3, 0.85, 0.45), RGBA(0.35, 0.75, 1),
                                 RGBA(0.72, 0.5, 1), RGBA(1, 0.42, 0.62)]
    static let backgrounds: [BackgroundChoice] = [
        BackgroundChoice(id: "blurred", title: "Blurred cover art", value: .blurredCover),
        BackgroundChoice(id: "cover", title: "Cover art", value: .coverArt),
        BackgroundChoice(id: "night", title: "Night", value: .gradient(RGBA(0.12, 0.14, 0.22), RGBA(0.32, 0.25, 0.45))),
        BackgroundChoice(id: "sunset", title: "Sunset", value: .gradient(RGBA(1.0, 0.62, 0.25), RGBA(0.93, 0.33, 0.45))),
        BackgroundChoice(id: "ocean", title: "Ocean", value: .gradient(RGBA(0.2, 0.55, 0.95), RGBA(0.35, 0.85, 0.8))),
        BackgroundChoice(id: "black", title: "Black", value: .solid(.black)),
    ]

    let items: [InputItem]
    let run: (ToolOptions, [InputItem]) -> Void
    let cancel: () -> Void
    @AppStorage("tool.visualizer.style") var style = VisualizerOptions.Style.waveform.rawValue
    @AppStorage("tool.visualizer.shape") var shape = VisualizerOptions.Shape.landscape.rawValue
    @AppStorage("tool.visualizer.background") var background = "blurred"
    @AppStorage("tool.visualizer.color") var colorIndex = 1
    @AppStorage("tool.visualizer.picture") var picturePath = ""
    @State var title: String

    init(items: [InputItem], run: @escaping (ToolOptions, [InputItem]) -> Void, cancel: @escaping () -> Void) {
        self.items = items
        self.run = run
        self.cancel = cancel
        _title = State(initialValue: items.first.map { OutputNamer.baseName(of: $0.url) } ?? "")
    }

    var body: some View {
        DialogFrame(summary: DialogText.summary(items), action: "Create Video", cancel: cancel, run: start) {
            Picker("", selection: $style) {
                ForEach(VisualizerOptions.Style.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Text("Colour").frame(width: 80, alignment: .leading)
                Swatches(colors: Self.colors, selection: colorBinding)
            }
            HStack {
                Picker("Background", selection: $background) {
                    ForEach(Self.backgrounds) { Text($0.title).tag($0.id) }
                    Text(picturePath.isEmpty ? "A picture…" : (picturePath as NSString).lastPathComponent).tag("picture")
                }
                if background == "picture" {
                    Button("Choose…") { choosePicture() }
                }
            }
            .onChange(of: background) { _, value in
                if value == "picture" && picturePath.isEmpty { choosePicture() }
            }
            Picker("Size", selection: $shape) {
                ForEach(VisualizerOptions.Shape.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
            }
            TextField("Title (optional)", text: $title)
            Text("Makes an MP4 video with the sound and a moving picture.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var colorBinding: Binding<RGBA> {
        Binding(get: { Self.colors[min(max(0, colorIndex), Self.colors.count - 1)] },
                set: { c in colorIndex = Self.colors.firstIndex(of: c) ?? 1 })
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Picture"
        if panel.runModal() == .OK, let url = panel.url {
            picturePath = url.path
        } else if picturePath.isEmpty {
            background = "blurred"
        }
    }

    private var chosenBackground: VisualizerOptions.Background {
        if background == "picture", !picturePath.isEmpty, FileManager.default.fileExists(atPath: picturePath) {
            return .image(URL(fileURLWithPath: picturePath))
        }
        return Self.backgrounds.first { $0.id == background }?.value ?? .blurredCover
    }

    private func start() {
        let options = VisualizerOptions(
            style: VisualizerOptions.Style(rawValue: style) ?? .waveform,
            color: colorBinding.wrappedValue,
            background: chosenBackground,
            title: title,
            shape: VisualizerOptions.Shape(rawValue: shape) ?? .landscape)
        run(.visualizer(options), items)
    }
}
