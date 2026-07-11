// swift-tools-version: 5.9
import PackageDescription

// MrEditor = 無料版アプリ（MIT・公開）。
// MrEditorCore = UI 非依存の再利用エンジン（piece table / mmap 索引 / 検索 /
//   エンコード判定・変換 / 構造化整形）。ここを library として切り出しておくことで、
//   Pro 版（別リポ・クローズド）が **core を一方向依存で参照** できる。
//   依存の向きは常に Pro → core / app → core。core は app / Pro を知らない。
let package = Package(
    name: "MrEditor",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Pro 版リポジトリはこの package を依存に追加し、この product を import する。
        .library(name: "MrEditorCore", targets: ["MrEditorCore"]),
    ],
    targets: [
        .target(
            name: "MrEditorCore",
            path: "Sources/MrEditorCore"
        ),
        .executableTarget(
            name: "MrEditor",
            dependencies: ["MrEditorCore"],
            path: "Sources/MrEditor",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MrEditorTests",
            dependencies: ["MrEditor", "MrEditorCore"],
            path: "Tests/MrEditorTests"
        )
    ]
)
