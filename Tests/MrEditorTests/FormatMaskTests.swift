import XCTest
@testable import MrEditorCore

/// 「フォーマットを比較」の正規化。
///
/// **この機能の一点物の要求**は「テスト環境と本番でデータの中身は違うが、日付の形が
/// 揃っているかを見たい」。だから守るべき性質は 2 つだけ ——
/// **値が違うだけの行は同じになる／形が違う行は違うまま**。
final class FormatMaskTests: XCTestCase {

    private let mask = FormatMask.standard

    // MARK: - 形は残す、値は消す

    func testSameFormatDifferentValuesCollapse() {
        XCTAssertEqual(mask.masked("2026-08-19"), mask.masked("1999-01-02"))
        XCTAssertEqual(mask.masked("2026-08-19 12:00:00 ERROR uid=41"),
                       mask.masked("2001-12-31 03:59:07 WARN uid=88"))
        // 空白の数は既定では「形」の一部（列がずれていれば差分として出る）。
        XCTAssertNotEqual(mask.masked("ERROR uid=41"), mask.masked("WARN  uid=88"))
    }

    /// **これが落ちたら機能そのものが無価値。** 型名（`<DATE>`）に置き換える実装だと、
    /// 区切りの違いまで消えてここが通ってしまう。
    func testDifferentDateFormatsStayDifferent() {
        XCTAssertNotEqual(mask.masked("2026-08-19"), mask.masked("2026/08/19"))
        XCTAssertNotEqual(mask.masked("2026-08-19"), mask.masked("19-08-2026 "))
        XCTAssertNotEqual(mask.masked("2026-08-19T12:00:00Z"), mask.masked("2026-08-19 12:00:00"))
        // syslog（Jul 30 12:34:56）と ISO は別の形。
        XCTAssertNotEqual(mask.masked("Aug 19 12:00:00"), mask.masked("2026-08-19 12:00:00"))
    }

    func testMaskedShape() {
        XCTAssertEqual(mask.masked("2026-08-19 12:00:00"), "9999-99-99 99:99:99")
        XCTAssertEqual(mask.masked("ERROR"), "A")
        XCTAssertEqual(mask.masked("uid=41,name=Ann"), "A=99,A=A")
    }

    // MARK: - 桁（ゼロ埋めの食い違いは残す）

    func testZeroPaddingIsADifferenceByDefault() {
        XCTAssertNotEqual(mask.masked("007"), mask.masked("7"))
        XCTAssertEqual(mask.masked("007"), mask.masked("123"))
    }

    func testDigitCountIgnoresPadding() {
        let m: FormatMask = [.digits, .digitCount, .letters]
        XCTAssertEqual(m.masked("007"), m.masked("7"))
        XCTAssertEqual(m.masked("id=0001"), m.masked("id=42"))
    }

    // MARK: - 全角（値は消すが、半角との食い違いは残す）

    func testFullWidthDigitsDifferFromAscii() {
        XCTAssertEqual(mask.masked("１２３"), mask.masked("４５６"))
        XCTAssertNotEqual(mask.masked("１２３"), mask.masked("123"))
        XCTAssertNotEqual(mask.masked("ＡＢＣ"), mask.masked("ABC"))
    }

    // MARK: - 日本語（値として畳むが、全角の記号は「形」として残す）

    /// 日本語の CSV でこれが畳めないと、氏名や住所が全部差分になって
    /// 「値は無視する」が嘘になる（実データの法人番号 CSV で気づいた）。
    func testJapaneseTextIsAValueNotAFormat() {
        XCTAssertEqual(mask.masked("釧路検察審査会"), mask.masked("伊達簡易裁判所"))
        XCTAssertEqual(mask.masked("氏名,2026-08-19"), "T,9999-99-99")
        XCTAssertEqual(mask.masked("\"北海道\",\"釧路市\""), mask.masked("\"東京都\",\"港区\""))
    }

    /// 全角の記号・全角スペースは畳まない —— `、` と `,`、全角空白と半角空白の食い違いは
    /// **まさに見つけたい形の違い**。
    func testFullWidthPunctuationStaysAFormat() {
        XCTAssertNotEqual(mask.masked("東京、大阪"), mask.masked("東京,大阪"))
        XCTAssertNotEqual(mask.masked("氏名　太郎"), mask.masked("氏名 太郎"))
    }

    func testScriptDifferenceIsAFormatDifference() {
        XCTAssertNotEqual(mask.masked("山田"), mask.masked("Yamada"))
    }

    // MARK: - 選べる潰し方

    func testSpacesOption() {
        let m: FormatMask = [.digits, .letters, .spaces]
        XCTAssertEqual(m.masked("a  b"), m.masked("a b"))
        XCTAssertEqual(m.masked("a b   "), m.masked("a b"))
        // 既定では末尾の空白は差分として残る。
        XCTAssertNotEqual(mask.masked("a b   "), mask.masked("a b"))
    }

    func testQuotesOption() {
        let m: FormatMask = [.digits, .letters, .quotes]
        XCTAssertEqual(m.masked("\"abc\",\"12\""), m.masked("abc,12"))
        XCTAssertNotEqual(mask.masked("\"abc\""), mask.masked("abc"))
    }

    func testLetterCaseOption() {
        let m: FormatMask = [.digits, .letterCase]
        XCTAssertEqual(m.masked("Error"), m.masked("ERROR"))
        XCTAssertNotEqual(m.masked("Error"), m.masked("Warn"))
    }

    func testEmptyMaskIsAPassThrough() {
        let m: FormatMask = []
        XCTAssertEqual(m.masked("2026-08-19 ERROR  "), "2026-08-19 ERROR  ")
    }

    // MARK: - 行の切り方（ふつうの diff と同じでなければ左右の対応が崩れる）

    private func hashes(_ mask: FormatMask, _ text: String) -> [LineHash] {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { buf in
            mask.hashLines(UnsafeRawBufferPointer(buf))
        }
    }

    func testLineSplittingMatchesPlainHasher() {
        for text in ["a\nb\nc", "a\nb\n", "", "\n", "a\r\nb\r\n", "a\n\nb", "no newline at end"] {
            var bytes = Array(text.utf8)
            let plain = bytes.withUnsafeMutableBufferPointer { LineHasher.hashLines(UnsafeRawBufferPointer($0)) }
            XCTAssertEqual(hashes(.standard, text).count, plain.count, "行数が食い違う: \(text.debugDescription)")
        }
    }

    func testEmptyMaskHashesMatchPlainHasher() {
        let text = "2026-08-19 ERROR\r\nplain\n"
        var bytes = Array(text.utf8)
        let plain = bytes.withUnsafeMutableBufferPointer { LineHasher.hashLines(UnsafeRawBufferPointer($0)) }
        XCTAssertEqual(hashes([], text), plain)
    }

    func testCRLFIsNotADifference() {
        XCTAssertEqual(hashes(.standard, "2026-08-19\r\n"), hashes(.standard, "2026-08-19\n"))
    }

    // MARK: - diff まで通す（ここが本番の経路）

    func testDiffSeesNoDifferenceWhenOnlyValuesDiffer() {
        let left = TextDiffSource(text: "2026-08-19 12:00:00 ERROR disk full\n2026-08-19 12:00:01 INFO ok",
                                  displayName: "test")
        let right = TextDiffSource(text: "2001-01-02 03:04:05 WARN net down\n2001-01-02 03:04:06 INFO no",
                                   displayName: "prod")
        XCTAssertFalse(DiffModel(ops: LineDiff.compute(left.lineHashes(), right.lineHashes())).isIdentical)
        let model = DiffModel(ops: LineDiff.compute(left.lineHashes(mask: .standard),
                                                    right.lineHashes(mask: .standard)))
        XCTAssertTrue(model.isIdentical, "値しか違わないのに差分が出た")
    }

    func testDiffCatchesTheDateFormatDifference() {
        let left = TextDiffSource(text: "2026-08-19 12:00:00 ok\n2026-08-19 12:00:01 ok", displayName: "test")
        let right = TextDiffSource(text: "2026-08-19 12:00:00 ok\n2026/08/19 12:00:01 ok", displayName: "prod")
        let model = DiffModel(ops: LineDiff.compute(left.lineHashes(mask: .standard),
                                                    right.lineHashes(mask: .standard)))
        XCTAssertFalse(model.isIdentical)
        XCTAssertEqual(model.changedRowCount, 1)
    }
}
