import AppKit
import ClementineCore
import SwiftUI

/// First-launch window: how the gesture works, a practice file to try it on,
/// and the open-at-login switch.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = OnboardingView(practiceFile: Self.practiceFile()) { [weak self] in
                Preferences.onboardingDone = true
                self?.window?.close()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Clementine"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Preferences.onboardingDone = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.window = nil }
        }
    }

    static func makeView() -> NSView {
        NSHostingView(rootView: OnboardingView(practiceFile: practiceFile()) {})
    }

    /// A small picture in Application Support to practise on (outputs land next to it).
    static func practiceFile() -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Clementine/Practice", isDirectory: true)
        let url = dir.appendingPathComponent("Clementine Practice.png")
        if fm.fileExists(atPath: url.path) { return url }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let side = 512
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSColor(srgbRed: 1.0, green: 0.95, blue: 0.88, alpha: 1).setFill()
                rect.fill()
                NSApp.applicationIconImage.draw(in: rect.insetBy(dx: 40, dy: 40))
                return true
            }
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

struct OnboardingView: View {
    let practiceFile: URL?
    let onDone: () -> Void
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
            Text("Welcome to Clementine")
                .font(.title2.weight(.semibold))
            VStack(spacing: 6) {
                Text("Hold **⇧ Shift** while you drag a file.\nA wheel of formats appears. Drop the file on one.")
                Text("Hold **⇧ Shift + ⌥ Option** instead to get tools: compress, crop, and more.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .font(.callout)

            if let practiceFile {
                HStack(spacing: 14) {
                    PracticeFile(url: practiceFile)
                        .frame(width: 92, height: 92)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Try it here").font(.headline)
                        Text("Start dragging this picture, then hold ⇧ Shift. The converted copy is saved next to it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            }

            Text("Clementine lives in the menu bar. It works offline and never changes your original files.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in LoginItem.setEnabled(on) }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(width: 440)
    }
}

/// The draggable practice file. Our own drags aren't seen by the global mouse
/// monitor, so this tells the drag monitor directly.
struct PracticeFile: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PracticeFileView { PracticeFileView(url: url) }
    func updateNSView(_ nsView: PracticeFileView, context: Context) {}
}

final class PracticeFileView: NSView, NSDraggingSource {
    let url: URL
    private let icon: NSImage

    init(url: URL) {
        self.url = url
        icon = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: NSRect(x: 0, y: 0, width: 92, height: 92))
        toolTip = "Drag me while holding ⇧ Shift"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 6)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.6).setFill()
        path.fill()
        icon.draw(in: rect.insetBy(dx: 6, dy: 6), from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        AppDelegate.shared?.dragMonitor.beginOwnDrag()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        AppDelegate.shared?.dragMonitor.endOwnDrag()
    }
}
