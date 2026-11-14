import XCTest
@testable import MrEditorCore

/// C2「列の統計」の試験。
///
/// **この機能の嘘は静かに出る**（型を勝手に決める・空欄を落とす・列がズレる）ので、
/// 縛るのは数字そのものよりも「勝手に決めていないこと」に寄せてある。
final class ColumnStatsRunnerTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrkpro-cols-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ text: String, name: String = "t.csv") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func doc(_ url: URL?,
                     text: String? = nil,
                     columns: [String],
                     originalIndices: [Int]? = nil,
                     structured: StructuredMode = .csv,
                     filter: [Int]? = nil,
                     encoding: DetectedEncoding = .utf8) -> ActiveDocument {
        ActiveDocument(fileURL: url, encoding: encoding, structuredMode: structured,
                       columnNames: columns, columnWidths: [:],
                       columnOriginalIndices: originalIndices ?? Array(columns.indices),
                       text: text, filterMatchLines: filter)
    }

    @discardableResult
    private func run(_ document: ActiveDocument,
                     cap: Int = ColumnStatsRunner.defaultUniqueCap) -> ColumnStatsRunner.Result {
        let runner = ColumnStatsRunner()
        let exp = expectation(description: "columnStats")
        var out = ColumnStatsRunner.Result()
        runner.run(document: document, cap: cap, progress: { _ in },
                   completion: { out = $0; exp.fulfill() })
        wait(for: [exp], timeout: 60)
        return out
    }

    // MARK: - 基本

    func testCountsEveryColumnInOnePass() throws {
        let url = try write("""
        pref,city,pop
        北海道,釧路市,165000
        北海道,伊達市,33000
        東京都,港区,260000

        """)
        let r = run(doc(url, columns: ["pref", "city", "pop"]))

        XCTAssertEqual(r.scannedLines, 3, "ヘッダを数えている")
        XCTAssertEqual(r.columns.count, 3)

        let pref = r.columns[0]
        XCTAssertEqual(pref.kind, .text)
        XCTAssertEqual(pref.present, 3)
        XCTAssertEqual(pref.blank, 0)
        XCTAssertEqual(pref.distinct, 2)
        XCTAssertEqual(pref.top.first?.value, "北海道")
        XCTAssertEqual(pref.top.first?.count, 2)

        let pop = r.columns[2]
        XCTAssertEqual(pop.kind, .number)
        XCTAssertEqual(pop.sum, .integer(458_000))
        XCTAssertEqual(pop.average ?? 0, 458_000.0 / 3, accuracy: 0.001)
        XCTAssertEqual(pop.minText, "33000")
        XCTAssertEqual(pop.maxText, "260000")
    }

    /// 表示順が並べ替わっていても(B19)、値は正しい列に付く。**実機で踏んだ core 側と同じ罠**
    /// ── `columnOriginalIndices` で生セル位置へ引き直さないと、並べ替え後は列名と値がズレる
    /// （2026-09-25）。ファイル自体は raw のまま(pref,city,pop)だが、画面の並びは city,pref,pop。
    func testColumnOrderFollowsDisplayOrderNotRawFileOrder() throws {
        let url = try write("""
        pref,city,pop
        北海道,釧路市,165000
        東京都,港区,260000

        """)
        let r = run(doc(url, columns: ["city", "pref", "pop"], originalIndices: [1, 0, 2]))
        XCTAssertEqual(r.columns.map(\.name), ["city", "pref", "pop"])
        XCTAssertEqual(r.columns[0].minText, "港区")     // "city" 列の値(rawの2番目)
        XCTAssertEqual(r.columns[0].maxText, "釧路市")
        XCTAssertEqual(r.columns[1].distinct, 2)         // "pref" 列(rawの1番目)は 北海道/東京都
        XCTAssertEqual(r.columns[2].sum, .integer(425_000))  // "pop" は動いていない(raw位置と一致)
    }

    /// 空欄は**落とさずに別に数える**（9,604 件の空欄は知りたい情報）。
    func testBlankCellsAreCountedSeparately() throws {
        let url = try write("a,b\nx,1\n,2\n  ,3\n")
        let r = run(doc(url, columns: ["a", "b"]))
        XCTAssertEqual(r.columns[0].present, 1)
        XCTAssertEqual(r.columns[0].blank, 2, "空白だけの欄も空欄")
        XCTAssertEqual(r.columns[0].distinct, 1, "空欄は異なる値に数えない")
    }

    /// 欄そのものが無い行（列数より短い行）は `missing` に入れる。**黙って捨てない。**
    func testShortRowsAreCountedAsMissing() throws {
        let url = try write("a,b,c\n1,2,3\n4,5\n")
        let r = run(doc(url, columns: ["a", "b", "c"]))
        XCTAssertEqual(r.columns[2].present, 1)
        XCTAssertEqual(r.columns[2].missing, 1)
        XCTAssertEqual(r.scannedLines, 2)
    }

    // MARK: - 型（勝手に決めない）

    /// **1 行でも数として読めなければ `混在`。** 8 割ルールを使わない。
    func testOneNonNumericMakesTheColumnMixed() throws {
        let url = try write("n\n1\n2\n不明\n4\n")
        let r = run(doc(url, columns: ["n"]))
        XCTAssertEqual(r.columns[0].kind, .mixed)
        XCTAssertEqual(r.columns[0].numeric, 3)
        XCTAssertEqual(r.columns[0].nonNumeric, 1)
        XCTAssertNil(r.columns[0].sum, "混在の列に合計を出してはいけない")
    }

    /// 先頭ゼロのある数字（郵便番号）は**文字列**。数値にするとゼロが落ちて別物になる。
    func testLeadingZeroNumbersAreText() throws {
        let url = try write("zip\n0520021\n0850824\n1000001\n")
        let r = run(doc(url, columns: ["zip"]))
        XCTAssertEqual(r.columns[0].kind, .mixed, "0 始まりは文字列側なので数値と混ざる")
        XCTAssertEqual(r.columns[0].numeric, 1)
        XCTAssertEqual(r.columns[0].minText, "0520021", "辞書順の最小がそのまま出る")
    }

    func testAllBlankColumnIsEmpty() throws {
        let url = try write("a,b\n1,\n2,\n")
        let r = run(doc(url, columns: ["a", "b"]))
        XCTAssertEqual(r.columns[1].kind, .empty)
        XCTAssertEqual(r.columns[1].blank, 2)
    }

    func testIso8601ColumnIsDatetime() throws {
        let url = try write("""
        at,msg
        2026-08-01T12:00:00Z,a
        2026-08-03T09:30:00Z,b
        2026-08-02T22:10:00Z,c

        """)
        let r = run(doc(url, columns: ["at", "msg"]))
        XCTAssertEqual(r.columns[0].kind, .datetime)
        XCTAssertEqual(r.columns[0].minText, "2026-08-01T12:00:00Z")
        XCTAssertEqual(r.columns[0].maxText, "2026-08-03T09:30:00Z", "日時は日時として比べる")
    }

    /// **13 桁の昇順 ID をエポックミリ秒と読まない。**
    /// 国税庁の法人番号 CSV は法人番号が昇順に並んでいて、単調増加の条件を通ってしまう。
    func testSortedThirteenDigitIdsAreNotDatetime() throws {
        var text = "id\n"
        for i in 0..<200 { text += "\(1_000_012_160_153 + i * 7)\n" }
        let url = try write(text)
        let r = run(doc(url, columns: ["id"]))
        XCTAssertEqual(r.columns[0].kind, .number, "ID 列を日時と言い切ってはいけない")
    }

    /// 合計が Int の桁を越えたら、**近い数を出さずに「出せない」と言う。**
    func testIntegerSumOverflowIsReported() throws {
        let big = String(Int.max - 10)
        let url = try write("n\n\(big)\n\(big)\n")
        let r = run(doc(url, columns: ["n"]))
        XCTAssertEqual(r.columns[0].kind, .number)
        XCTAssertEqual(r.columns[0].sum, .overflow)
    }

    // MARK: - 対象（C1 と同じ規則）

    func testRespectsFilterMatchLines() throws {
        let url = try write("a\nx\ny\nz\n")
        // 0 始まり。行 0 はヘッダなので、行 2（"y"）だけが対象。
        let r = run(doc(url, columns: ["a"], filter: [2]))
        XCTAssertEqual(r.scannedLines, 1)
        XCTAssertEqual(r.columns[0].top.map(\.value), ["y"])
    }

    func testWorksOnInMemoryText() {
        let text = "a,b\n1,x\n2,y\n"
        let r = run(doc(nil, text: text, columns: ["a", "b"]))
        XCTAssertEqual(r.scannedLines, 2)
        XCTAssertEqual(r.columns[0].kind, .number)
        XCTAssertEqual(r.columns[1].distinct, 2)
    }

    /// 構造化していない（列が無い）ファイルでは何も出さない。**列を発明しない。**
    func testWithoutColumnsProducesNothing() throws {
        let url = try write("just a log line\n")
        let r = run(ActiveDocument(fileURL: url, encoding: .utf8, structuredMode: nil,
                                   columnNames: [], columnWidths: [:], columnOriginalIndices: [], text: nil, filterMatchLines: nil))
        XCTAssertTrue(r.columns.isEmpty)
    }

    // MARK: - 上限

    func testUniqueCapIsReported() throws {
        var text = "id,k\n"
        for i in 0..<5000 { text += "\(i),\(i % 3)\n" }
        let url = try write(text, name: "many.csv")
        let r = run(doc(url, columns: ["id", "k"]), cap: 640)
        XCTAssertTrue(r.columns[0].distinctTruncated, "打ち切ったことを言っていない")
        XCTAssertLessThan(r.columns[0].distinct, 5000)
        XCTAssertFalse(r.columns[1].distinctTruncated, "3 種類の列まで打ち切ってはいけない")
        XCTAssertEqual(r.columns[1].distinct, 3)
    }

    // MARK: - チャンク境界（16MB を越える実ファイル）

    func testCountsSurviveChunkBoundary() throws {
        var text = "n,tag\n"
        for i in 0..<1_500_000 { text += "\(i),t\(i % 4)\n" }        // 約 20MB ＝ 2 チャンク
        let url = try write(text, name: "big.csv")
        let r = run(doc(url, columns: ["n", "tag"]))
        XCTAssertEqual(r.scannedLines, 1_500_000)
        XCTAssertEqual(r.columns[0].present, 1_500_000)
        XCTAssertEqual(r.columns[0].kind, .number)
        XCTAssertEqual(r.columns[0].sum, .integer((0..<1_500_000).reduce(0, +)))
        XCTAssertEqual(r.columns[1].distinct, 4)
        XCTAssertEqual(r.columns[1].top.map(\.count), [375_000, 375_000, 375_000])
    }

    // MARK: - 切り方（画面・C1・C2 でズレないこと）

    /// 行の切り方は `TabularFormatter.splitDelimited`（＝画面）と**同じでなければならない**。
    func testRowScannerMatchesTabularFormatter() {
        let lines = [
            #"a,b,c"#,
            #""a,b",c,d"#,
            #"a,"b""c",d"#,
            #",,"#,
            #"a,,c"#,
            #""",x,"y""#,
            #"末尾が空,"#,
        ]
        for line in lines {
            let expected = TabularFormatter.splitDelimited(line, sep: ",", csvQuotes: true)
            var got = [String](repeating: "<none>", count: expected.count)
            let bytes = Array(line.utf8)
            bytes.withUnsafeBufferPointer { buf in
                CSVRowScanner.forEachField(in: buf, separator: UInt8(ascii: ","),
                                           quoted: true, limit: expected.count) { j, range in
                    got[j] = CSVFieldScanner.decode(buf, range: range, unquote: true)
                }
            }
            XCTAssertEqual(got, expected, "画面と列がズレる: \(line)")
        }
    }

    // MARK: - 数値の読み方（純関数）

    func testNumericFieldParsing() {
        XCTAssertEqual(NumericField.parse("42"), .integer(42))
        XCTAssertEqual(NumericField.parse("-7"), .integer(-7))
        XCTAssertEqual(NumericField.parse("+7"), .integer(7))
        XCTAssertEqual(NumericField.parse("0"), .integer(0))
        XCTAssertEqual(NumericField.parse("3.5"), .real(3.5))
        XCTAssertEqual(NumericField.parse("0.5"), .real(0.5))
        XCTAssertEqual(NumericField.parse("1e3"), .real(1000))

        XCTAssertNil(NumericField.parse("007"), "先頭ゼロは文字列")
        XCTAssertNil(NumericField.parse(""))
        XCTAssertNil(NumericField.parse("12ab"))
        XCTAssertNil(NumericField.parse("1,234"), "桁区切りは数値にしない")
        XCTAssertNil(NumericField.parse("3件"))
        XCTAssertNil(NumericField.parse("-"))
        XCTAssertNil(NumericField.parse("1e"))
        XCTAssertNil(NumericField.parse("NaN"))
        XCTAssertNil(NumericField.parse("inf"))

        // Int に収まらない桁は Double へ落とす（読めなくはしない）。
        if case .real = NumericField.parse("99999999999999999999")! {} else {
            XCTFail("Int を越える桁は real で読む")
        }
    }
}