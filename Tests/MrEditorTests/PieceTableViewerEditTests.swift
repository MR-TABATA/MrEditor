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

    // MARK: IME（marked text / 変換中・B2c）

    func testMarkedTextIsNotInDocumentUntilCommitted() {
        let v = makeViewer("ab")
        v._testSetCaret(2)
        v._testSetMarked("ん", sel: NSRange(location: 1, length: 0))
        XCTAssertTrue(v._testHasMarked)
        XCTAssertEqual(v._testMarkedText, "ん")
        XCTAssertEqual(v._testDocString, "ab")     // まだドキュメントには入らない
        XCTAssertEqual(v._testCaret, 2)            // キャレット位置（合成起点）は不動

        v._testInsert("引")                         // 確定
        XCTAssertFalse(v._testHasMarked)
        XCTAssertEqual(v._testDocString, "ab引")
        XCTAssertEqual(v._testCaret, 5)            // "引" は 3 バイト
    }

    func testMarkedTextReplacesSelectionOnStart() {
        let v = makeViewer("abcXYZ")
        v._testSelect(1..<4)                        // "bcX"
        v._testSetMarked("ん", sel: NSRange(location: 1, length: 0))
        XCTAssertEqual(v._testDocString, "aYZ")     // 選択は変換開始時に削除
        XCTAssertTrue(v._testHasMarked)
        v._testInsert("変")
        XCTAssertEqual(v._testDocString, "a変YZ")
    }

    func testUnmarkCommitsMarkedText() {
        let v = makeViewer("ab")
        v._testSetCaret(2)
        v._testSetMarked("ん", sel: NSRange(location: 1, length: 0))
        v._testUnmark()
        XCTAssertFalse(v._testHasMarked)
        XCTAssertEqual(v._testDocString, "abん")
    }

    func testEmptyCommitCancelsComposition() {
        let v = makeViewer("ab")
        v._testSetCaret(1)
        v._testSetMarked("ん", sel: NSRange(location: 1, length: 0))
        v._testInsert("")                           // 変換キャンセル（空確定）
        XCTAssertFalse(v._testHasMarked)
        XCTAssertEqual(v._testDocString, "ab")      // 何も挿入されない
    }

    // MARK: 保存（B3）

    func testEditMarksDirtySaveClears() throws {
        let v = makeViewer("hello")
        XCTAssertFalse(v._testIsDirty)
        v._testSetCaret(5); v._testInsert(" world")
        XCTAssertTrue(v._testIsDirty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-b3-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(v._testWrite(to: url))
        XCTAssertFalse(v._testIsDirty)              // 保存で dirty 解除

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "hello world")      // 編集内容がディスクに載る
    }

    func testSaveOverExistingFileReplacesAtomically() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-b3-\(UUID().uuidString).txt")
        try "original content\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let v = makeViewer("")
        v._testLoad(Array("edited\nlines\n".utf8))
        XCTAssertTrue(v._testWrite(to: url))
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "edited\nlines\n")
    }

    func testAsyncSaveWritesAndClearsDirtyAndBlocksEditWhileSaving() throws {
        let v = makeViewer("hello")
        v._testSetCaret(5); v._testInsert(" world")
        XCTAssertTrue(v._testIsDirty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-async-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let began = expectation(description: "onBegin")
        let done = expectation(description: "completion")
        v._testSaveAsync(to: url,
                         onBegin: {
                             // 保存中は編集がブロックされる（背景で全文を読むため）。
                             XCTAssertTrue(v._testIsSaving)
                             v._testInsert("XXX")            // 無視されるはず
                             began.fulfill()
                         },
                         progress: { _ in },
                         completion: { ok in XCTAssertTrue(ok); done.fulfill() })
        wait(for: [began, done], timeout: 5)

        XCTAssertFalse(v._testIsDirty)
        XCTAssertFalse(v._testIsSaving)
        XCTAssertEqual(v._testDocString, "hello world")     // 保存中の "XXX" は入っていない
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello world")
    }

    func testSaveLargerDocumentRoundTrips() throws {
        // 多数の挿入でピースを増やしても、ストリーム書き出しが全内容を保てる。
        let v = makeViewer("")
        v._testLoad(Array("start\n".utf8))
        for i in 0..<200 { v._testSetCaret(v._testDocBytes.count); v._testInsert("line \(i)\n") }
        let expected = v._testDocString

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-b3-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(v._testWrite(to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
    }
}
