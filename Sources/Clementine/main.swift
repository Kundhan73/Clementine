import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if let i = args.firstIndex(of: "--render-snapshots") {
        let dir = i + 1 < args.count ? args[i + 1] : "snapshots"
        app.finishLaunching()
        // `--only media` renders the media editors (needs ffmpeg in the bundle).
        let media = args.firstIndex(of: "--only").map { $0 + 1 < args.count && args[$0 + 1] == "media" } ?? false
        exit(SnapshotRenderer.run(into: URL(fileURLWithPath: dir), media: media))
    }
    let delegate = AppDelegate(selfTest: args.contains("--self-test"))
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
