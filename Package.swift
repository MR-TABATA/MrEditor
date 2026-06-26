// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MrEditor",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MrEditor",
            path: "Sources/MrEditor"
        )
    ]
)
