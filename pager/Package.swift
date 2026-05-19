// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudePager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudePager",
            path: "Sources/ClaudePager"
        ),
        .testTarget(
            name: "ClaudePagerTests",
            dependencies: ["ClaudePager"],
            path: "Tests/ClaudePagerTests"
        )
    ]
)
