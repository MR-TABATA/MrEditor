import XCTest
@testable import MrEditor

/// ファイルを読んで束ねるところまで（`MergedLogBuilder`）。
///
/// 形式が**ファイルごとに違う**のが現実の使い方なので、そこを主眼に置く。
/// nginx（Apache 形式）とアプリログ（ISO）と DB（syslog）を一緒に束ねたとき、
/// 全体で1つの形式に決めつけると片方が丸ごと継続行になって時系列が崩れる。
final class MergedLogBuilderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("merge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func write(_ name: String, _ body: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try body.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    /// JST 固定で組み立てる（実行環境のタイムゾーンに結果を左右されないため）。
    private var builder: MergedLogBuilder {
        MergedLogBuilder(displayOffset: 9 * 3600, assumedOffset: 9 * 3600, assumedYear: 2026)
    }

    private let nginx = """
    10.0.1.4 - - [30/Jul/2026:12:34:55 +0900] "GET /health HTTP/1.1" 200 2
    10.0.1.9 - alice [30/Jul/2026:12:34:57 +0900] "POST /api/checkout HTTP/1.1" 500 512
    """

    private let app = """
    2026-07-30T12:34:56.120+09:00 INFO  checkout start order=88213
    2026-07-30T12:34:57.004+09:00 ERROR NullPointerException in Checkout.pay
        at com.example.Checkout.pay(Checkout.java:88)
    """

    private let db = """
    Jul 30 12:34:56 db-1 postgres[812]: LOG:  duration: 41.2 ms
    Jul 30 12:34:58 db-1 postgres[812]: LOG:  duration: 3208.9 ms
    """

    /// 3つの形式が混ざっていても、ファイルごとに判定して1本の時系列になる。
    func testMergesThreeDifferentFormats() throws {
        let a = try write("nginx-access.log", nginx)
        let b = try write("app.log", app)
        let c = try write("db-syslog.log", db)

        let r = try builder.build(urls: [a, b, c], into: dir)
        XCTAssertEqual(r.sources.map { $0.format },
                       [.apache, .iso8601, .syslog],
                       "形式はファイルごとに決めること")
        XCTAssertTrue(r.warnings.isEmpty)

        let body = try String(contentsOf: r.url, encoding: .utf8)
        let rows = body.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)

        // 12:34:55 nginx → 12:34:56.120 app → 12:34:56 db … の順に並ぶ
        let labels = rows.map { row -> String in
            let parts = row.split(separator: "│", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count >= 2 ? parts[1] : ""
        }
        XCTAssertEqual(labels, ["nginx-access", "db-syslog", "app", "nginx-access", "app", "app", "db-syslog"])
    }

    /// 出力の時刻欄が単調に増えること（＝並べ替えが効いている、の最短の確認）。
    func testOutputTimestampsAreMonotonic() throws {
        let a = try write("nginx-access.log", nginx)
        let b = try write("app.log", app)
        let r = try builder.build(urls: [a, b], into: dir)

        let stamps = try String(contentsOf: r.url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { String($0.prefix(23)) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(stamps, stamps.sorted(), "束ねた結果の時刻は増加していること")
    }

    /// 継続行は時刻欄を空にする。親の時刻を引き継いでいるだけなので、
    /// そこに数字を出すと「その行自身の時刻」に見えて嘘になる。
    func testContinuationLinesHaveBlankTimeColumn() throws {
        let a = try write("app.log", app)
        let b = try write("db-syslog.log", db)
        let r = try builder.build(urls: [a, b], into: dir)

        let stackLine = try String(contentsOf: r.url, encoding: .utf8)
            .split(separator: "\n")
            .first { $0.contains("Checkout.java:88") }
        XCTAssertNotNil(stackLine)
        XCTAssertTrue(String(stackLine!.prefix(23)).trimmingCharacters(in: .whitespaces).isEmpty,
                      "継続行の時刻欄は空であること")
    }

    /// 全行が必ず出力される（見出し行を除く）。
    func testEveryInputLineAppears() throws {
        let a = try write("nginx-access.log", nginx)
        let b = try write("app.log", app)
        let c = try write("db-syslog.log", db)
        let r = try builder.build(urls: [a, b, c], into: dir)

        let expected = nginx.split(separator: "\n").count
            + app.split(separator: "\n").count
            + db.split(separator: "\n").count
        XCTAssertEqual(r.totalLines, expected)
    }

    /// 同名ファイルはディレクトリ名で区別する。ホスト別に集めたログで必ず起きる。
    func testDuplicateBaseNamesGetParentDirectoryInLabel() throws {
        for host in ["web-1", "web-2"] {
            let sub = dir.appendingPathComponent(host)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try app.write(to: sub.appendingPathComponent("app.log"), atomically: true, encoding: .utf8)
        }
        let urls = ["web-1", "web-2"].map { dir.appendingPathComponent($0).appendingPathComponent("app.log") }
        let r = try builder.build(urls: urls, into: dir)
        XCTAssertEqual(r.sources.map { $0.label }, ["web-1/app", "web-2/app"])
    }

    /// 時刻を持たないファイルは末尾に回り、その旨を警告に出す（黙って混ぜない）。
    func testTimestamplessFileIsReportedAndPlacedLast() throws {
        let a = try write("app.log", app)
        let b = try write("notes.txt", "just some notes\nno timestamps at all\n")
        let r = try builder.build(urls: [a, b], into: dir)

        XCTAssertNil(r.sources[1].format)
        XCTAssertEqual(r.warnings.count, 1)
        XCTAssertTrue(r.warnings[0].contains("notes.txt"))

        let rows = try String(contentsOf: r.url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertTrue(rows.suffix(2).allSatisfy { $0.contains("notes") },
                      "時刻を持たない行は末尾に並ぶ")
    }

    /// テキストファイルは改行で終わるのが普通。その末尾改行から生まれる空行を残すと
    /// **ファイルの数だけラベルだけの空行が混ざる**（実機で見つけた）。
    func testTrailingNewlineDoesNotAddPhantomLine() throws {
        let a = try write("app.log", app + "\n")            // 改行で終わる
        let b = try write("db-syslog.log", db + "\n")
        let r = try builder.build(urls: [a, b], into: dir)

        XCTAssertEqual(r.sources[0].lineCount, 3, "app.log は3行（幻の空行を数えない）")
        XCTAssertEqual(r.sources[1].lineCount, 2)
        XCTAssertEqual(r.totalLines, 5)

        let rows = try String(contentsOf: r.url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
        // 「時刻 │ ラベル │ 空」の行が無いこと
        for row in rows {
            let parts = row.split(separator: "│", maxSplits: 2, omittingEmptySubsequences: false)
            XCTAssertFalse(parts.count == 3 && parts[2].trimmingCharacters(in: .whitespaces).isEmpty,
                           "本文が空の行が残っている: \(row)")
        }
    }

    func testRefusesSingleFile() throws {
        let a = try write("app.log", app)
        XCTAssertThrowsError(try builder.build(urls: [a], into: dir))
    }

    /// Shift-JIS のログも読める（既存の文字コード判定を通す）。
    func testReadsShiftJISInput() throws {
        let u = dir.appendingPathComponent("sjis.log")
        let text = "2026-07-30T12:34:56+09:00 エラー 在庫が足りません\n"
        try text.data(using: .shiftJIS)!.write(to: u)
        let b = try write("app.log", app)

        let r = try builder.build(urls: [u, b], into: dir)
        let body = try String(contentsOf: r.url, encoding: .utf8)
        XCTAssertTrue(body.contains("在庫が足りません"), "Shift-JIS が文字化けせず読めること")
    }
}
