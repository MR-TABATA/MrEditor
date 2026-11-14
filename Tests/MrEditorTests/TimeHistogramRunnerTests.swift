import XCTest
@testable import MrEditorCore

/// C3「時間分布」の試験。
///
/// ここで縛るのは主に **「捨てない・逆算しない・勝手に決めない」**の 3 つ。
/// 数が合っているだけでは足りない（時刻の無い行を落とす、棒から行番号を逆算する、
/// 年やオフセットを黙って補う、のどれをやっても静かに嘘になる）。
final class TimeHistogramRunnerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrkpro-time-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ text: String, name: String = "t.log") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func doc(_ url: URL?, text: String? = nil, filter: [Int]? = nil) -> ActiveDocument {
        ActiveDocument(fileURL: url, encoding: .utf8, structuredMode: nil,
                       columnNames: [], columnWidths: [:], columnOriginalIndices: [], text: text, filterMatchLines: filter)
    }

    private func utc(_ hours: Int = 0) -> TimeHistogramRunner.Options {
        var options = TimeHistogramRunner.Options()
        options.timeZoneOffset = hours * 3600
        options.displayOffset = hours * 3600
        return options
    }

    @discardableResult
    private func run(_ document: ActiveDocument,
                     _ options: TimeHistogramRunner.Options? = nil) -> TimeHistogramRunner.Result {
        let runner = TimeHistogramRunner()
        let exp = expectation(description: "histogram")
        var out = TimeHistogramRunner.Result()
        runner.run(document: document, options: options ?? utc(),
                   progress: { _ in }, completion: { out = $0; exp.fulfill() })
        wait(for: [exp], timeout: 60)
        return out
    }

    private func pick(_ document: ActiveDocument,
                      _ range: Range<Int>,
                      _ options: TimeHistogramRunner.Options? = nil,
                      cap: Int = 1_000_000) -> (lines: [Int], capped: Bool) {
        let runner = TimeHistogramRunner()
        let exp = expectation(description: "lines")
        var out: ([Int], Bool) = ([], false)
        runner.lines(in: range, document: document, options: options ?? utc(), cap: cap,
                     progress: { _ in }, completion: { out = ($0, $1); exp.fulfill() })
        wait(for: [exp], timeout: 60)
        return out
    }

    // MARK: - 基本

    func testCountsLinesPerBucket() throws {
        // 12:00:00 から 1 秒おきに 600 行（＝10 分）。
        var text = ""
        for i in 0..<600 {
            text += "2026-07-01T12:\(String(format: "%02d", i / 60)):\(String(format: "%02d", i % 60)).000Z ok\n"
        }
        let r = run(doc(try write(text)))
        XCTAssertEqual(r.format, .iso8601)
        XCTAssertEqual(r.timedLines, 600)
        XCTAssertEqual(r.untimedLines, 0)
        XCTAssertEqual(r.buckets.reduce(0) { $0 + $1.count }, 600, "棒の合計が行数と合わない")
        XCTAssertLessThanOrEqual(r.buckets.count, 200)
        XCTAssertGreaterThan(r.buckets.count, 1)
    }

    /// **時刻を持たない行を捨てない**（スタックトレースの継続行）。
    func testLinesWithoutTimestampAreCounted() throws {
        let text = """
        2026-07-01T12:00:00.000Z boom
            at com.example.A.run(A.java:1)
            at com.example.B.run(B.java:2)
        2026-07-01T12:00:01.000Z ok

        """
        let r = run(doc(try write(text)))
        XCTAssertEqual(r.timedLines, 2)
        XCTAssertEqual(r.untimedLines, 2)
        XCTAssertEqual(r.scannedLines, 4)
    }

    func testEmptyWhenNoTimestampsAtAll() throws {
        let r = run(doc(try write("just a line\nand another\n")))
        XCTAssertNil(r.format)
        XCTAssertTrue(r.buckets.isEmpty)
    }

    /// 年を持たない形式（syslog）は、**指定された年**で読む（勝手に今年にしない）。
    func testSyslogUsesSuppliedYear() throws {
        let text = """
        Jul  1 12:00:00 host app: one
        Jul  1 12:00:30 host app: two
        Jul  1 12:01:00 host app: three

        """
        var options = utc()
        options.assumedYear = 2019
        let r = run(doc(try write(text)), options)
        XCTAssertEqual(r.format, .syslog)
        XCTAssertTrue(r.suppliedYear, "年を補ったことを言っていない")
        let (year, _, _) = TimestampDetector.civilFromDays(Int(floor(Double(r.minSecond) / 86400)))
        XCTAssertEqual(year, 2019)
    }

    /// 行にオフセットが無いときは、**指定されたオフセット**で読む。
    func testOffsetIsAppliedWhenLineHasNone() throws {
        let text = "2026-07-01T12:00:00.000 a\n2026-07-01T12:00:01.000 b\n"
        let utcResult = run(doc(try write(text)), utc(0))
        let jstResult = run(doc(try write(text, name: "jst.log")), utc(9))
        XCTAssertEqual(utcResult.minSecond - jstResult.minSecond, 9 * 3600,
                       "オフセットの指定が効いていない")
    }

    // MARK: - バケット幅（純関数）

    func testBucketWidthPicksTheFinestThatFits() {
        XCTAssertEqual(TimeHistogramRunner.bucketWidth(span: 100, maxBars: 200), 1)
        XCTAssertEqual(TimeHistogramRunner.bucketWidth(span: 600, maxBars: 200), 5)
        XCTAssertEqual(TimeHistogramRunner.bucketWidth(span: 3600, maxBars: 200), 30)
        // 12 日 ＝ 1 時間だと 290 本で読めない。仕様の階段に足した 2 時間が選ばれる。
        XCTAssertEqual(TimeHistogramRunner.bucketWidth(span: 12 * 86400, maxBars: 200), 7200)
        XCTAssertEqual(TimeHistogramRunner.bucketWidth(span: 0, maxBars: 200), 1)
    }

    func testFloorToRespectsDisplayOffset() {
        // JST の 1 日は UTC の 15:00 に始まる。
        let jstMidnight = 1_782_000_000 - (1_782_000_000 + 9 * 3600) % 86400
        XCTAssertEqual(TimeHistogramRunner.floorTo(1_782_000_000, width: 86400, offset: 9 * 3600),
                       jstMidnight)
    }

    // MARK: - 時間帯で行を選ぶ

    /// 選んだ時間帯に**実際に入る行だけ**を返す（0 始まり）。
    func testPicksExactLinesInRange() throws {
        var text = ""
        for i in 0..<10 {
            text += "2026-07-01T12:00:\(String(format: "%02d", i)).000Z line\(i)\n"
        }
        let url = try write(text)
        let base = 1_782_000_000       // 使わない（下で実測値から作る）
        _ = base
        let r = run(doc(url))
        let from = r.minSecond + 3
        let (lines, capped) = pick(doc(url), from..<(from + 2))
        XCTAssertEqual(lines, [3, 4])
        XCTAssertFalse(capped)
    }

    /// **棒から行番号を逆算しない**ことの試験。時刻が前後するログでは、同じ時間帯の行が
    /// 連続していない。逆算していれば、間に挟まった別の時間帯の行まで拾ってしまう。
    func testPicksScatteredLinesWhenLogIsNotSorted() throws {
        let text = """
        2026-07-01T12:00:00.000Z a
        2026-07-01T13:00:00.000Z b
        2026-07-01T12:00:01.000Z c
        2026-07-01T13:00:01.000Z d
        2026-07-01T12:00:02.000Z e

        """
        let url = try write(text)
        let r = run(doc(url))
        let (lines, _) = pick(doc(url), r.minSecond..<(r.minSecond + 60))
        XCTAssertEqual(lines, [0, 2, 4], "連続しない行を拾えていない（逆算している）")
    }

    func testPickRespectsCap() throws {
        var text = ""
        for i in 0..<1000 { text += "2026-07-01T12:00:00.\(String(format: "%03d", i)) x\n" }
        let url = try write(text)
        let r = run(doc(url))
        let (lines, capped) = pick(doc(url), r.minSecond..<(r.minSecond + 60), cap: 100)
        XCTAssertEqual(lines.count, 100)
        XCTAssertTrue(capped, "上限に達したことを言っていない")
    }

    // MARK: - 対象（C1・C2 と同じ規則）

    func testRespectsFilterMatchLines() throws {
        let text = """
        2026-07-01T12:00:00.000Z a
        2026-07-01T12:00:01.000Z b
        2026-07-01T12:00:02.000Z c

        """
        let r = run(doc(try write(text), filter: [1]))
        XCTAssertEqual(r.timedLines, 1)
        XCTAssertEqual(r.buckets.reduce(0) { $0 + $1.count }, 1)
    }

    func testWorksOnInMemoryText() {
        let text = "2026-07-01T12:00:00.000Z a\n2026-07-01T12:30:00.000Z b\n"
        let r = run(doc(nil, text: text))
        XCTAssertEqual(r.timedLines, 2)
        XCTAssertEqual(r.buckets.reduce(0) { $0 + $1.count }, 2)
    }

    // MARK: - チャンク境界（16MB を越える実ファイル）

    func testSurvivesChunkBoundary() throws {
        var text = ""
        for i in 0..<400_000 {
            let sec = i % 60, minute = (i / 60) % 60, hour = (i / 3600) % 24
            text += "2026-07-01T\(String(format: "%02d:%02d:%02d", hour, minute, sec)).000Z "
                + "request_id=\(i) status=200 padding=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n"
        }
        let url = try write(text, name: "big.log")          // 約 34MB ＝ 3 チャンク
        let r = run(doc(url))
        XCTAssertEqual(r.timedLines, 400_000)
        XCTAssertEqual(r.buckets.reduce(0) { $0 + $1.count }, 400_000)

        // チャンクを跨いだ行番号が正しいこと（最後の 1 秒＝末尾のほうの行）。
        let (lines, _) = pick(doc(url), r.maxSecond..<(r.maxSecond + 1))
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0 >= 0 && $0 < 400_000 })
        XCTAssertEqual(lines, lines.sorted(), "行番号が昇順でない")
    }
}