import AppKit
import Carbon.HIToolbox
import ClementineCore

/// Optional ⌃⌥C shortcut (off by default): opens the wheel for the files
/// selected in Finder. The hotkey itself needs no permission; asking Finder
/// for its selection makes macOS ask once to let Clementine control Finder.
@MainActor
final class FinderHotKey {
    static let shared = FinderHotKey()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.finderHotKey) }

    func apply() {
        if Self.isEnabled { register() } else { unregister() }
    }

    private func register() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { FinderHotKey.shared.fire() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x434C_4D4E), id: 1) // 'CLMN'
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    private func fire() {
        let point = NSEvent.mouseLocation
        Task {
            let paths = await Self.finderSelection()
            guard !paths.isEmpty else {
                NSSound.beep()
                return
            }
            AppDelegate.shared?.showWheel(for: paths.map { URL(fileURLWithPath: $0) }, at: point)
        }
    }

    /// POSIX paths of Finder's selection (osascript runs off the main thread).
    static func finderSelection() async -> [String] {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with f in (get selection)
                set out to out & POSIX path of (f as alias) & linefeed
            end repeat
            return out
        end tell
        """
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script]),
              result.status == 0 else { return [] }
        return result.stdoutString.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
