import XCTest
@testable import MrEditor

/// 10GB 実ファイルでの索引構築時間を測る。README / LP に載せる数字の出どころ。
/// 普段は skip。`MREDITOR_BENCH=1 swift test --filter BigFileIndexBench` で走る。
///
/// 公表値を勘で書かないための計測。数字が動いたらここで測り直して README を直す。
final class BigFileIndexBenchTests: XCTestCase {

    func testIndexBuildTimeOn10GB() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1 で 10GB の索引ベンチを実行")
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("testdata/test_10gb.log")
        guard let buffer = FileBuffer(url: url) else {
            throw XCTSkip("testdata/test_10gb.log がない（scripts/gen_testdata.py で作る）")
        }

        let index = LineIndex(buffer: buffer)
        let done = expectation(description: "索引完了")
        let t0 = Date()
        index.buildInBackground(progress: { _ in }, completion: { done.fulfill() })
        wait(for: [done], timeout: 600)
        let sec = Date().timeIntervalSince(t0)

        let gb = Double(buffer.count) / 1_073_741_824
        print(String(format: "索引: %.2f 秒 / %.2f GB / %d 行 (%.2f GB/s)",
                     sec, gb, index.displayLineCount, gb / sec))

        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.displayLineCount, 86_420_337)

        // 最終行へのシーク。索引完了後は最寄りの疎索引点から数えるだけなので O(stride)。
        var seekWorst = 0.0
        for _ in 0..<20 {
            let t = Date()
            _ = index.byteOffset(ofLineStart: 86_420_336)
            seekWorst = max(seekWorst, Date().timeIntervalSince(t))
        }
        print(String(format: "最終行へのシーク: 最悪 %.3f ms（20回）", seekWorst * 1000))

        // 索引そのものの大きさ。LP の「1 億行でも N KB」はここから出す。
        let kb = Double(index.indexBytes) / 1024
        let per100M = kb / Double(index.displayLineCount) * 100_000_000
        print(String(format: "疎索引: %.0f KB（%d 行・stride %d）→ 1 億行なら %.0f KB",
                     kb, index.displayLineCount, index.stride, per100M))
    }

    /// 「開いてから最初の行が出るまで」に相当する経路: mmap して、行数を見積もり、
    /// 画面に出る最初の数十行を読むところまで。AppKit の描画そのものは含まない。
    func testTimeToFirstScreenOn10GB() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1 で 10GB の初期表示ベンチを実行")
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("testdata/test_10gb.log")

        let t0 = Date()
        guard let buffer = FileBuffer(url: url) else { throw XCTSkip("testdata/test_10gb.log がない") }
        let index = LineIndex(buffer: buffer)          // ここで先頭を標本化して行数を見積もる
        // 画面に出る最初の 50 行を実際に読む
        let end = index.byteOffset(ofLineStart: 50)
        _ = buffer.data(in: 0..<max(1, end))
        let ms = Date().timeIntervalSince(t0) * 1000

        print(String(format: "最初の画面まで: %.1f ms（mmap + 行数見積もり + 先頭50行の読み出し）", ms))
        XCTAssertGreaterThan(index.displayLineCount, 0)
    }
}
