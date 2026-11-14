import XCTest
@testable import MrEditorCore

/// 集計の通し試験。**「何を対象にしたか」がずれると、正しい数を出しても嘘になる**ので、
/// ヘッダ行・フィルタ・小ファイル経路をそれぞれ縛る。
final class AggregateRunnerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrkpro-agg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ text: String, name: String = "t.log") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func doc(_ url: URL?,
                     text: String? = nil,
                     structured: StructuredMode? = nil,
                     columns: [String] = [],
                     filter: [Int]? = nil,
                     encoding: DetectedEncoding = .utf8) -> ActiveDocument {
        ActiveDocument(fileURL: url, encoding: encoding, structuredMode: structured,
                       columnNames: columns, columnWidths: [:], columnOriginalIndices: Array(columns.indices), text: text, filterMatchLines: filter)
    }

    private func run(_ document: ActiveDocument,
                     _ mode: ValueExtractor.Mode,
                     cap: Int = ShardedCounter.defaultCap) -> AggregateRunner.Result {
        let runner = AggregateRunner()
        let exp = expectation(description: "aggregate")
        var out = AggregateRunner.Result()
        runner.run(document: document, mode: mode, options: .init(), cap: cap,
                   progress: { _ in },
                   completion: { out = $0; exp.fulfill() })
        wait(for: [exp], timeout: 60)
        return out
    }

    // MARK: - 基本

    func testCountsKeyValueFromFile() throws {
        let url = try write("""
        a status=200
        b status=500
        c status=200
        d status=200

        """)
        let r = run(doc(url), .keyValue(key: "status"))
        XCTAssertEqual(r.rows.map(\.value), ["200", "500"])
        XCTAssertEqual(r.rows.map(\.count), [3, 1])
        XCTAssertEqual(r.scannedLines, 4)
        XCTAssertEqual(r.matchedLines, 4)
        XCTAssertEqual(r.distinctCount, 2)
        XCTAssertEqual(r.truncatedRows, 0)
    }

    /// 値が取れない行は `(該当なし)` として数え、**黙って捨てない**。
    func testLinesWithoutValueAreCountedAsMissing() throws {
        let url = try write("status=200\nno key here\n")
        let r = run(doc(url), .keyValue(key: "status"))
        XCTAssertEqual(r.scannedLines, 2)
        XCTAssertEqual(r.matchedLines, 1)
        XCTAssertEqual(r.rows.first(where: { $0.value == ValueExtractor.missing })?.count, 1)
    }

    /// CSV の構造化表示中はヘッダ行（1 行目）を数えない（画面もヘッダとして扱っている）。
    func testSkipsHeaderRowWhenStructured() throws {
        let url = try write("pref,city\n北海道,釧路市\n北海道,伊達市\n東京都,港区\n")
        let r = run(doc(url, structured: .csv, columns: ["pref", "city"]),
                    .column(index: 0, mode: .csv))
        XCTAssertEqual(r.scannedLines, 3, "ヘッダを数えている")
        XCTAssertEqual(r.rows.map(\.value), ["北海道", "東京都"])
        XCTAssertEqual(r.rows.map(\.count), [2, 1])
    }

    /// 構造化していなければヘッダも 1 行として数える（勝手に落とさない）。
    func testDoesNotSkipFirstLineWhenNotStructured() throws {
        let url = try write("pref\n北海道\n北海道\n")
        let r = run(doc(url), .wholeLine)
        XCTAssertEqual(r.scannedLines, 3)
    }

    // MARK: - フィルタ中

    /// フィルタ中は**一致行だけ**を数える。行番号は 0 始まり。
    func testCountsOnlyFilteredLines() throws {
        let url = try write("""
        status=200
        status=500
        status=200
        status=404

        """)
        let r = run(doc(url, filter: [1, 3]), .keyValue(key: "status"))
        XCTAssertEqual(r.scannedLines, 2)
        XCTAssertEqual(Set(r.rows.map(\.value)), ["500", "404"])
        XCTAssertEqual(r.rows.map(\.count), [1, 1])
    }

    /// **16MB を越える実ファイル**でもフィルタが効く（チャンクを跨いで行番号が続く）。
    func testFilterWorksAcrossChunkBoundary() throws {
        var text = ""
        for i in 0..<2_000_000 { text += "id=\(i % 7) line\(i)\n" }   // 約 26MB ＝ 2 チャンク
        let url = try write(text, name: "big.log")

        // 最後のほうの 3 行だけを対象にする（＝2 つ目のチャンクにある）。
        let filter = [1_999_997, 1_999_998, 1_999_999]
        let r = run(doc(url, filter: filter), .keyValue(key: "id"))
        XCTAssertEqual(r.scannedLines, 3)
        let expected = filter.map { String($0 % 7) }
        XCTAssertEqual(r.rows.reduce(0) { $0 + $1.count }, 3)
        XCTAssertEqual(Set(r.rows.map(\.value)), Set(expected))
    }

    // MARK: - 小ファイル（本文が手元にある経路）

    func testCountsFromInMemoryText() {
        let text = "status=200\nstatus=200\nstatus=500\n"
        let r = run(doc(nil, text: text), .keyValue(key: "status"))
        XCTAssertEqual(r.rows.map(\.value), ["200", "500"])
        XCTAssertEqual(r.rows.map(\.count), [2, 1])
        XCTAssertEqual(r.scannedLines, 3)
    }

    func testInMemoryTextRespectsFilter() {
        let text = "a\nb\nc\n"
        let r = run(doc(nil, text: text, filter: [2]), .wholeLine)
        XCTAssertEqual(r.scannedLines, 1)
        XCTAssertEqual(r.rows.map(\.value), ["c"])
    }

    // MARK: - 打ち切り

    /// 上限を超えたら打ち切り、**打ち切った行数を数える**（「まとめました」と言えるように）。
    func testTruncationIsReported() throws {
        var text = ""
        for i in 0..<5000 { text += "id=\(i)\n" }
        let url = try write(text, name: "many.log")
        let r = run(doc(url), .keyValue(key: "id"), cap: 640)
        XCTAssertGreaterThan(r.truncatedRows, 0)
        XCTAssertLessThan(r.distinctCount, 5000)
        XCTAssertEqual(r.rows.reduce(0) { $0 + $1.count } + r.truncatedRows, 5000,
                       "数えた件数と打ち切った件数の合計が、行数と合わない")
    }

    // MARK: - 打ち切り（キャンセル）

    func testCancelSuppressesCompletion() throws {
        var text = ""
        for i in 0..<2_000_000 { text += "id=\(i % 5)\n" }
        let url = try write(text, name: "cancel.log")

        let runner = AggregateRunner()
        let notCalled = expectation(description: "completion は呼ばれない")
        notCalled.isInverted = true
        runner.run(document: doc(url), mode: .keyValue(key: "id"), options: .init(),
                   progress: { _ in }, completion: { _ in notCalled.fulfill() })
        runner.cancel()
        wait(for: [notCalled], timeout: 3)
    }
}
/// `key=value` のキー候補の並び。**既定で選ばれるキーが「数えて意味のあるもの」**である
/// ことを縛る（実機で最初に選ばれたのが request_id で、開いた瞬間に打ち切りの赤帯が出た）。
extension AggregateRunnerTests {

    func testKeyCandidatesAreOrderedByFewestDistinctValues() throws {
        var text = ""
        for i in 0..<200 {
            text += "request_id=\(i) status=\(i % 3 == 0 ? 500 : 200) region=ap-northeast-1\n"
        }
        let url = try write(text, name: "keys.log")
        let keys = KeySampler.keys(in: doc(url))
        XCTAssertEqual(keys.first, "region", "種類が 1 つのキーが先頭に来ていない")
        XCTAssertEqual(keys.last, "request_id", "ID のようなキーが先頭に来ている")
        XCTAssertTrue(keys.contains("status"))
    }
}
