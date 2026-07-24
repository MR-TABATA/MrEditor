import XCTest
import AppKit
@testable import MrEditor

/// 行表示まわり（行頭索引＝行番号ガター／キャレット位置、不可視文字の記号、行の分割）の検証。
final class LineDisplayTests: XCTestCase {

    // MARK: - 行頭索引（LineStartIndex）

    func testEmptyTextHasOneLine() {
        let index = LineStartIndex("")
        XCTAssertEqual(index.lineCount, 1)
        XCTAssertEqual(index.lineIndex(at: 0), 0)
    }

    func testLineIndexAtOffsets() {
        //           0123 456789
        let text = "abc\ndef\n\nxy"
        let index = LineStartIndex(text)
        XCTAssertEqual(index.lineCount, 4)         // "abc" / "def" / "" / "xy"
        XCTAssertEqual(index.lineIndex(at: 0), 0)
        XCTAssertEqual(index.lineIndex(at: 3), 0)  // 行末の改行はその行に属する
        XCTAssertEqual(index.lineIndex(at: 4), 1)  // 次の行の先頭
        XCTAssertEqual(index.lineIndex(at: 8), 2)  // 空行
        XCTAssertEqual(index.lineIndex(at: 9), 3)
        XCTAssertEqual(index.start(ofLine: 3), 9)
    }

    func testTrailingNewlineGivesAnEmptyLastLine() {
        let index = LineStartIndex("a\nb\n")
        XCTAssertEqual(index.lineCount, 3)          // 末尾の改行の後ろにもキャレットは置ける
        XCTAssertEqual(index.lineIndex(at: 4), 2)
    }

    func testPositionIsOneBasedAndCountsCharactersNotUTF16() {
        let text = "abc\nあ🚀z" as NSString
        let index = LineStartIndex(text)
        XCTAssertEqual(index.position(at: 0, in: text).line, 1)
        XCTAssertEqual(index.position(at: 0, in: text).column, 1)
        XCTAssertEqual(index.position(at: 2, in: text).column, 3)   // "ab" の後ろ＝3 桁目
        // 2 行目: "あ"(UTF-16 1) + "🚀"(UTF-16 2) の後ろは 3 桁目（サロゲートペアを 1 文字と数える）
        let afterRocket = 4 + 1 + 2
        XCTAssertEqual(index.position(at: afterRocket, in: text).line, 2)
        XCTAssertEqual(index.position(at: afterRocket, in: text).column, 3)
    }

    func testPositionClampsOutOfRange() {
        let text = "ab" as NSString
        let index = LineStartIndex(text)
        XCTAssertEqual(index.position(at: 99, in: text).column, 3)
        XCTAssertEqual(index.position(at: -5, in: text).column, 1)
    }

    // MARK: - 不可視文字の記号

    func testTabAndIdeographicSpaceMarkers() {
        let markers = InvisibleGlyphs.markers(in: "a\tb　c")
        XCTAssertEqual(markers, [
            .init(utf16Index: 1, glyph: InvisibleGlyphs.tab),
            .init(utf16Index: 3, glyph: InvisibleGlyphs.ideographicSpace),
        ])
    }

    /// 半角スペースは行末の連なりだけ出す（文中の空白まで点を打つと本文が読めない）。
    func testOnlyTrailingHalfWidthSpacesAreMarked() {
        let markers = InvisibleGlyphs.markers(in: "a b  ")
        XCTAssertEqual(markers.map(\.utf16Index), [3, 4])
        XCTAssertTrue(markers.allSatisfy { $0.glyph == InvisibleGlyphs.trailingSpace })
    }

    func testAllSpacesLineIsAllTrailing() {
        XCTAssertEqual(InvisibleGlyphs.markers(in: "   ").count, 3)
        XCTAssertTrue(InvisibleGlyphs.markers(in: "").isEmpty)
        XCTAssertTrue(InvisibleGlyphs.markers(in: "abc").isEmpty)
    }

    // MARK: - 行の分割

    func testSplitByComma() {
        let out = LineSplitter.split("a,b,c", options: .init(delimiter: ","))
        XCTAssertEqual(out, "a\nb\nc")
    }

    func testSplitKeepsTrailingNewlineAndHandlesEachLine() {
        let out = LineSplitter.split("a,b\nc,d\n", options: .init(delimiter: ","))
        XCTAssertEqual(out, "a\nb\nc\nd\n")
    }

    func testSplitByEscapedTab() {
        let out = LineSplitter.split("a\tb", options: .init(delimiter: "\\t"))
        XCTAssertEqual(out, "a\nb")
    }

    func testSplitTrimAndDropEmpty() {
        let opts = LineSplitter.Options(delimiter: ",", trimEach: true, dropEmpty: true)
        XCTAssertEqual(LineSplitter.split("a , ,b ", options: opts), "a\nb")
        // 既定（trim/drop なし）は空要素もそのまま行にする。
        XCTAssertEqual(LineSplitter.split("a,,b", options: .init(delimiter: ",")), "a\n\nb")
    }

    func testSplitWithEmptyDelimiterIsRefused() {
        XCTAssertNil(LineSplitter.split("abc", options: .init(delimiter: "")))
    }

    /// 日本語キーボードは同じキーで `¥` を打つので、バックスラッシュと同じに扱う。
    func testUnescapeAcceptsYenSignAsEscapeLeader() {
        XCTAssertEqual(LineSplitter.unescape("¥t"), "\t")
        XCTAssertEqual(LineSplitter.unescape("￥n"), "\n")
        XCTAssertEqual(LineSplitter.unescape("¥¥"), "¥")
        XCTAssertEqual(LineSplitter.split("a\tb", options: .init(delimiter: "¥t")), "a\nb")
    }

    func testUnescapeLeavesUnknownEscapesAlone() {
        XCTAssertEqual(LineSplitter.unescape("\\t"), "\t")
        XCTAssertEqual(LineSplitter.unescape("\\n"), "\n")
        XCTAssertEqual(LineSplitter.unescape("\\\\"), "\\")
        XCTAssertEqual(LineSplitter.unescape("\\q"), "\\q")
        XCTAssertEqual(LineSplitter.unescape("a\\"), "a\\")
    }

    /// 連結の逆操作になっている（連結 → 分割で元の行数に戻る）。
    func testJoinThenSplitRoundTrip() {
        let source = "alpha\nbeta\ngamma"
        let joined = try! XCTUnwrap(TextTransform.joinLines.apply(source))
        XCTAssertEqual(joined, "alpha beta gamma")
        XCTAssertEqual(LineSplitter.split(joined, options: .init(delimiter: " ")), source)
    }

    // MARK: - ステータスバーへ流れるキャレット位置（小ファイルペイン）

    func testEditableViewerReportsCaretPosition() {
        let v = EditableViewer()
        var latest: ViewerState?
        v.onStateChange = { latest = $0 }
        v.newDocument()
        v._testSetText("abc\nあいう\n")
        v._testSelect(NSRange(location: 6, length: 0))   // 2 行目「あい」の後ろ
        v.reEmitState()
        XCTAssertEqual(latest?.caret?.line, 2)
        XCTAssertEqual(latest?.caret?.column, 3)

        v._testSelect(NSRange(location: 0, length: 0))
        v.reEmitState()
        XCTAssertEqual(latest?.caret?.line, 1)
        XCTAssertEqual(latest?.caret?.column, 1)
    }

    /// 編集で行がずれても（索引キャッシュを捨てて）正しい行を返す。
    func testCaretPositionFollowsEdits() {
        let v = EditableViewer()
        var latest: ViewerState?
        v.onStateChange = { latest = $0 }
        v.newDocument()
        v._testSetText("one\ntwo")
        v._testSelect(NSRange(location: 7, length: 0))
        v.reEmitState()
        XCTAssertEqual(latest?.caret?.line, 2)

        v._testSetText("one\nmore\ntwo")
        v._testSelect(NSRange(location: 12, length: 0))
        v.reEmitState()
        XCTAssertEqual(latest?.caret?.line, 3)
        XCTAssertEqual(latest?.caret?.column, 4)
    }
}
