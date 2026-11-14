// swift-tools-version: 5.9
import PackageDescription

// MrEditor（MIT）。本体は MrEditorCore に置き、実行ファイル MrEditor は起動するだけ。
//
//   MrEditorCore (library) ── 本体のほぼ全部。UI もエンジンも分析もここ。
//        ├── MrEditor       (executable) … アプリ。
//        └── SearchBenchCLI (executable) … 検索の速さを測る道具。
let package = Package(
    name: "MrEditor",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MrEditorCore", targets: ["MrEditorCore"])
    ],
    targets: [
        .target(
            name: "MrEditorCore",
            path: "Sources/MrEditorCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "MrEditor",
            dependencies: ["MrEditorCore"],
            path: "Sources/MrEditor"
        ),
        // 検索の速さを release で測る道具（debug の数字だけでは実装のせいか
        // ビルド設定のせいか分けられないため）。
        .executableTarget(
            name: "SearchBenchCLI",
            dependencies: ["MrEditorCore"],
            path: "Sources/SearchBenchCLI"
        ),
        .testTarget(
            name: "MrEditorTests",
            dependencies: ["MrEditorCore"],
            path: "Tests/MrEditorTests"
        )
    ]
)