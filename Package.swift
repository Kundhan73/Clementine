// swift-tools-version:5.10
// Swift 5 language mode (tools version 5.10), macOS 14+, Apple silicon.
import PackageDescription

var targets: [Target] = [
    .target(name: "ClementineCore", path: "Sources/ClementineCore"),
    .testTarget(name: "ClementineCoreTests", dependencies: ["ClementineCore"], path: "Tests/ClementineCoreTests"),
]

#if os(macOS)
// The menu-bar app needs AppKit; on Linux only the core library is built (for
// local unit tests of platform-neutral code).
targets.append(.executableTarget(name: "Clementine", dependencies: ["ClementineCore"], path: "Sources/Clementine"))
#endif

let package = Package(
    name: "Clementine",
    platforms: [.macOS(.v14)],
    targets: targets
)
