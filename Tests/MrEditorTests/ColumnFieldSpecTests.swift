import XCTest
@testable import MrEditorCore

/// 固定長の項目定義（C）の純ロジック——文字列 ↔ 境界の桁、桁で切る、幅を測る。
///
/// **ここが「仕様書を持っている人」の入口**なので、読めない書き方を黙って一部だけ
/// 通さないこと（半端に通ると、ずれた項目定義でデータを読み違える）を一番厚く見る。
final class ColumnFieldSpecTests: XCTestCase {

    // MARK: - 文字列 → 境界の桁

    func testParsesClosedFields() {
        // 1-8 / 9-14 / 15-40 の切れ目は 9・15、そして 40 で閉じる印の 41。
        XCTAssertEqual(ColumnFieldSpec.parse("1-8,9-14,15-40"), [9, 15, 41])
    }

    func testParsesOpenLastField() {
        XCTAssertEqual(ColumnFieldSpec.parse("1-8,9-14,15-"), [9, 15])
    }

    func testBareNumbersAreFieldStarts() {
        XCTAssertEqual(ColumnFieldSpec.parse("1,9,15"), [9, 15])
    }

    func testAcceptsSpacesAndFullWidthPunctuation() {
        XCTAssertEqual(ColumnFieldSpec.parse(" 1-8 , 9-14 "), ColumnFieldSpec.parse("1-8,9-14"))
        XCTAssertEqual(ColumnFieldSpec.parse("１-８，９-１４"), ColumnFieldSpec.parse("1-8,9-14"))
        XCTAssertEqual(ColumnFieldSpec.parse("1〜8、9〜14"), ColumnFieldSpec.parse("1-8,9-14"))
    }

    func testGapBecomesItsOwnField() {
        // 1-8 と 15-20 の間（9-14）は捨てず、独立した項目として残す。
        XCTAssertEqual(ColumnFieldSpec.parse("1-8,15-20"), [9, 15, 21])
    }

    func testEmptyMeansNoDefinition() {
        XCTAssertEqual(ColumnFieldSpec.parse(""), [])
        XCTAssertEqual(ColumnFieldSpec.parse("   "), [])
    }

    /// 読めないものは nil。**一部だけ通さない。**
    func testRejectsMalformed() {
        XCTAssertNil(ColumnFieldSpec.parse("abc"))
        XCTAssertNil(ColumnFieldSpec.parse("1-8,x-14"))
        XCTAssertNil(ColumnFieldSpec.parse("-8"))
        XCTAssertNil(ColumnFieldSpec.parse("0-8"))
        XCTAssertNil(ColumnFieldSpec.parse("8-1"))          // 逆向き
        XCTAssertNil(ColumnFieldSpec.parse("1-8,5-12"))     // 重なり
        XCTAssertNil(ColumnFieldSpec.parse("9-14,1-8"))     // 桁が戻る
        XCTAssertNil(ColumnFieldSpec.parse("1-999999"))     // 上限超え
    }

    // MARK: - 境界の桁 → 文字列（往復）

    func testTextForGuidesLeavesLastFieldOpen() {
        XCTAssertEqual(ColumnFieldSpec.text(for: ColumnGuides([9, 15])), "1-8,9-14,15-")
        XCTAssertEqual(ColumnFieldSpec.text(for: ColumnGuides()), "")
    }

    /// ダイアログを開いて何も直さず OK を押しても定義が動かないこと。
    func testRoundTripThroughText() {
        for columns in [[9, 15], [9, 15, 41], [2], [3, 4, 5]] {
            let text = ColumnFieldSpec.text(for: ColumnGuides(columns))
            XCTAssertEqual(ColumnFieldSpec.parse(text), columns, "『\(text)』で往復が壊れた")
        }
    }

    // MARK: - 項目の範囲（データに合わせて最後を閉じる）

    func testFieldRangesFitSampleLines() {
        let guides = ColumnGuides([9, 15])
        XCTAssertEqual(guides.fieldRanges(fitting: ["12345678ABCDEF0123456789"]), [1...8, 9...14, 15...24])
    }

    /// 幅は文字数ではなく**見えている桁**（全角＝2）。ここを文字数で測るとガイド線とズレる。
    func testFieldRangesMeasureDisplayColumns() {
        let guides = ColumnGuides([5])
        XCTAssertEqual(guides.fieldRanges(fitting: ["日本語"]), [1...4, 5...6])
    }

    // MARK: - 桁で切る

    private func formatter(_ guides: [Int], _ lines: [String]) -> TabularFormatter {
        TabularFormatter.build(mode: .fixedWidth, sampleLines: lines,
                               fields: ColumnGuides(guides).fieldRanges(fitting: lines))
    }

    func testFixedCellsSliceByColumns() {
        let line = "00012345TOKYO 20260815"
        let fmt = formatter([9, 15], [line])
        XCTAssertEqual(fmt.cells(of: line), ["00012345", "TOKYO", "20260815"])
    }

    func testShortLineGivesEmptyTrailingCells() {
        let fmt = formatter([9, 15], ["00012345TOKYO 20260815"])
        XCTAssertEqual(fmt.cells(of: "0001"), ["0001", "", ""])
    }

    /// 全角は 2 桁。桁をまたぐ 1 文字は**始まった側**の項目に入れる（文字を割らない）。
    func testWideCharactersCountAsTwoColumns() {
        let fmt = formatter([5], ["日本語です"])
        XCTAssertEqual(fmt.cells(of: "日本語です"), ["日本", "語です"])
        // 3 桁目から始まる全角（2 桁め〜3 桁め）は、境界 5 の手前側に残る。
        XCTAssertEqual(fmt.cells(of: "A日本語"), ["A日本", "語"])
    }

    func testColumnNamesAreTheColumnsThemselves() {
        let fmt = formatter([9, 15], ["00012345TOKYO 20260815"])
        XCTAssertEqual(fmt.columns.map(\.key), ["1-8", "9-14", "15-22"])
    }

    /// 定義が無ければ列は作らない（呼ぶ側が先に訊く）。
    func testNoFieldsMeansNoColumns() {
        let fmt = TabularFormatter.build(mode: .fixedWidth, sampleLines: ["abc"], fields: [])
        XCTAssertEqual(fmt.columnCount, 0)
    }

    /// 桁を数えるための表示なので、幅の上限で切り詰めない（CSV は 40 桁で省略する）。
    func testWideFieldIsNotTruncated() {
        let long = String(repeating: "A", count: 60)
        let fmt = TabularFormatter.build(mode: .fixedWidth, sampleLines: [long], fields: [1...60])
        XCTAssertEqual(fmt.format(long), long)
    }

    /// 定義がデータより右まで伸びていても、空の列を 1 本増やさない。
    func testDefinitionBeyondDataDoesNotAddEmptyColumn() {
        let guides = ColumnGuides([9, 15, 41])       // 1-8,9-14,15-40 と打った状態
        XCTAssertEqual(guides.fieldRanges(fitting: [String(repeating: "X", count: 40)]),
                       [1...8, 9...14, 15...40])
    }

    func testFormatAlignsCellsWithSeparator() {
        let lines = ["00012345TOKYO 20260815", "00000007OSAKA 20260101"]
        let fmt = formatter([9, 15], lines)
        XCTAssertEqual(fmt.format(lines[0]), "00012345 │ TOKYO │ 20260815")
        XCTAssertEqual(fmt.format(lines[1]), "00000007 │ OSAKA │ 20260101")
    }

    // MARK: - 縞（線を引いたら列が立ち上がる）

    /// 塗るのは 1 つおき。**1 番目は塗らない**（本文の左端から急に色が付くと、
    /// 何かを選択したように見える）。
    func testStripesArePaintedEveryOtherField() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.stripes(upTo: 22), [9...14])
        XCTAssertEqual(g.fieldRanges(lastColumn: 22), [1...8, 9...14, 15...22])
    }

    func testStripesFollowMoreGuides() {
        let g = ColumnGuides([5, 9, 13, 17])
        XCTAssertEqual(g.stripes(upTo: 20), [5...8, 13...16])
    }

    /// 線が 1 本も無ければ塗らない（縞が出る＝線を引いた、が対応する）。
    func testNoGuidesNoStripes() {
        XCTAssertTrue(ColumnGuides().stripes(upTo: 40).isEmpty)
        XCTAssertTrue(ColumnGuides([1]).stripes(upTo: 40).isEmpty, "1 桁目は切れ目ではない")
    }

    /// 画面の右端までしか塗らない（見えていない桁に色を作らない）。
    func testStripesStopAtVisibleColumn() {
        let g = ColumnGuides([9, 15])
        XCTAssertEqual(g.stripes(upTo: 12), [9...12])
        XCTAssertTrue(g.stripes(upTo: 5).isEmpty)
    }

    // MARK: - ガイドを掴んで動かす

    func testMoveGuide() {
        var g = ColumnGuides([9, 15])
        XCTAssertTrue(g.move(9, to: 10))
        XCTAssertEqual(g.columns, [10, 15])
    }

    /// 行き先が埋まっていたら動かさない（重ねると片方が消えて戻せなくなる）。
    func testMoveOntoExistingGuideIsRefused() {
        var g = ColumnGuides([9, 15])
        XCTAssertFalse(g.move(9, to: 15))
        XCTAssertEqual(g.columns, [9, 15])
    }

    func testMoveUnknownOrInvalidColumnIsRefused() {
        var g = ColumnGuides([9])
        XCTAssertFalse(g.move(8, to: 12))
        XCTAssertFalse(g.move(9, to: 0))
        XCTAssertEqual(g.columns, [9])
    }
}
