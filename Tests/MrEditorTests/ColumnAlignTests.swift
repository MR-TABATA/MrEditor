import XCTest
@testable import MrEditorCore

/// 1 行目で作った桁割りを、残りの行へ当てる。
///
/// **ここが崩れると「揃えたつもりでズレたデータ」ができる**——見た目が揃っているぶん、
/// 元より質が悪い。字を消さないこと・全角を 2 桁で数えることを厚く見る。
final class ColumnAlignTests: XCTestCase {

    private let starts = [1, 9, 15]   // 1-8 / 9-14 / 15-

    func testAlignsSpaceSeparatedLines() {
        let src = "123 TOKYO 20260815\n4567 OSAKA 20260101\n"
        XCTAssertEqual(ColumnAlign.align(src, to: starts),
                       "123     TOKYO 20260815\n4567    OSAKA 20260101\n")
    }

    func testAlignsTabSeparatedLines() {
        XCTAssertEqual(ColumnAlign.alignLine("12\tOSAKA\t20260101", to: starts),
                       "12      OSAKA 20260101")
        XCTAssertFalse(ColumnAlign.alignLine("12\tOSAKA", to: starts).contains("\t"),
                       "タブは残さない（固定長に混ざると桁が崩れる）")
    }

    /// 既に揃っている行はそのまま（当て直しても壊れない）。
    func testAlreadyAlignedStaysPut() {
        let line = "123     TOKYO 20260815"
        XCTAssertEqual(ColumnAlign.alignLine(line, to: starts), line)
    }

    /// **字は消さない。** 項目が桁を越えていたら、空白 1 つだけ空けて続ける。
    func testOverlongFieldPushesInsteadOfTruncating() {
        XCTAssertEqual(ColumnAlign.alignLine("123456789012 OSAKA 20260101", to: starts),
                       "123456789012 OSAKA 20260101")
        XCTAssertTrue(ColumnAlign.alignLine("123456789012 OSAKA", to: starts).contains("123456789012"))
    }

    /// 定義より項目が多ければ、余りは 1 空けて後ろに続ける（切り捨てない）。
    func testExtraTokensAreKept() {
        XCTAssertEqual(ColumnAlign.alignLine("1 A B C D", to: starts),
                       "1       A     B C D")
    }

    /// 項目が少ない行は、そこまでで終わる（余計な空白を残さない）。
    func testFewerTokensLeaveNoTrailingSpaces() {
        XCTAssertEqual(ColumnAlign.alignLine("1 A", to: starts), "1       A")
    }

    /// 桁は表示幅（全角＝2）。文字数で詰めると全角の行だけ揃わない。
    func testFullWidthCountsAsTwoColumns() {
        // 東京＝4 桁ぶん。5・6 桁目を空白で埋めて、7 桁目に A が来る。
        XCTAssertEqual(ColumnAlign.alignLine("東京 A", to: [1, 7]), "東京  A")
    }

    func testEmptyAndBlankLinesUntouched() {
        XCTAssertEqual(ColumnAlign.align("\n\n", to: starts), "\n\n")
        XCTAssertEqual(ColumnAlign.alignLine("   ", to: starts), "   ")
    }

    /// 改行の有無と CRLF の名残を保つ。
    func testKeepsLineEndings() {
        XCTAssertEqual(ColumnAlign.align("1 A", to: starts), "1       A", "末尾に改行を足さない")
        XCTAssertEqual(ColumnAlign.alignLine("1 A\r", to: starts), "1       A\r")
    }

    // MARK: - 中身から桁割りを作る（いきなり ⌥Tab）

    /// 各項目の一番長いものが収まる幅で割り、あいだを 1 桁空ける。
    func testInfersStartsFromContent() {
        let lines = ["123 TOKYO 20260815", "4567 OSAKA 20260101", "89 NAGOYA 20251231"]
        XCTAssertEqual(ColumnAlign.inferFieldStarts(from: lines), [1, 6, 13])
        // 作った桁割りで揃えると、どの行も項目が重ならない。
        let aligned = lines.map { ColumnAlign.alignLine($0, to: [1, 6, 13]) }
        XCTAssertEqual(aligned, ["123  TOKYO  20260815",
                                 "4567 OSAKA  20260101",
                                 "89   NAGOYA 20251231"])
    }

    /// 全角も 2 桁で数える。
    func testInferCountsFullWidth() {
        XCTAssertEqual(ColumnAlign.inferFieldStarts(from: ["東京 A", "大阪府 B"]), [1, 8])
    }

    /// 項目が 1 つしかないなら割らない（切る意味がない）。
    func testInferNeedsAtLeastTwoFields() {
        XCTAssertEqual(ColumnAlign.inferFieldStarts(from: ["abc", "de"]), [])
        XCTAssertEqual(ColumnAlign.inferFieldStarts(from: []), [])
    }

    func testNoFieldStartsIsNoOp() {
        XCTAssertEqual(ColumnAlign.align("1 A\n", to: []), "1 A\n")
    }
}
