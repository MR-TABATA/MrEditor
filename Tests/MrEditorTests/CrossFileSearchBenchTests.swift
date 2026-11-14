import XCTest
@testable import MrEditorCore

/// C5 のベンチ。普段は skip。
/// `MREDITOR_BENCH=1 swift test -c release --filter CrossFileSearchBench` で走る。
///
/// **rg と並べて測る。** ただし公表するときは「互角」までしか言わない——複雑な正規表現は
/// Rust の regex のほうが確実に速く、数字を並べて勝ちに行くと足元をすくわれる（仕様 §5.1）。
final class CrossFileSearchBenchTests: XCTestCase {

    private func benchOnly() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1 で実データのベンチを実行")
        }
    }

    private func measureSearch(_ label: String,
                               folders: [URL],
                               query: String,
                               options: CrossFileSearchRunner.Options = .init()) {
        let runner = CrossFileSearchRunner()
        let exp = expectation(description: label)
        var summary = CrossFileSearchRunner.Summary()
        runner.run(folders: folders, query: query, options: options,
                   onFile: { _ in }, progress: { _ in },
                   completion: { summary = $0; exp.fulfill() })
        wait(for: [exp], timeout: 900)
        print(String(format: "[bench] %@: %.2f 秒 / %d ファイル中 %d ファイル / %d 行%@",
                     label, summary.elapsed, summary.files, summary.matchedFiles,
                     summary.matchedLines, summary.capped ? "（上限で打ち切り）" : ""))
    }

    /// 比較用に `rg` を回す（入っていなければ黙って飛ばす）。
    private func measureRipgrep(_ label: String, args: [String]) {
        let rg = URL(fileURLWithPath: "/opt/homebrew/bin/rg")
        guard FileManager.default.isExecutableFile(atPath: rg.path) else {
            print("[bench] \(label): rg が無いので比較なし")
            return
        }
        let process = Process()
        process.executableURL = rg
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let t0 = Date()
        try? process.run()
        process.waitUntilExit()
        print(String(format: "[bench] %@（rg 参考）: %.2f 秒", label, Date().timeIntervalSince(t0)))
    }

    /// 10GB 1 本・リテラル 1 語。
    func testTenGBLiteral() throws {
        try benchOnly()
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/testdata/test_10gb_time.log")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("testdata/test_10gb_time.log がない")
        }
        // 一致が 1 行だけの語を選ぶ（上限に当てず、走査そのものを測るため）。
        let needle = "request_id=42032287"
        measureSearch("10GB リテラル 1 語", folders: [url], query: needle)
        measureRipgrep("10GB リテラル 1 語", args: ["-c", needle, url.path])
    }

    /// 小さいファイルが大量にあるフォルダ（＝ソースツリー）。
    func testManySmallFiles() throws {
        try benchOnly()
        let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/Sources")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw XCTSkip("Sources がない")
        }
        measureSearch("小ファイル多数（Sources）", folders: [folder], query: "func")
        measureRipgrep("小ファイル多数（Sources）", args: ["-c", "func", folder.path])
    }
}