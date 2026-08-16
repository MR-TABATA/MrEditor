import XCTest
@testable import MrEditorCore

/// 構造化表示の列幅を掴んで変えるための計算。
///
/// **列の境界の桁がズレると、掴んだ場所と動く列が食い違う。** ここは整形結果（実際の
/// 文字列）と突き合わせて測る——幅の足し算を別に書くと、区切り ` │ ` の 3 桁を
/// どこかで数え落とす。
final class ColumnWidthDragTests: XCTestCase {

    private func csv(_ lines: [String]) -> TabularFormatter {
        TabularFormatter.build(mode: .csv, sampleLines: lines)
    }

    private let rows = ["name,age,city", "Alice,30,Tokyo", "Bob,7,Osaka"]

    // MARK: - 列の始まる桁

    /// 整形した実際の文字列で、各列の中身が始まる位置と一致すること。
    func testColumnStartsMatchFormattedText() {
        let f = csv(rows)
        let line = f.format(rows[1])                 // "Alice │ 30  │ Tokyo"
        let starts = f.columnStartColumns()
        XCTAssertEqual(starts.first, 1)
        for (j, cell) in f.cells(of: rows[1]).enumerated() where !cell.isEmpty {
            let start = starts[j] - 1                // 0 始まりへ
            let chars = Array(line)
            let actual = String(chars[start..<min(chars.count, start + cell.count)])
            XCTAssertEqual(actual, cell, "\(j) 列目の始まりがズレている")
        }
    }

    /// 区切り（3 桁）を数え落としていないこと。
    func testColumnStartsIncludeSeparatorWidth() {
        let f = csv(rows)
        // name 列は 5 桁（Alice）→ 次の列は 1 + 5 + 3 = 9 桁目から。
        XCTAssertEqual(f.columnStartColumns(), [1, 9, 15])
        XCTAssertEqual(f.separatorColumn(after: 0), 6)
    }

    // MARK: - 幅を変える

    func testWithColumnWidthChangesOnlyThatColumn() {
        let f = csv(rows).withColumnWidth(0, 10)
        XCTAssertEqual(f.columns.map(\.width), [10, 3, 5])
        XCTAssertEqual(f.format(rows[1]), "Alice      │ 30  │ Tokyo")
    }

    func testWithColumnWidthIsClamped() {
        let f = csv(rows)
        XCTAssertEqual(f.withColumnWidth(0, 0).columns[0].width, TabularFormatter.minColumnWidth)
        XCTAssertEqual(f.withColumnWidth(0, 9999).columns[0].width, TabularFormatter.maxColumnWidth)
    }

    func testWithColumnWidthIgnoresUnknownColumn() {
        let f = csv(rows)
        XCTAssertEqual(f.withColumnWidth(99, 10).columns.map(\.width), f.columns.map(\.width))
    }

    /// 幅を変えても、他の列の中身は切れない（区切りの位置だけが動く）。
    func testNarrowedColumnTruncatesWithEllipsis() {
        let f = csv(rows).withColumnWidth(0, 3)
        XCTAssertEqual(f.format(rows[1]), "Al… │ 30  │ Tokyo")
    }

    // MARK: - 掴んで動かす

    func testDraggingSeparatorSetsWidth() {
        let f = csv(rows)
        // 1 列目の区切りを 12 桁目まで引っぱる → 幅は 12-1 = 11。
        XCTAssertEqual(f.width(forSeparatorOf: 0, draggedTo: 12), 11)
        // 2 列目（9 桁目始まり）の区切りを 20 桁目へ → 11。
        XCTAssertEqual(f.width(forSeparatorOf: 1, draggedTo: 20), 11)
    }

    /// 左へ詰めきっても 1 桁は残す（0 にすると掴み手が消えて戻せなくなる）。
    func testDraggingPastLeftEdgeKeepsOneColumn() {
        let f = csv(rows)
        XCTAssertEqual(f.width(forSeparatorOf: 0, draggedTo: 1), TabularFormatter.minColumnWidth)
        XCTAssertEqual(f.width(forSeparatorOf: 0, draggedTo: -50), TabularFormatter.minColumnWidth)
    }

    /// 変えた幅で、掴み手の位置も追いてくること（掴む → 動かす → また掴む、が続く）。
    func testSeparatorFollowsNewWidth() {
        let f = csv(rows).withColumnWidth(0, 11)
        XCTAssertEqual(f.separatorColumn(after: 0), 12)
        XCTAssertEqual(f.columnStartColumns()[1], 15)
    }

    /// 固定長でも同じ計算が効く（列名が桁そのものになるだけ）。
    func testWorksForFixedWidthToo() {
        let lines = ["00012345TOKYO 20260815"]
        let f = TabularFormatter.build(mode: .fixedWidth, sampleLines: lines,
                                       fields: ColumnGuides([9, 15]).fieldRanges(fitting: lines))
        XCTAssertEqual(f.columnStartColumns(), [1, 12, 20])
        XCTAssertEqual(f.withColumnWidth(0, 4).format(lines[0]), "000… │ TOKYO │ 20260815")
    }
}
