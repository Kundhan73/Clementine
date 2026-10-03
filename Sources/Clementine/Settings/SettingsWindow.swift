import AppKit
import ClementineCore
import SwiftUI

/// Settings window (SwiftUI, created on demand and released when closed).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(tab: SettingsTab = .general) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(initialTab: tab))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Clementine Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the SwiftUI tree once the window is gone (memory).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.window = nil }
        }
    }

    /// The window's content view, for snapshots.
    static func makeView(tab: SettingsTab) -> NSView {
        NSHostingView(rootView: SettingsView(initialTab: tab))
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, output, quality, wheel, advanced, about
    var id: String { rawValue }
}

struct SettingsView: View {
    @State var tab: SettingsTab

    init(initialTab: SettingsTab) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            OutputSettingsView().tabItem { Label("Output", systemImage: "folder") }.tag(SettingsTab.output)
            QualitySettingsView().tabItem { Label("Quality", systemImage: "dial.medium") }.tag(SettingsTab.quality)
            WheelSettingsView().tabItem { Label("Wheel", systemImage: "circle.dashed") }.tag(SettingsTab.wheel)
            AdvancedSettingsView().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.advanced)
            AboutSettingsView().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 500)
        .padding(.vertical, 8)
    }
}

struct GeneralSettingsView: View {
    @AppStorage(PrefKey.shiftDragEnabled) private var shiftDrag = true
    @AppStorage(PrefKey.modifierScheme) private var scheme = ModifierScheme.shift.rawValue
    @AppStorage(PrefKey.wheelSize) private var wheelSize = WheelSize.medium.rawValue
    @AppStorage(PrefKey.completionSound) private var sound = true
    @AppStorage(PrefKey.revealInFinder) private var reveal = false
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Open Clementine at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in LoginItem.setEnabled(on) }
                Toggle("Show the wheel when I drag files with a modifier key", isOn: $shiftDrag)
                    .onChange(of: shiftDrag) { _, _ in AppDelegate.shared?.applyShiftDragPreference() }
                Picker("Keys", selection: $scheme) {
                    Text("⇧ convert · ⇧⌥ tools").tag(ModifierScheme.shift.rawValue)
                    Text("⌃ convert · ⌃⌥ tools").tag(ModifierScheme.control.rawValue)
                }
                Picker("Wheel size", selection: $wheelSize) {
                    Text("Small").tag(WheelSize.small.rawValue)
                    Text("Medium").tag(WheelSize.medium.rawValue)
                    Text("Large").tag(WheelSize.large.rawValue)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Play a sound when files are ready", isOn: $sound)
                Toggle("Show converted files in Finder", isOn: $reveal)
            }
        }
        .formStyle(.grouped)
    }
}

struct OutputSettingsView: View {
    @AppStorage(PrefKey.outputLocation) private var location = "beside"
    @AppStorage(PrefKey.customOutputFolder) private var customFolder = ""
    @AppStorage(PrefKey.keepMetadata) private var keepMetadata = true
    @AppStorage(PrefKey.keepFileDates) private var keepDates = false

    var body: some View {
        Form {
            Section {
                Picker("Save converted files", selection: $location) {
                    Text("Next to the original").tag("beside")
                    Text("In Downloads").tag("downloads")
                    Text("In a folder I choose").tag("custom")
                }
                if location == "custom" {
                    HStack {
                        Text(customFolder.isEmpty ? "No folder chosen" : (customFolder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Text("If a folder can't be written to (for example a disk image), files go to Downloads.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep metadata (camera details, location, tags)", isOn: $keepMetadata)
                Toggle("Keep the original's creation and modification dates", isOn: $keepDates)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { customFolder = url.path }
    }
}

struct QualitySettingsView: View {
    @AppStorage(PrefKey.jpegQuality) private var jpeg = 85
    @AppStorage(PrefKey.heicQuality) private var heic = 80
    @AppStorage(PrefKey.webpQuality) private var webp = 80
    @AppStorage(PrefKey.avifQuality) private var avif = 70
    @AppStorage(PrefKey.pdfDPI) private var dpi = 300
    @AppStorage(PrefKey.videoCodec) private var codec = "h264"
    @AppStorage(PrefKey.videoQuality) private var videoQuality = 65
    @AppStorage(PrefKey.gifFPS) private var gifFPS = 15
    @AppStorage(PrefKey.gifMaxWidth) private var gifWidth = 720

    var body: some View {
        Form {
            Section("Images") {
                QualitySlider(title: "JPG", value: $jpeg)
                QualitySlider(title: "HEIC", value: $heic)
                QualitySlider(title: "WebP", value: $webp)
                QualitySlider(title: "AVIF", value: $avif)
                Picker("PDF pages as images", selection: $dpi) {
                    Text("72 dpi").tag(72)
                    Text("150 dpi").tag(150)
                    Text("300 dpi").tag(300)
                    Text("600 dpi").tag(600)
                }
            }
            Section("Video") {
                Picker("Codec", selection: $codec) {
                    Text("H.264 (works everywhere)").tag("h264")
                    Text("HEVC (smaller)").tag("hevc")
                }
                QualitySlider(title: "Quality", value: $videoQuality)
                Stepper("GIF frame rate: \(gifFPS) fps", value: $gifFPS, in: 5...30)
                Picker("GIF width", selection: $gifWidth) {
                    Text("480 px").tag(480)
                    Text("720 px").tag(720)
                    Text("1080 px").tag(1080)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct QualitySlider: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: 30...100)
            Text("\(value)%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

struct AdvancedSettingsView: View {
    @AppStorage(PrefKey.maxMediaJobs) private var mediaJobs = 1
    @AppStorage(PrefKey.hardwareEncoding) private var hardware = true
    @AppStorage(PrefKey.ffmpegFolder) private var ffmpegFolder = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Stepper("Audio/video files converted at once: \(mediaJobs)", value: $mediaJobs, in: 1...3)
                Toggle("Use hardware video encoding", isOn: $hardware)
            }
            Section("ffmpeg") {
                HStack {
                    Text(ffmpegFolder.isEmpty ? "Built-in" : (ffmpegFolder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose Folder…") { chooseFFmpeg() }
                    if !ffmpegFolder.isEmpty {
                        Button("Use Built-in") {
                            ffmpegFolder = ""
                            Preferences.applyFFmpegOverride()
                        }
                    }
                }
                Text(FFmpegLocator.isAvailable ? "Audio and video conversion is available." : "ffmpeg wasn't found: audio and video conversion is off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Reset All Settings…") { confirmReset = true }
                    .confirmationDialog("Reset all Clementine settings?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { resetAll() }
                    }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder that contains ffmpeg and ffprobe."
        if panel.runModal() == .OK, let url = panel.url {
            ffmpegFolder = url.path
            Preferences.applyFFmpegOverride()
        }
    }

    private func resetAll() {
        let defaults = UserDefaults.standard
        let keep: Set<String> = [PrefKey.onboardingDone, PrefKey.loginItemInitialized, PrefKey.recentOutputs]
        for key in defaults.dictionaryRepresentation().keys where !keep.contains(key) {
            defaults.removeObject(forKey: key)
        }
        Preferences.applyFFmpegOverride()
        AppDelegate.shared?.applyShiftDragPreference()
    }
}

/// Show, hide and reorder the wheel's chips for each kind of file.
struct WheelSettingsView: View {
    struct Category: Identifiable, Hashable {
        let title: String
        let kind: FileKind
        let mode: WheelMode
        var id: String { "\(mode.rawValue).\(kind.rawValue)" }
    }

    static let categories: [Category] = [
        Category(title: "Images", kind: .image, mode: .convert),
        Category(title: "Video", kind: .video, mode: .convert),
        Category(title: "Audio", kind: .audio, mode: .convert),
        Category(title: "PDF", kind: .pdf, mode: .convert),
        Category(title: "Documents", kind: .document, mode: .convert),
        Category(title: "Subtitles", kind: .subtitle, mode: .convert),
        Category(title: "Archives", kind: .archive, mode: .convert),
        Category(title: "Folders", kind: .folder, mode: .convert),
        Category(title: "Image tools", kind: .image, mode: .tools),
        Category(title: "Video tools", kind: .video, mode: .tools),
        Category(title: "Audio tools", kind: .audio, mode: .tools),
        Category(title: "PDF tools", kind: .pdf, mode: .tools),
    ]

    @State var category = WheelSettingsView.categories[0]
    @State var hidden: Set<String> = []
    @State var order: [String] = []

    private var chips: [WheelChip] {
        WheelContent.applyingOrder(WheelContent.catalogue(for: category.kind, mode: category.mode), order: order)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Wheel for", selection: $category) {
                Section("Convert") {
                    ForEach(Self.categories.filter { $0.mode == .convert }) { Text($0.title).tag($0) }
                }
                Section("Tools (⌥)") {
                    ForEach(Self.categories.filter { $0.mode == .tools }) { Text($0.title).tag($0) }
                }
            }
            List {
                ForEach(chips, id: \.key) { chip in
                    HStack(spacing: 8) {
                        Toggle("", isOn: shown(chip)).labelsHidden().toggleStyle(.checkbox)
                        Text(chip.title).fontWeight(.medium)
                        Text(chip.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    }
                    .opacity(hidden.contains(chip.key) ? 0.55 : 1)
                }
                .onMove(perform: move)
            }
            .frame(height: 290)
            HStack {
                Text("Drag to reorder: the first ones sit at the top of the wheel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset Wheel") {
                    Preferences.resetWheel()
                    load()
                }
            }
        }
        .padding(20)
        .onAppear(perform: load)
        .onChange(of: category) { _, _ in load() }
    }

    private func load() {
        hidden = Set(UserDefaults.standard.stringArray(forKey: Preferences.wheelKey(PrefKey.hiddenChips, kind: category.kind,
                                                                                      mode: category.mode)) ?? [])
        order = Preferences.chipOrder(kind: category.kind, mode: category.mode)
    }

    private func shown(_ chip: WheelChip) -> Binding<Bool> {
        Binding(get: { !hidden.contains(chip.key) }, set: { on in
            if on { hidden.remove(chip.key) } else { hidden.insert(chip.key) }
            Preferences.setHiddenChips(hidden, kind: category.kind, mode: category.mode)
        })
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var keys = chips.map(\.key)
        keys.move(fromOffsets: from, toOffset: to)
        order = keys
        Preferences.setChipOrder(keys, kind: category.kind, mode: category.mode)
    }
}

struct AboutSettingsView: View {
    @AppStorage(PrefKey.autoUpdateCheck) private var autoCheck = false

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            Text("Clementine").font(.title2.weight(.semibold))
            Text("Version \(Updater.currentVersion)").foregroundStyle(.secondary)
            Text("A fast, offline file converter for your menu bar.\nNothing you convert ever leaves your Mac.")
                .multilineTextAlignment(.center)
                .font(.callout)
            HStack {
                Button("Check for Updates…") { Updater.shared.checkForUpdates(userInitiated: true) }
                Button("Licenses") { openLicenses() }
            }
            .padding(.top, 6)
            Toggle("Check for updates once a day", isOn: $autoCheck)
                .onChange(of: autoCheck) { _, _ in Updater.shared.applySchedule() }
            Text("The only time Clementine goes online: it asks GitHub for the latest release.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func openLicenses() {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") {
            NSWorkspace.shared.open(url)
        }
    }
}
