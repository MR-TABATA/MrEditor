// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MrEditor",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MrEditor",
            path: "Sources/MrEditor",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MrEditorTests",
            dependencies: ["MrEditor"],
            path: "Tests/MrEditorTests"
        )
    ]
)
