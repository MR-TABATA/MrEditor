import XCTest
@testable import MrEditorCore

/// `TabularFormatter` の分割・キー投影・表示幅パディング・省略・列幅確定を検証する。
final class TabularFormatterTests: XCTestCase {

    // MARK: - 分割

    func testCSVQuotedFields() {
        let cells = TabularFormatter.splitDelimited("a,\"b,c\",\"d\"\"e\",f", sep: ",", csvQuotes: true)
        XCTAssertEqual(cells, ["a", "b,c", "d\"e", "f"])
    }

    func testCSVEmptyFields() {
        XCTAssertEqual(TabularFormatter.splitDelimited("a,,c", sep: ",", csvQuotes: true), ["a", "", "c"])
    }

    func testTSVPlainSplit() {
        XCTAssertEqual(TabularFormatter.splitDelimited("a\tb\tc", sep: "\t", csvQuotes: false), ["a", "b", "c"])
    }

    // MARK: - 表示幅・パディング・省略

    func testDisplayWidthCJKIsDouble() {
        XCTAssertEqual(TabularFormatter.displayWidth("abc"), 3)
        XCTAssertEqual(TabularFormatter.displayWidth("あいう"), 6)      // 全角=2
        XCTAssertEqual(TabularFormatter.displayWidth("aあb"), 4)
    }

    func testPadLeftAlignsToDisplayWidth() {
        XCTAssertEqual(TabularFormatter.pad("ab", to: 5), "ab   ")     // 3 スペース
        XCTAssertEqual(TabularFormatter.pad("あ", to: 5), "あ   ")     // 全角2 + 3 スペース
        XCTAssertEqual(TabularFormatter.displayWidth(TabularFormatter.pad("あ", to: 5)), 5)
    }

    func testPadTruncatesWithEllipsis() {
        let out = TabularFormatter.pad("abcdef", to: 4)               // 3 文字 + …
        XCTAssertEqual(out, "abc…")
        XCTAssertEqual(TabularFormatter.displayWidth(out), 4)
    }

    func testPadTruncationRespectsCJKWidth() {
        // 幅5に「あいうえ」(=8)。全角は2なので「あい」(=4)+… で幅5。
        let out = TabularFormatter.pad("あいうえ", to: 5)
        XCTAssertEqual(TabularFormatter.displayWidth(out), 5)
        XCTAssertTrue(out.hasSuffix("…"))
    }

    // MARK: - build（列幅確定）

    func testBuildCSVColumnsFromSample() {
        let f = TabularFormatter.build(mode: .csv,
                                       sampleLines: ["name,age", "Alice,30", "Bob,7"])
        XCTAssertEqual(f.columnCount, 2)
        XCTAssertEqual(f.columns[0].key, "name")
        XCTAssertEqual(f.columns[0].width, 5)   // "Alice"
        XCTAssertEqual(f.columns[1].key, "age")
        XCTAssertEqual(f.columns[1].width, 3)   // "age"
    }

    func testFormatAlignsColumns() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["name,age", "Alice,30", "Bob,7"])
        let row = f.format("Bob,7")
        XCTAssertEqual(row, "Bob   │ 7  ")       // name 幅5, age 幅3
    }

    func testBuildCapsColumnWidth() {
        let long = String(repeating: "x", count: 100)
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["h", long], widthCap: 10)
        XCTAssertEqual(f.columns[0].width, 10)
    }

    func testRaggedRowsPadMissingCells() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["a,b,c", "1,2,3"])
        let row = f.format("x")                  // 1 セルだけ → 残りは空でパディング
        XCTAssertTrue(row.hasPrefix("x"))
        XCTAssertEqual(f.columnCount, 3)
    }

    // MARK: - NDJSON

    func testNDJSONProjectsKeysInOrder() {
        let f = TabularFormatter.build(mode: .ndjson,
            sampleLines: ["{\"level\":\"INFO\",\"msg\":\"hi\"}",
                          "{\"level\":\"ERROR\",\"msg\":\"boom\",\"code\":500}"])
        XCTAssertEqual(f.columns.map(\.key), ["level", "msg", "code"])
        let cells = f.cells(of: "{\"level\":\"INFO\",\"msg\":\"hi\"}")
        XCTAssertEqual(cells, ["INFO", "hi", ""])          // 欠けたキーは空
    }

    func testNDJSONNestedValueBecomesCompactJSON() {
        let f = TabularFormatter.build(mode: .ndjson, sampleLines: ["{\"a\":{\"x\":1},\"b\":[1,2]}"])
        let cells = f.cells(of: "{\"a\":{\"x\":1},\"b\":[1,2]}")
        XCTAssertEqual(cells[0], "{\"x\":1}")
        XCTAssertEqual(cells[1], "[1,2]")
    }

    func testNDJSONNumberAndNull() {
        let f = TabularFormatter.build(mode: .ndjson, sampleLines: ["{\"n\":42,\"z\":null}"])
        let cells = f.cells(of: "{\"n\":42,\"z\":null}")
        XCTAssertEqual(cells[0], "42")
        XCTAssertEqual(cells[1], "")
    }

    // MARK: - movingColumn（B19: 列の並べ替え）

    func testMovingColumnFrontToBack() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["a,b,c", "1,2,3"])
        let moved = f.movingColumn(0, to: 2)
        XCTAssertEqual(moved.columns.map(\.key), ["b", "c", "a"])
    }

    func testMovingColumnBackToFront() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["a,b,c", "1,2,3"])
        let moved = f.movingColumn(2, to: 0)
        XCTAssertEqual(moved.columns.map(\.key), ["c", "a", "b"])
    }

    func testMovingColumnAdjacentSwap() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["a,b,c", "1,2,3"])
        let moved = f.movingColumn(1, to: 2)
        XCTAssertEqual(moved.columns.map(\.key), ["a", "c", "b"])
    }

    func testMovingColumnOutOfRangeIndexIsNoOp() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["a,b,c", "1,2,3"])
        XCTAssertEqual(f.movingColumn(-1, to: 1).columns.map(\.key), ["a", "b", "c"])
        XCTAssertEqual(f.movingColumn(5, to: 1).columns.map(\.key), ["a", "b", "c"])
        XCTAssertEqual(f.movingColumn(0, to: -1).columns.map(\.key), ["a", "b", "c"])
        XCTAssertEqual(f.movingColumn(0, to: 5).columns.map(\.key), ["a", "b", "c"])
    }

    func testMovingColumnPreservesWidths() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["name,age", "Alice,30"])
        let moved = f.movingColumn(0, to: 1)
        XCTAssertEqual(moved.columns.map(\.key), ["age", "name"])
        XCTAssertEqual(moved.columns[1].width, 5)   // "name" 列(元 index 0)の幅が付いてくる
    }

    /// 実機で踏んだバグ(2026-09-25): 並べ替えると**列名は動くのに値が動かない**。
    /// `cells(of:)`/`format` は表示順に値を並べ直さねばならない。
    func testMovingColumnAlsoMovesRenderedValues() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["name,age,city,role", "Alice,30,Tokyo,Engineer"])
        // city(index 2) を age(index 1) の前へ動かす → 表示順は name, city, age, role。
        let moved = f.movingColumn(2, to: 1)
        XCTAssertEqual(moved.columns.map(\.key), ["name", "city", "age", "role"])
        let cells = moved.cells(of: "Alice,30,Tokyo,Engineer")
        XCTAssertEqual(cells, ["Alice", "Tokyo", "30", "Engineer"])   // 列名と同じ順で値も動く
        XCTAssertTrue(moved.format("Alice,30,Tokyo,Engineer").hasPrefix("Alice"))
        XCTAssertTrue(moved.format("Alice,30,Tokyo,Engineer").contains("Tokyo"))
    }

    func testApplyingLayoutAlsoMovesRenderedValues() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["name,age,city,role", "Alice,30,Tokyo,Engineer"])
        let applied = f.applyingLayout(order: ["city", "name", "role", "age"], widths: [:])
        XCTAssertEqual(applied.cells(of: "Alice,30,Tokyo,Engineer"), ["Tokyo", "Alice", "Engineer", "30"])
    }

    func testMovingColumnTSVAlsoMovesRenderedValues() {
        let f = TabularFormatter.build(mode: .tsv, sampleLines: ["a\tb\tc", "1\t2\t3"])
        let moved = f.movingColumn(0, to: 2)
        XCTAssertEqual(moved.cells(of: "1\t2\t3"), ["2", "3", "1"])
    }

    // MARK: - applyingLayout（Pro のビュープリセットが使う）

    func testApplyingLayoutReordersAndResizes() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["a,b,c", "1,2,3"])
        let applied = f.applyingLayout(order: ["c", "a", "b"], widths: ["c": 9, "a": 8])
        XCTAssertEqual(applied.columns.map(\.key), ["c", "a", "b"])
        XCTAssertEqual(applied.columns[0].width, 9)
        XCTAssertEqual(applied.columns[1].width, 8)
        XCTAssertEqual(applied.columns[2].width, f.columns[1].width)   // "b" は widths に無い→幅そのまま
    }

    func testApplyingLayoutUnknownOrderKeyIsIgnored() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["a,b", "1,2"])
        let applied = f.applyingLayout(order: ["a", "ghost", "b"], widths: [:])
        XCTAssertEqual(applied.columns.map(\.key), ["a", "b"])
    }

    func testApplyingLayoutMissingKeyStaysAtEndInOriginalOrder() {
        let f = TabularFormatter.build(mode: .csv, sampleLines: ["a,b,c", "1,2,3"])
        // プリセットは "a" しか知らない（保存後にファイル形状が増えた想定）→ b, c は元順で末尾に残る。
        let applied = f.applyingLayout(order: ["a"], widths: [:])
        XCTAssertEqual(applied.columns.map(\.key), ["a", "b", "c"])
    }
}
