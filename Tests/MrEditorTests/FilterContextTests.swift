import XCTest
@testable import MrEditorCore

/// 一致行の前後 N 行（`grep -C` 相当）の展開。
///
/// 絞り込みは「その行だけ」を見せるが、調査は往復する。前後が見えないと
/// フィルタを解除して行番号で探し直すことになる、というのがこの機能の動機。
final class FilterContextTests: XCTestCase {
    func testZeroContextReturnsMatchesUnchanged() {
        let m = [3, 10, 11]
        XCTAssertEqual(FilterContext.expand(matches: m, context: 0, lineCount: 100), m)
    }

    func testExpandsAroundEachMatch() {
        XCTAssertEqual(FilterContext.expand(matches: [5], context: 2, lineCount: 100),
                       [3, 4, 5, 6, 7])
    }

    /// 窓が重なっても行を二度出さない（`grep` が続きをまとめるのと同じ）。
    func testOverlappingWindowsAreMerged() {
        XCTAssertEqual(FilterContext.expand(matches: [5, 7], context: 2, lineCount: 100),
                       [3, 4, 5, 6, 7, 8, 9])
    }

    /// 隣り合う一致は 1 つの塊になる。
    func testAdjacentMatches() {
        XCTAssertEqual(FilterContext.expand(matches: [5, 6], context: 1, lineCount: 100),
                       [4, 5, 6, 7])
    }

    /// 離れていれば塊は分かれる（間の行は出さない＝ここが飛んでいる所）。
    func testDistantMatchesStayInSeparateGroups() {
        XCTAssertEqual(FilterContext.expand(matches: [2, 20], context: 1, lineCount: 100),
                       [1, 2, 3, 19, 20, 21])
    }

    /// ファイルの端で範囲外へはみ出さない。
    func testClampsToFileEnds() {
        XCTAssertEqual(FilterContext.expand(matches: [0], context: 3, lineCount: 3), [0, 1, 2])
        XCTAssertEqual(FilterContext.expand(matches: [9], context: 3, lineCount: 10), [6, 7, 8, 9])
    }

    func testEmptyInputs() {
        XCTAssertEqual(FilterContext.expand(matches: [], context: 5, lineCount: 100), [])
        XCTAssertEqual(FilterContext.expand(matches: [1], context: 5, lineCount: 0), [1],
                       "行数が分からないときは触らない（切り落とすより出さない方が安全）")
    }

    /// 一致が完全に既出の窓へ埋もれても、順序と重複なしが崩れない。
    func testResultIsSortedAndUnique() {
        let out = FilterContext.expand(matches: [4, 5, 6, 7, 30], context: 10, lineCount: 50)
        XCTAssertEqual(out, Array(0...17) + Array(20...40))
        XCTAssertEqual(out, out.sorted())
        XCTAssertEqual(out.count, Set(out).count)
    }

    /// 上限で止める（100 万一致 × 前後 100 行を素直に展開すると 1.6GB になる）。
    func testStopsAtDisplayCap() {
        let matches = Array(stride(from: 0, to: 4_000_000, by: 2))
        let out = FilterContext.expand(matches: matches, context: 1, lineCount: 4_000_000)
        XCTAssertEqual(out.count, FilterContext.displayCap)
        XCTAssertEqual(out.first, 0)
    }
}
