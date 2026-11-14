import XCTest
@testable import MrEditorCore

/// 値の取り出しの試験。
///
/// **一番大事なのは「画面の列」と「数える列」が同じであること。** 表示は
/// `TabularFormatter.splitDelimited`（core・String 経路）で切っていて、集計は速度のために
/// バイト経路で切る。2 つが同じ結果を返すことを、意地の悪い行で突き合わせて縛る。
final class ValueExtractorTests: XCTestCase {

    private let opts = ValueExtractor.Options()

    private func bytes<T>(_ s: String, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        var a = Array(s.utf8)
        return a.withUnsafeMutableBufferPointer { body(UnsafeBufferPointer($0)) }
    }

    private func column(_ line: String, _ index: Int, mode: StructuredMode = .csv) -> String {
        bytes(line) { ValueExtractor.value(from: $0, mode: .column(index: index, mode: mode), options: opts) }
    }

    // MARK: - 表示と同じ割り方か（本丸）

    func testByteSplitMatchesDisplaySplit() {
        let lines = [
            "a,b,c",
            "1,,3",                                   // 空欄
            "\"a,b\",c",                              // 引用符の中の区切り
            "\"he said \"\"hi\"\"\",x",               // "" のエスケープ
            "\"\",x",                                 // 空の引用符
            "北海道,釧路市,\"柏木町４－７\"",              // 日本語（マルチバイト）
            "a,b,",                                   // 末尾が空欄
            ",a",                                     // 先頭が空欄
            "a,\"b",                                  // 閉じていない引用符（壊れた CSV）
            "1000012160153,01,1,2018-04-02,\"釧路検察審査会\"",
        ]
        for line in lines {
            let expected = TabularFormatter.splitDelimited(line, sep: ",", csvQuotes: true)
            for i in 0..<expected.count {
                XCTAssertEqual(column(line, i), expectedValue(expected[i]),
                               "行 \(line) の \(i) 番目が表示と違う")
            }
            // 欄の数を超えたら「該当なし」。
            XCTAssertEqual(column(line, expected.count), ValueExtractor.missing, "行 \(line)")
        }
    }

    /// `splitDelimited` の生の値に、集計側の正規化（空欄の言い換え）を当てたもの。
    private func expectedValue(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? ValueExtractor.blank : t
    }

    func testTSVColumns() {
        XCTAssertEqual(column("a\tb\tc", 1, mode: .tsv), "b")
        XCTAssertEqual(column("a\t\tc", 1, mode: .tsv), ValueExtractor.blank)
    }

    // MARK: - key=value

    func testKeyValue() {
        let line = "2026-06-26 12:00:00 [INFO] request_id=42 status=200 path=/api/v1/users"
        XCTAssertEqual(kv(line, "status"), "200")
        XCTAssertEqual(kv(line, "request_id"), "42")
        XCTAssertEqual(kv(line, "path"), "/api/v1/users")
        XCTAssertEqual(kv(line, "missing"), ValueExtractor.missing)
    }

    /// **語の途中には当てない。** `id=` を探して `request_id=42` に当たってはいけない。
    func testKeyValueMatchesWholeKeyOnly() {
        let line = "request_id=42 id=7"
        XCTAssertEqual(kv(line, "id"), "7")
    }

    func testKeyValueWithQuotedValue() {
        let line = "msg=\"user not found\" status=404"
        XCTAssertEqual(kv(line, "msg"), "user not found")
        XCTAssertEqual(kv(line, "status"), "404")
    }

    func testKeyValueEmptyValue() {
        XCTAssertEqual(kv("a= b=2", "a"), ValueExtractor.blank)
    }

    private func kv(_ line: String, _ key: String) -> String {
        bytes(line) { ValueExtractor.value(from: $0, mode: .keyValue(key: key), options: opts) }
    }

    // MARK: - 正規表現・行全体

    func testRegexCapture() throws {
        let rx = try NSRegularExpression(pattern: "status=(\\d+)")
        let v = bytes("x status=503 y") { ValueExtractor.value(from: $0, mode: .regex(rx), options: opts) }
        XCTAssertEqual(v, "503")
    }

    /// 群が無い正規表現は「該当なし」（黙って行全体を返さない）。
    func testRegexWithoutCaptureGroupYieldsMissing() throws {
        let rx = try NSRegularExpression(pattern: "status=\\d+")
        let v = bytes("status=503") { ValueExtractor.value(from: $0, mode: .regex(rx), options: opts) }
        XCTAssertEqual(v, ValueExtractor.missing)
    }

    func testWholeLine() {
        XCTAssertEqual(bytes("  hello  ") { ValueExtractor.value(from: $0, mode: .wholeLine, options: opts) },
                       "hello")
        XCTAssertEqual(bytes("   ") { ValueExtractor.value(from: $0, mode: .wholeLine, options: opts) },
                       ValueExtractor.blank)
    }

    // MARK: - 正規化

    func testCaseFoldingIsOptIn() {
        var folded = ValueExtractor.Options()
        folded.caseSensitive = false
        let a = bytes("ERROR") { ValueExtractor.value(from: $0, mode: .wholeLine, options: folded) }
        XCTAssertEqual(a, "error")
        let b = bytes("ERROR") { ValueExtractor.value(from: $0, mode: .wholeLine, options: opts) }
        XCTAssertEqual(b, "ERROR", "既定では大小を区別する")
    }

    // MARK: - Shift-JIS（文字列経路）

    /// SJIS の行はデコードしてから切る。**バイト経路に流してはいけない**
    /// （SJIS の 2 バイト目に `,` と同じ値が現れうる）。
    func testShiftJISGoesThroughStringPath() {
        let line = "北海道,釧路市"
        XCTAssertEqual(ValueExtractor.value(fromString: line,
                                            mode: .column(index: 1, mode: .csv),
                                            options: opts), "釧路市")
    }

    // MARK: - 固定長（桁で区切る表示）

    /// 2026-09-11。core が `StructuredMode` に `.fixedWidth` を足した（公開リポの
    /// `35f86da`）ので、ここの switch が網羅でなくなりビルドできなくなっていた。
    ///
    /// 直し方として**「1 列目を返す」「csv と同じに切る」は採らない。** 桁の定義は
    /// 桁ガイド側にあって分析まで来ていないので、どちらも当てずっぽうになる。
    /// 返すのは「該当なし」だけ ── 画面側（`AggregateView` / `ColumnStatsView`）は
    /// そもそも走らせずに「固定長は未対応」と言う。
    func testFixedWidthYieldsNoValueInsteadOfGuessing() {
        let line = "20260911  ERROR  disk full"
        for i in 0..<3 {
            XCTAssertEqual(column(line, i, mode: .fixedWidth), ValueExtractor.missing,
                           "桁の定義が無いのに値を作ってはいけない（列 \(i)）")
        }
        // 文字列経路でも同じ答えにする（SJIS の行はこちらを通る）。
        XCTAssertEqual(ValueExtractor.value(fromString: line,
                                            mode: .column(index: 0, mode: .fixedWidth),
                                            options: opts), ValueExtractor.missing)
    }
}