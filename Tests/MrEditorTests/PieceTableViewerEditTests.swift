import XCTest
import AppKit
@testable import MrEditor

/// B2b（テキスト変異＋Undo/Redo＋Cut/Paste）を document 単位でヘッドレス検証する。
/// GUI を立てず、`PieceTableViewer` のテスト用シーム経由で編集パイプラインを駆動する。
final class PieceTableViewerEditTests: XCTestCase {
    private func makeViewer(_ text: String) -> PieceTableViewer {
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(text.utf8))
        return v
    }

    // MARK: 挿入

    func testInsertAtCaretAdvancesAndUndoRedo() {
        let v = makeViewer("hello")
        v._testSetCaret(5)
        v._testInsert(" world")
        XCTAssertEqual(v._testDocString, "hello world")
        XCTAssertEqual(v._testCaret, 11)

        v._testUndo()
        XCTAssertEqual(v._testDocString, "hello")
        XCTAssertEqual(v._testCaret, 5)

        v._testRedo()
        XCTAssertEqual(v._testDocString, "hello world")
        XCTAssertEqual(v._testCaret, 11)
    }

    func testInsertInMiddle() {
        let v = makeViewer("abcd")
        v._testSetCaret(2)
        v._testInsert("XY")
        XCTAssertEqual(v._testDocString, "abXYcd")
        XCTAssertEqual(v._testCaret, 4)
    }

    func testTypingOverSelectionReplaces() {
        let v = makeViewer("abcdef")
        v._testSelect(1..<4)          // "bcd"
        v._testInsert("Z")
        XCTAssertEqual(v._testDocString, "aZef")
        XCTAssertEqual(v._testCaret, 2)
        v._testUndo()
        XCTAssertEqual(v._testDocString, "abcdef")
    }

    // MARK: 改行

    func testInsertNewlineSplitsLine() {
        let v = makeViewer("abcd")
        XCTAssertEqual(v._testLineCount, 1)
        v._testSetCaret(2)
        v._testCommand("insertNewline:")
        XCTAssertEqual(v._testDocString, "ab\ncd")
        XCTAssertEqual(v._testLineCount, 2)
        XCTAssertEqual(v._testCaret, 3)
    }

    // MARK: 削除

    func testDeleteBackwardChar() {
        let v = makeViewer("abc")
        v._testSetCaret(3)
        v._testCommand("deleteBackward:")
        XCTAssertEqual(v._testDocString, "ab")
        XCTAssertEqual(v._testCaret, 2)
    }

    func testDeleteBackwardAtLineStartMergesLF() {
        let v = makeViewer("ab\ncd")
        v._testSetCaret(3)            // 2行目の先頭（\n の直後）
        v._testCommand("deleteBackward:")
        XCTAssertEqual(v._testDocString, "abcd")
        XCTAssertEqual(v._testCaret, 2)
    }

    func testDeleteBackwardAtLineStartMergesCRLF() {
        let v = makeViewer("ab\r\ncd")
        v._testSetCaret(4)            // 2行目の先頭（\r\n の直後）
        v._testCommand("deleteBackward:")
        XCTAssertEqual(v._testDocString, "abcd")   // CR と LF の両方が消える
        XCTAssertEqual(v._testCaret, 2)
    }

    func testDeleteForwardChar() {
        let v = makeViewer("abc")
        v._testSetCaret(1)
        v._testCommand("deleteForward:")
        XCTAssertEqual(v._testDocString, "ac")
        XCTAssertEqual(v._testCaret, 1)
    }

    func testDeleteForwardAtLineEndMergesCRLF() {
        let v = makeViewer("ab\r\ncd")
        v._testSetCaret(2)            // 1行目末（内容末尾、CR の手前）
        v._testCommand("deleteForward:")
        XCTAssertEqual(v._testDocString, "abcd")
        XCTAssertEqual(v._testCaret, 2)
    }

    func testDeleteWordBackward() {
        let v = makeViewer("foo bar baz")
        v._testSetCaret(11)
        v._testCommand("deleteWordBackward:")
        XCTAssertEqual(v._testDocString, "foo bar ")
        XCTAssertEqual(v._testCaret, 8)
    }

    // MARK: 切り取り / 貼り付け

    func testCutThenPaste() {
        let v = makeViewer("hello world")
        v._testSelect(0..<5)          // "hello"
        v._testCut()
        XCTAssertEqual(v._testDocString, " world")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")

        v._testSetCaret(v._testDocBytes.count)   // 末尾へ
        v._testPaste()
        XCTAssertEqual(v._testDocString, " worldhello")
    }

    func testCutIsUndoable() {
        let v = makeViewer("hello world")
        v._testSelect(0..<6)          // "hello "
        v._testCut()
        XCTAssertEqual(v._testDocString, "world")
        v._testUndo()
        XCTAssertEqual(v._testDocString, "hello world")
    }

    // MARK: マルチバイト（UTF-8 書記素）

    func testInsertAndDeleteMultibyte() {
        let v = makeViewer("あい")            // 各 3 バイト
        v._testSetCaret(6)                    // 末尾
        v._testInsert("う")
        XCTAssertEqual(v._testDocString, "あいう")
        v._testCommand("deleteBackward:")     // 1 書記素（3 バイト）まるごと
        XCTAssertEqual(v._testDocString, "あい")
        XCTAssertEqual(v._testCaret, 6)
    }
}
