import XCTest
@testable import MrEditorCore

/// 時刻の読み取り速度を測る。普段は skip。
/// `MREDITOR_BENCH=1 swift test --filter TimestampBench` で走る。
///
/// 時刻マージは「複数のログを全部読んで並べ直す」ので、1行あたりのコストが
/// そのまま体感になる。索引 9 秒の隣に置いて恥ずかしくない速度かをここで見る。
/// 公表値を勘で書かないための計測。
final class TimestampBenchTests: XCTestCase {

    /// 2桁・3桁のゼロ詰め。`String(format:)` を使わないための小道具。
    private func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// 実ログに近い分布（時刻あり8割・継続行2割）を組み立てる。
    ///
    /// ⚠️ **`String(format:)` を使ってはいけない。** 返ってくるのは NSString 由来の
    /// 文字列で、Swift ネイティブの連続バッファを持たない。`withUTF8` がそのたびに
    /// コピーを作るため、測っているのが自分のコードでなく**橋渡しの費用**になる
    /// （実測 2026-08-04: **1.26 → 11.73 M行/s**。9倍の差が全部これだった）。
    /// 実運用の行は自前のファイル読み込みから来るのでネイティブ。補間で組み立てる。
    private func makeLines(_ count: Int) -> [String] {
        var lines: [String] = []
        lines.reserveCapacity(count)
        for i in 0..<count {
            if i % 5 == 4 {
                lines.append("    at com.example.Service.handle(Service.java:\(i % 400))")
            } else {
                let s = 1_785_414_896 + i / 3
                let t = TimestampDetector.civilFromDays(s / 86_400)
                let rem = s % 86_400
                lines.append("\(t.year)-\(pad(t.month, 2))-\(pad(t.day, 2))T"
                             + "\(pad(rem / 3600, 2)):\(pad((rem % 3600) / 60, 2)):\(pad(rem % 60, 2))"
                             + ".\(pad(i % 1000, 3))Z INFO request id=\(i) done in \(i % 900)ms")
            }
        }
        return lines
    }

    func testParseAllThroughput() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1 で時刻読み取りのベンチを実行")
        }
        let n = 2_000_000
        let lines = makeLines(n)
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: 0)

        let t0 = Date()
        let times = d.parseAll(lines)
        let sec = Date().timeIntervalSince(t0)

        let hits = times.compactMap { $0 }.count
        print(String(format: "parseAll: %.3f 秒 / %d 行 (%.2f M行/s・命中 %d)",
                     sec, n, Double(n) / sec / 1_000_000, hits))
        XCTAssertEqual(times.count, n)
    }

    func testMergeThroughput() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1 で統合のベンチを実行")
        }
        let per = 500_000
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: 0)
        let sources = (0..<4).map { k in
            LogMerger.Source(label: "host-\(k)",
                             times: d.parseAll(makeLines(per)),
                             clockOffset: Double(k))
        }

        let t0 = Date()
        let merged = LogMerger.merge(sources)
        let sec = Date().timeIntervalSince(t0)

        print(String(format: "merge: %.3f 秒 / %d 行 × %d 本 (%.2f M行/s)",
                     sec, per, sources.count, Double(merged.count) / sec / 1_000_000))
        XCTAssertEqual(merged.count, per * sources.count)
    }

    /// 実ファイルで測る。`testdata/test_50mb_jp.log` があれば使う。
    func testRealFileThroughput() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1 で実ファイルのベンチを実行")
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("testdata/test_50mb_jp.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("testdata/test_50mb_jp.log がない")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let t0 = Date()
        let detector = TimestampDetector.detect(sampleLines: Array(lines.prefix(200)))
        let detectSec = Date().timeIntervalSince(t0)

        guard let detector else {
            print("実ファイル: 時刻形式を検出せず（\(lines.count) 行）")
            return
        }
        let t1 = Date()
        let times = detector.parseAll(lines)
        let sec = Date().timeIntervalSince(t1)
        let hits = times.compactMap { $0 }.count
        print(String(format: "実ファイル(%@): 判定 %.4f 秒 / parseAll %.3f 秒 / %d 行 (%.2f M行/s・命中率 %.1f%%)",
                     detector.format.rawValue, detectSec, sec, lines.count,
                     Double(lines.count) / sec / 1_000_000,
                     Double(hits) / Double(lines.count) * 100))
    }
}
