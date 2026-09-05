// swift-tools-version: 5.9
import PackageDescription

// 無料コア（MIT）と Pro（クローズド・別リポ）を1本の依存方向で繋ぐための構成。
//
//   MrEditorCore (library) ── 本体のほぼ全部。UI もエンジンもここ。
//        ├── MrEditor  (executable)  … 無料版。Pro を渡さずに起動する。
//        └── ※Pro リポの MrkEditor (executable) が SwiftPM 依存としてこれを引く。
//
// 依存は **Pro → core の一方向のみ**。core は Pro の型を一切知らない
// （知る必要があるのは `ProProvider` という口だけ＝ Sources/MrEditorCore/Pro/）。
let package = Package(
    name: "MrEditor",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Pro リポ（private）はこの product を依存に足して MrkEditor.app を作る。
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