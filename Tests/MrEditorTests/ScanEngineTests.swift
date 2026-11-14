import XCTest
@testable import MrEditorCore

/// 走査の土台の試験。**ここが狂うと 4 機能すべてが静かに間違う。**
///
/// 特に見ているのは**チャンク境界**。16MB ごとに並列に読むので、境界に跨がる行を
/// 二重に数えたり落としたりする間違いが一番起きやすく、しかも小さなファイルでは
/// 絶対に再現しない（＝普通のテストでは見つからない）。
final class ScanEngineTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrkpro-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, name: String = "t.log") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// 走査して「行の中身」を全部集める（順序はチャンク順）。
    private func collectLines(_ url: URL) throws -> (lines: [String], stats: ScanEngine.Stats) {
        let engine = ScanEngine()
        let exp = expectation(description: "scan")
        var out: [[String]] = []
        var stats = ScanEngine.Stats()
        engine.scan(url: url,
                    makeSink: { _ in [String]() },
                    consume: { sink, bytes, _ in
                        sink.append(String(decoding: bytes, as: UTF8.self))
                    },
                    progress: { _ in },
                    completion: { sinks, _, s in out = sinks; stats = s; exp.fulfill() })
        wait(for: [exp], timeout: 60)
        return (out.flatMap { $0 }, stats)
    }

    // MARK: - 基本

    func testReadsEveryLineInOrder() throws {
        let url = try write("a\nbb\nccc\n")
        let (lines, stats) = try collectLines(url)
        XCTAssertEqual(lines, ["a", "bb", "ccc"])
        XCTAssertEqual(stats.lines, 3)
        XCTAssertFalse(stats.cancelled)
    }

    /// 末尾に改行が無いファイルでも最後の行を落とさない。
    func testLastLineWithoutTrailingNewline() throws {
        let url = try write("a\nb")
        let (lines, _) = try collectLines(url)
        XCTAssertEqual(lines, ["a", "b"])
    }

    /// 末尾の改行で**幻の空行**を作らない（時刻マージで踏んだのと同じ罠）。
    func testTrailingNewlineDoesNotAddPhantomLine() throws {
        let url = try write("a\nb\n")
        let (lines, _) = try collectLines(url)
        XCTAssertEqual(lines, ["a", "b"])
    }

    /// CRLF の行末では `\r` を値に混ぜない（Windows 由来の CSV を数えたときに
    /// 「200」と「200\r」が別の値になってしまうため）。
    func testStripsCarriageReturn() throws {
        let url = try write("a\r\nb\r\n")
        let (lines, _) = try collectLines(url)
        XCTAssertEqual(lines, ["a", "b"])
    }

    func testEmptyFile() throws {
        let url = try write("")
        let (lines, stats) = try collectLines(url)
        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(stats.lines, 0)
    }

    /// 空行も 1 行として数える（`(空欄)` を数える約束のため）。
    func testBlankLinesAreCounted() throws {
        let url = try write("a\n\n\nb\n")
        let (lines, stats) = try collectLines(url)
        XCTAssertEqual(lines, ["a", "", "", "b"])
        XCTAssertEqual(stats.lines, 4)
    }

    // MARK: - チャンク境界（本番）

    /// **16MB の境界をまたぐファイル**を実際に作って、1 行も落とさず・二重にも数えない
    /// ことを確かめる。行長をわざと 16MB の約数でない値にして、境界が行の途中に来るようにする。
    func testChunkBoundaryDoesNotSplitOrDuplicateLines() throws {
        let lineCount = 3_000_000
        var text = ""
        text.reserveCapacity(lineCount * 15)
        for i in 0..<lineCount { text += "line\(i)\n" }        // 約 37MB ＝ 3 チャンク
        let url = try write(text, name: "big.log")

        let (lines, stats) = try collectLines(url)
        XCTAssertEqual(stats.lines, lineCount)
        XCTAssertEqual(lines.count, lineCount)
        // 端と、境界のあたりを抜き取りで確かめる（全件比較は遅いので）。
        XCTAssertEqual(lines.first, "line0")
        XCTAssertEqual(lines.last, "line\(lineCount - 1)")
        for i in stride(from: 0, to: lineCount, by: 97_777) {
            XCTAssertEqual(lines[i], "line\(i)", "\(i) 行目がずれている")
        }
        XCTAssertGreaterThan(stats.bytes, ScanEngine.chunkSize, "チャンク境界を跨いでいない＝試験になっていない")
    }

    /// チャンクごとの行数の合計が全体の行数と一致する（全体の行番号はこの前方累和で作る）。
    func testChunkLineCountsSumToTotal() throws {
        // 16MB を必ず超える長さにする（下の assert が「試験になっていない」を弾く）。
        var text = ""
        for i in 0..<2_000_000 { text += "line\(i)\n" }     // 約 22MB ＝ 2 チャンク
        let url = try write(text, name: "counts.log")

        let engine = ScanEngine()
        let exp = expectation(description: "counts")
        var counts: [Int] = []
        var total = 0
        engine.scan(url: url,
                    makeSink: { _ in 0 },
                    consume: { (n: inout Int, _, _) in n += 1 },
                    progress: { _ in },
                    completion: { sinks, chunkCounts, stats in
                        counts = chunkCounts
                        total = stats.lines
                        XCTAssertEqual(sinks.reduce(0, +), stats.lines)
                        exp.fulfill()
                    })
        wait(for: [exp], timeout: 60)
        XCTAssertEqual(counts.reduce(0, +), total)
        XCTAssertEqual(total, 2_000_000)
        XCTAssertGreaterThan(counts.count, 1, "1 チャンクに収まっている＝試験になっていない")
    }

    // MARK: - キャンセル

    /// 打ち切ったら completion は呼ばない（古い結果で画面を上書きしないため）。
    func testCancelSuppressesCompletion() throws {
        var text = ""
        for i in 0..<2_000_000 { text += "line\(i)\n" }
        let url = try write(text, name: "cancel.log")

        let engine = ScanEngine()
        let notCalled = expectation(description: "completion は呼ばれない")
        notCalled.isInverted = true
        engine.scan(url: url,
                    makeSink: { _ in 0 },
                    consume: { (n: inout Int, _, _) in n += 1 },
                    progress: { _ in },
                    completion: { _, _, _ in notCalled.fulfill() })
        engine.cancel()
        wait(for: [notCalled], timeout: 3)
    }

    // MARK: - 進捗

    func testProgressIsReported() throws {
        var text = ""
        for i in 0..<3_000_000 { text += "line\(i)\n" }
        let url = try write(text, name: "progress.log")

        let engine = ScanEngine()
        let done = expectation(description: "done")
        var seen: [Double] = []
        engine.scan(url: url,
                    makeSink: { _ in 0 },
                    consume: { (n: inout Int, _, _) in n += 1 },
                    progress: { seen.append($0) },
                    completion: { _, _, _ in done.fulfill() })
        wait(for: [done], timeout: 60)
        XCTAssertTrue(seen.allSatisfy { $0 >= 0 && $0 <= 1 }, "進捗が 0…1 の外に出た: \(seen)")
    }
}