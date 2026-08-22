import XCTest
import AppKit
@testable import MrEditorCore

/// 一致行の前後 N 行（`grep -C` 相当）が、両方のペインで同じように効くこと。
///
/// `AppSettings.filterContextLines`（UserDefaults.standard）を触るので、
/// 各テストで元の値へ復元する。
final class FilterContextPaneTests: XCTestCase {

    private var savedContext = 0

    override func setUp() {
        super.setUp()
        savedContext = AppSettings.filterContextLines
        AppSettings.filterContextLines = 0    // ペインは init でこの値を読む
    }

    override func tearDown() {
        AppSettings.filterContextLines = savedContext
        super.tearDown()
    }

    // MARK: - 小ファイル（EditableViewer）

    private func editable(_ text: String) -> EditableViewer {
        let v = EditableViewer()
        v.newDocument()
        v._testSetText(text)
        v._testSelect(NSRange(location: 0, length: 0))
        return v
    }

    private let log = "a0\na1\nERROR here\na3\na4\na5\na6\nERROR again\na8\n"

    /// 既定（0）は今までどおり一致行だけ。
    func testEditableFilterWithoutContextShowsOnlyMatches() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        XCTAssertEqual(v._testText, "ERROR here\nERROR again\n")
    }

    /// ±1 で前後の行が付いてくる（塊は離れているので混ざらない）。
    func testEditableFilterWithContextShowsNeighbours() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        v.setFilterContextLines(1)
        XCTAssertEqual(v._testText, "a1\nERROR here\na3\na6\nERROR again\na8\n")
    }

    /// 前後行を出しても「一致行」は一致した行だけ（分析の件数を水増ししない）。
    func testEditableMatchLinesExcludeContext() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        v.setFilterContextLines(2)
        XCTAssertEqual(v.filterMatchLines ?? [], [2, 7], "文脈行を一致に数えないこと")
    }

    /// 0 に戻せば元どおり（伸ばしたら縮められる）。
    func testEditableContextCanBeTurnedBackOff() {
        let v = editable(log)
        v.setSearchQuery("ERROR")
        v.setFilterMode(true)
        v.setFilterContextLines(3)
        v.setFilterContextLines(0)
        XCTAssertEqual(v._testText, "ERROR here\nERROR again\n")
    }

    /// 時間帯を指定した絞り込み（時間分布のドラッグ）には前後行を足さない。
    /// 選んだ範囲の外の行が混ざると「選んだ時間帯」が嘘になる。
    func testEditableExplicitLinesIgnoreContext() {
        let v = editable(log)
        v.setFilterContextLines(2)
        v.showOnlyLines([4])
        XCTAssertEqual(v._testText, "a4\n")
        XCTAssertEqual(v.filterMatchLines ?? [], [4])
    }

    /// 上限で丸める（青天井にすると全文が出て絞り込みの意味が無くなる）。
    func testContextIsClamped() {
        let v = editable(log)
        v.setFilterContextLines(-5)
        XCTAssertEqual(v.filterContextLines, 0)
        v.setFilterContextLines(9999)
        XCTAssertEqual(v.filterContextLines, FilterContext.maxContext)
    }

    /// 設定として覚える（次に開いたファイルでも同じ見え方になる）。
    func testContextPersists() {
        editable(log).setFilterContextLines(4)
        XCTAssertEqual(AppSettings.filterContextLines, 4)
        XCTAssertEqual(editable(log).filterContextLines, 4, "新しいペインも覚えている値で始まる")
    }

    // MARK: - 巨大ファイル（PieceTableViewer）
    //
    // `_testLoad` はインメモリ原本＝`fileBuffer` を持たないので `refresh()` が
    // 描画まで進まない。確かめるのは**並べる行の決まり方**（`filterDisplayLines`）と
    // 「いまの一致」の動き。実画面の見え方は .app で確認する。

    private func big(_ text: String) -> PieceTableViewer {
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(text.utf8))
        return v
    }

    /// 400 行のログ。10 行ごとに `ERROR`（＝一致行は 10, 20, … 390）。
    /// 短いログだと絞り込んだ結果が 1 画面に収まってしまい、先頭行が常に 0 へ
    /// 丸められてスクロールの検証にならない。
    private func longLog() -> (text: String, matches: [Int]) {
        var lines: [String] = []
        var matches: [Int] = []
        for i in 0..<400 {
            if i > 0, i % 10 == 0 { lines.append("ERROR \(i)"); matches.append(i) }
            else { lines.append("line \(i)") }
        }
        return (lines.joined(separator: "\n") + "\n", matches)
    }

    func testBigFileFilterWithoutContextShowsOnlyMatches() {
        let v = big(log)
        v._testSetSearch(terms: ["ERROR"], matchLines: [2, 7])
        v.setFilterMode(true)
        XCTAssertEqual(v._testFilterDisplayLines, [2, 7])
    }

    func testBigFileFilterWithContextShowsNeighbours() {
        let v = big(log)
        v._testSetSearch(terms: ["ERROR"], matchLines: [2, 7])
        v.setFilterMode(true)
        v.setFilterContextLines(1)
        XCTAssertEqual(v._testFilterDisplayLines, [1, 2, 3, 6, 7, 8])
    }

    /// ファイルの端で範囲外へ行かない（最終行の先を出そうとしない）。
    func testBigFileContextClampsAtFileEnd() {
        let v = big(log)                       // 9 行（0…8）
        v._testSetSearch(terms: ["a8"], matchLines: [8])
        v.setFilterMode(true)
        v.setFilterContextLines(3)
        XCTAssertEqual(v._testFilterDisplayLines, [5, 6, 7, 8])
    }

    /// 絞り込みに入った時点で最初の一致を指す（帯を敷く行が決まる）。
    func testBigFileEnteringFilterSelectsFirstMatch() {
        let v = big(log)
        v._testSetSearch(terms: ["ERROR"], matchLines: [2, 7])
        v.setFilterMode(true)
        v.setFilterContextLines(1)
        XCTAssertEqual(v._testCurrentMatchLine, 2)
    }

    /// 「次を検索」は文脈行を飛ばして次の一致まで進む
    /// （1 行ずつスクロールすると、前後を広げるほど次の一致に着かなくなる）。
    func testBigFileFindNextSkipsContextLines() {
        let (text, matches) = longLog()
        let v = big(text)
        v._testSetSearch(terms: ["ERROR"], matchLines: matches)
        v.setFilterMode(true)
        v.setFilterContextLines(1)
        XCTAssertEqual(v._testCurrentMatchLine, 10, "最初の一致")
        v.findNext()
        XCTAssertEqual(v._testCurrentMatchLine, 20, "次の一致行へ（間の文脈行では止まらない）")
        XCTAssertEqual(v._testFilterDisplayLines[v._testTopLine], 19,
                       "先頭は一致行そのものでなく前の行（出した「直前」を画面の上に隠さない）")
        v.findPrev()
        XCTAssertEqual(v._testCurrentMatchLine, 10, "前の一致行へ")
    }

    /// 末尾の次は先頭へ回る（前後行を出していても一巡できる）。
    func testBigFileFindNextWrapsAround() {
        let (text, matches) = longLog()
        let v = big(text)
        v._testSetSearch(terms: ["ERROR"], matchLines: matches)
        v.setFilterMode(true)
        v.setFilterContextLines(2)
        for _ in 0..<(matches.count - 1) { v.findNext() }
        XCTAssertEqual(v._testCurrentMatchLine, matches.last)
        v.findNext()
        XCTAssertEqual(v._testCurrentMatchLine, matches.first, "末尾の次は先頭")
    }

    /// 時間帯の指定（`showOnlyLines`）には前後行を足さない。
    func testBigFileExplicitLinesIgnoreContext() {
        let v = big(log)
        v.setFilterContextLines(2)
        v.showOnlyLines([4])
        XCTAssertEqual(v._testFilterDisplayLines, [4])
    }

    /// 前後行を変えても、いま先頭に見えている行は先頭のまま（見失わせない）。
    func testBigFileKeepsTopLineWhenContextChanges() {
        let (text, matches) = longLog()
        let v = big(text)
        v._testSetSearch(terms: ["ERROR"], matchLines: matches)
        v.setFilterMode(true)
        for _ in 0..<5 { v.findNext() }
        let top = v._testFilterDisplayLines[v._testTopLine]
        XCTAssertEqual(top, 60, "前提: 6 件目の一致を先頭に見ている")
        v.setFilterContextLines(2)
        XCTAssertEqual(v._testFilterDisplayLines[v._testTopLine], top, "同じ行が先頭に残る")
    }

    /// 絞り込みを解除したら、いま見ていた行がそのまま本文の位置になる。
    func testBigFileLeavingFilterKeepsThePlace() {
        let (text, matches) = longLog()
        let v = big(text)
        v._testSetSearch(terms: ["ERROR"], matchLines: matches)
        v.setFilterMode(true)
        v.setFilterContextLines(1)
        for _ in 0..<3 { v.findNext() }
        let top = v._testFilterDisplayLines[v._testTopLine]
        v.setFilterMode(false)
        XCTAssertEqual(v._testTopLine, top, "解除後は元の行番号で同じ場所")
    }
}
