import XCTest
@testable import MrEditorCore

/// 遠隔で直した行の預かり（B12）。**直せない行を直せることにしない**のが肝。
final class RemoteEditsTests: XCTestCase {

    func testStageKeepsTheFirstOpenedTextAsTheBaseline() {
        var e = RemoteEdits()
        e.stage(line: 3, original: "old", edited: "mid")
        e.stage(line: 3, original: "mid", edited: "new")   // 2 回目の original は画面の値でも、基準は最初のまま
        XCTAssertEqual(e.edit(at: 3)?.original, "old")
        XCTAssertEqual(e.edit(at: 3)?.edited, "new")
        XCTAssertEqual(e.count, 1)
    }

    func testRestoringTheOriginalTextDropsTheEdit() {
        var e = RemoteEdits()
        e.stage(line: 1, original: "a", edited: "b")
        XCTAssertFalse(e.stage(line: 1, original: "a", edited: "a"))
        XCTAssertTrue(e.isEmpty)
    }

    func testAllIsSortedByLineAndCommitRemoves() {
        var e = RemoteEdits()
        e.stage(line: 9, original: "x", edited: "y")
        e.stage(line: 2, original: "x", edited: "yy")
        XCTAssertEqual(e.all.map(\.line), [2, 9])
        e.commit(line: 2)
        XCTAssertEqual(e.all.map(\.line), [9])
    }

    /// 長さが変わる編集の数。バイトで数える（「あ」→「a」は文字数が同じでも長さが違う）。
    func testRewriteCountIsByBytes() {
        var e = RemoteEdits()
        e.stage(line: 1, original: "abc", edited: "xyz")      // 同じ
        e.stage(line: 2, original: "あ", edited: "a")          // 3B → 1B
        e.stage(line: 3, original: "a", edited: "ab")
        XCTAssertEqual(e.rewriteCount, 2)
    }

    // MARK: - 直してよい行

    func testLineWithoutNumberIsNotEditable() {
        XCTAssertFalse(RemoteEdits.isEditable(RemoteLine(number: nil, isMatch: false, text: "x")))
        XCTAssertTrue(RemoteEdits.isEditable(RemoteLine(number: 1, isMatch: false, text: "x")))
    }

    /// 読めなかったバイトが置換文字に化けた行を直すと、元のバイトが失われる。
    func testLineWithReplacementCharacterIsNotEditable() {
        let bad = String(decoding: [0x61, 0xFF, 0x62], as: UTF8.self)
        XCTAssertTrue(bad.contains("\u{FFFD}"))
        XCTAssertFalse(RemoteEdits.isEditable(RemoteLine(number: 1, isMatch: false, text: bad)))
    }

    func testVeryLongLineIsNotEditable() {
        let long = String(repeating: "a", count: RemoteEdits.maxLineBytes + 1)
        XCTAssertFalse(RemoteEdits.isEditable(RemoteLine(number: 1, isMatch: false, text: long)))
    }

    // MARK: - CRLF と改行

    func testCarriageReturnIsHiddenAndRestored() {
        XCTAssertEqual(RemoteEdits.display("abc\r"), "abc")
        XCTAssertEqual(RemoteEdits.raw(display: "xyz", original: "abc\r"), "xyz\r")
        XCTAssertEqual(RemoteEdits.raw(display: "xyz", original: "abc"), "xyz")
    }

    func testNewlineInInputIsRejected() {
        XCTAssertNil(RemoteEdits.raw(display: "a\nb", original: "x"))
        XCTAssertNil(RemoteEdits.raw(display: "a\rb", original: "x"))
    }

    func testTextForShowsTheEditedText() {
        var e = RemoteEdits()
        e.stage(line: 4, original: "a", edited: "b")
        XCTAssertEqual(e.text(for: RemoteLine(number: 4, isMatch: false, text: "a")), "b")
        XCTAssertEqual(e.text(for: RemoteLine(number: 5, isMatch: false, text: "a")), "a")
        XCTAssertEqual(e.text(for: RemoteLine(number: nil, isMatch: false, text: "a")), "a")
    }
}
