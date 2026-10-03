import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if let i = args.firstIndex(of: "--render-snapshots") {
        let dir = i + 1 < args.count ? args[i + 1] : "snapshots"
        app.finishLaunching()
        exit(SnapshotRenderer.run(into: URL(fileURLWithPath: dir)))
    }
    let delegate = AppDelegate(selfTest: args.contains("--self-test"))
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
