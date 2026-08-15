import XCTest
@testable import MrEditorCore

/// 桁ルーラー（A）と桁ガイド（B）の座標計算・配列としてのガイド保持を検証する。
///
/// ここが両ペイン共通の唯一の式なので、**桁 ↔ x の往復が壊れていないこと**を
/// 一番厚く見る。ズレたまま固定長の項目定義（C）を載せると、同じファイルを
/// 開き直しただけで項目が別の場所を指す。
final class ColumnRulerTests: XCTestCase {

    private let w: CGFloat = 8   // 等幅 1 桁の幅

    // MARK: - 桁 ↔ x

    func testColumnOneStartsAtOrigin() {
        XCTAssertEqual(ColumnRuler.x(ofColumn: 1, columnWidth: w), 0)
    }

    func testColumnXIsOneBased() {
        XCTAssertEqual(ColumnRuler.x(ofColumn: 9, columnWidth: w), 64)
    }

    func testColumnAtXIsOneBased() {
        XCTAssertEqual(ColumnRuler.column(atX: 0, columnWidth: w), 1)
        XCTAssertEqual(ColumnRuler.column(atX: 7.9, columnWidth: w), 1)
        XCTAssertEqual(ColumnRuler.column(atX: 8, columnWidth: w), 2)
        XCTAssertEqual(ColumnRuler.column(atX: 64, columnWidth: w), 9)
    }

    /// 桁 → x → 桁 が全桁で戻ること（往復して同じ桁に着かないと、クリックで置いた
    /// ガイドが別の桁に付く）。
    func testRoundTripColumnToXToColumn() {
        for col in 1...500 {
            let x = ColumnRuler.x(ofColumn: col, columnWidth: w)
            XCTAssertEqual(ColumnRuler.column(atX: x, columnWidth: w), col, "桁 \(col) で往復が壊れた")
        }
    }

    func testNegativeXClampsToFirstColumn() {
        XCTAssertEqual(ColumnRuler.column(atX: -100, columnWidth: w), 1)
    }

    func testZeroColumnWidthDoesNotDivideByZero() {
        XCTAssertEqual(ColumnRuler.column(atX: 100, columnWidth: 0), 1)
        XCTAssertTrue(ColumnRuler.ticks(offset: 0, width: 100, columnWidth: 0).isEmpty)
    }

    // MARK: - 目盛り

    func testTicksIncludeFirstColumnAsMajor() {
        let ticks = ColumnRuler.ticks(offset: 0, width: 100, columnWidth: w)
        XCTAssertEqual(ticks.first?.column, 1)
        XCTAssertEqual(ticks.first?.isMajor, true)
    }

    func testTicksAreMajorEveryTenAndMinorEveryFive() {
        let ticks = ColumnRuler.ticks(offset: 0, width: 240, columnWidth: w)
        let majors = ticks.filter(\.isMajor).map(\.column)
        let minors = ticks.filter { !$0.isMajor }.map(\.column)
        XCTAssertEqual(majors, [1, 10, 20, 30])
        XCTAssertEqual(minors, [5, 15, 25])
    }

    /// 横スクロールすると目盛りは左へ流れるが、**桁の番号は動かない**。
    func testTicksFollowHorizontalOffset() {
        let ticks = ColumnRuler.ticks(offset: 800, width: 100, columnWidth: w)
        XCTAssertEqual(ticks.first?.column, 105)   // x=800 は 101 桁目、最初の目盛りは 105
        // x は本文左端を 0 とする絶対座標のまま（呼ぶ側が offset を引く）。
        XCTAssertEqual(ticks.first?.x, ColumnRuler.x(ofColumn: 105, columnWidth: w))
    }

    func testTicksEmptyForZeroWidth() {
        XCTAssertTrue(ColumnRuler.ticks(offset: 0, width: 0, columnWidth: w).isEmpty)
    }

    // MARK: - ガイドは「桁の配列」

    func testGuidesAreSortedUniqueAndOneBased() {
        let g = ColumnGuides([15, 9, 15, 0, -3, 1])
        XCTAssertEqual(g.columns, [1, 9, 15])
    }

    func testToggleAddsAndRemoves() {
        var g = ColumnGuides()
        g.toggle(9)
        XCTAssertEqual(g.columns, [9])
        g.toggle(1)
        XCTAssertEqual(g.columns, [1, 9], "足したら昇順に保たれる")
        g.toggle(9)
        XCTAssertEqual(g.columns, [1])
    }

    func testInsertIgnoresDuplicatesAndZero() {
        var g = ColumnGuides([5])
        g.insert(5)
        g.insert(0)
        XCTAssertEqual(g.columns, [5])
    }

    func testRemoveAllClears() {
        var g = ColumnGuides([1, 2, 3])
        g.removeAll()
        XCTAssertTrue(g.isEmpty)
    }

    /// クリックの当たり判定。細い線をピクセル単位で狙わせない。
    func testNearestWithinTolerance() {
        let g = ColumnGuides([10, 40])
        XCTAssertEqual(g.nearest(to: 11, within: 1), 10)
        XCTAssertEqual(g.nearest(to: 12, within: 1), nil)
        XCTAssertEqual(g.nearest(to: 12, within: 2), 10)
        XCTAssertNil(ColumnGuides().nearest(to: 10, within: 5))
    }

    func testNearestPrefersSmallerColumnOnTie() {
        let g = ColumnGuides([9, 11])
        XCTAssertEqual(g.nearest(to: 10, within: 1), 9)
    }

    // MARK: - C（固定長の項目定義）へ渡る形

    /// 桁 [9, 15] は「1-8 / 9-14 / 15-」の 3 項目。最後は行の長さが分かって初めて閉じる。
    func testFieldRangesFromGuides() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.fieldRanges(lastColumn: 40), [1...8, 9...14, 15...40])
    }

    func testFieldRangesDropOpenTailWithoutLastColumn() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.fieldRanges(), [1...8, 9...14])
    }

    func testFieldRangesIgnoreGuideAtColumnOne() {
        // 1 桁目のガイドは「切れ目」ではない（そこが先頭なので項目を割らない）。
        let g = ColumnGuides([1, 9])
        XCTAssertEqual(g.fieldRanges(lastColumn: 20), [1...8, 9...20])
    }

    func testFieldRangesEmptyWithoutGuidesOrLength() {
        XCTAssertEqual(ColumnGuides().fieldRanges(), [])
        XCTAssertEqual(ColumnGuides().fieldRanges(lastColumn: 10), [1...10])
    }

    // MARK: - 両ペインが同じ桁幅を読むこと

    /// ルーラーの目盛り幅とブロックカーソルの幅は同じ「等幅 1 文字」。
    /// 別々に測ると目盛りと本文が少しずつズレる。
    func testColumnWidthMatchesCaretWidth() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(EditorStyle.columnWidth(for: font), EditorStyle.caretWidth(for: font))
    }

    func testColumnWidthIsPositiveForProportionalFont() {
        let font = NSFont.systemFont(ofSize: 13)
        XCTAssertGreaterThan(EditorStyle.columnWidth(for: font), 0)
    }
}
