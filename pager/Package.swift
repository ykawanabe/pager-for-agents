// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudePager",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Embedded terminal emulator for Watch live's main pane.
        // We attach to the topic's tmux session via LocalProcessTerminalView,
        // giving us a real PTY-driven view instead of polling capture-pane.
        // See docs/plans/pager-watch-live.md (Phase: SwiftTerm).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudePager",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/ClaudePager"
        ),
        .testTarget(
            name: "ClaudePagerTests",
            dependencies: ["ClaudePager"],
            path: "Tests/ClaudePagerTests"
        )
    ]
)
