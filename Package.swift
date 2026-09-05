// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClaudeUsageBarCore", path: "Sources/ClaudeUsageBarCore"),
        .executableTarget(
            name: "ClaudeUsageBar",
            dependencies: ["ClaudeUsageBarCore"],
            path: "Sources/ClaudeUsageBar"
        ),
        .testTarget(
            name: "ClaudeUsageBarTests",
            dependencies: ["ClaudeUsageBarCore"],
            path: "tests/ClaudeUsageBarTests"
        ),
    ]
)
