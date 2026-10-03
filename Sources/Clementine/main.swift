import AppKit

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--render-snapshots") {
        let dir = i + 1 < args.count ? args[i + 1] : "snapshots"
        exit(SnapshotRenderer.run(into: URL(fileURLWithPath: dir)))
    }
    let app = NSApplication.shared
    let delegate = AppDelegate(selfTest: args.contains("--self-test"))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
