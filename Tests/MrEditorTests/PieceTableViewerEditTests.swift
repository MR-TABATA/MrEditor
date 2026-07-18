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

    // MARK: 編集ツールボックス（変換）

    func testTransformUppercasesSelectionAndKeepsItSelected() {
        let v = makeViewer("abcdef")
        v._testSelect(1..<4)                 // "bcd"
        v.applyTextTransform(.uppercase)
        XCTAssertEqual(v._testDocString, "aBCDef")
        XCTAssertEqual(v._testCaret, 4)      // 変換後も末尾へ（選択維持）
        v._testUndo()
        XCTAssertEqual(v._testDocString, "abcdef")
        v._testRedo()
        XCTAssertEqual(v._testDocString, "aBCDef")
    }

    func testTransformNoSelectionIsNoOp() {
        let v = makeViewer("abc")
        v._testSetCaret(1)                   // 選択なし
        v.applyTextTransform(.uppercase)
        XCTAssertEqual(v._testDocString, "abc")
    }

    func testTransformMultibyteReencodes() {
        let v = makeViewer("xAbc")           // 選択にラテンのみ
        v._testSelect(1..<4)                 // "Abc"
        v.applyTextTransform(.lowercase)
        XCTAssertEqual(v._testDocString, "xabc")
    }

    func testSelectedTextNilWithoutSelection() {
        let v = makeViewer("abc")
        v._testSetCaret(1)
        XCTAssertNil(v.selectedText)
    }

    /// 外部コマンド・フィルタの経路（selectedText → ShellFilter → replaceSelection）を
    /// 巨大ファイルペインで通す。sort に流して選択を並べ替える。
    func testFilterPipelineSortsSelection() throws {
        let v = makeViewer("gamma\nalpha\nbeta")   // 16 バイト
        v._testSelect(0..<16)
        let sel = try XCTUnwrap(v.selectedText)
        let filtered = try ShellFilter.run(command: "sort", input: sel)
        v.replaceSelection(with: filtered)
        XCTAssertEqual(v._testDocString, "alpha\nbeta\ngamma\n")
        v._testUndo()
        XCTAssertEqual(v._testDocString, "gamma\nalpha\nbeta")
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

    // MARK: EOL 追従（ファイルの改行コードに合わせて挿入）

    /// CRLF ファイルへ Return を打つと CRLF が挿入される（LF 混入しない）。
    func testInsertNewlineFollowsCRLF() {
        let v = makeViewer("ab\r\ncd")
        v._testSetCaret(2)                 // "ab" の直後（CR の手前）
        v._testCommand("insertNewline:")
        // 挿入された改行は CRLF。既存の CRLF はそのまま。
        XCTAssertEqual(Array(v._testDocBytes), Array("ab\r\n\r\ncd".utf8))
    }

    /// LF ファイルへ CRLF 混じりの文字列を貼り付けると LF に正規化される。
    func testPasteNormalizesCRLFToLF() {
        let v = makeViewer("abcd")
        v._testSetCaret(2)
        v._testInsert("X\r\nY\rZ")
        XCTAssertEqual(v._testDocString, "abX\nY\nZcd")
    }

    /// CRLF ファイルへ LF 混じりの文字列を貼り付けると CRLF に正規化される。
    func testPasteNormalizesLFToCRLF() {
        let v = makeViewer("ab\r\ncd")
        v._testSetCaret(4)                 // 2 行目行頭
        v._testInsert("X\nY")
        XCTAssertEqual(Array(v._testDocBytes), Array("ab\r\nX\r\nYcd".utf8))
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

    // MARK: 置換（B5）

    func testReplaceAllLiteralIsOneUndo() {
        let v = makeViewer("foo bar\nfoo baz\n")
        v._testSetSearch(terms: ["foo"], matchLines: [0, 1])
        v._testReplaceAll("X")
        XCTAssertEqual(v._testDocString, "X bar\nX baz\n")
        XCTAssertTrue(v._testIsDirty)
        v._testUndo()                                   // 1 アンドゥで全戻し
        XCTAssertEqual(v._testDocString, "foo bar\nfoo baz\n")
    }

    func testReplaceAllMultiplePerLine() {
        let v = makeViewer("foo foo foo\n")
        v._testSetSearch(terms: ["foo"], matchLines: [0])
        v._testReplaceAll("X")
        XCTAssertEqual(v._testDocString, "X X X\n")
    }

    func testReplaceCurrentIterative() {
        let v = makeViewer("a foo b foo c")
        v._testSetSearch(terms: ["foo"], matchLines: [0])
        v._testSetCaret(0)
        v._testReplaceCurrent("X")                      // 最初は次の一致を選択
        XCTAssertEqual(v._testSelection, 2..<5)
        v._testReplaceCurrent("X")                      // 選択中を置換→次を選択
        XCTAssertEqual(v._testDocString, "a X b foo c")
        v._testReplaceCurrent("X")
        XCTAssertEqual(v._testDocString, "a X b X c")
    }

    func testReplaceAllRegexTemplate() {
        let v = makeViewer("id=1 id=2\n")
        let rx = try! NSRegularExpression(pattern: "id=(\\d)")
        v._testSetSearch(terms: [], regex: rx, matchLines: [0])
        v._testReplaceAll("[$1]")
        XCTAssertEqual(v._testDocString, "[1] [2]\n")
    }

    // MARK: ダブル/トリプルクリック選択（B7）

    func testDoubleClickSelectsWord() {
        let v = makeViewer("foo bar_baz qux")
        v._testSelectWord(at: 5)                    // "bar_baz" の中
        XCTAssertEqual(v._testSelection, 4..<11)    // "bar_baz"（_ は語文字）
    }

    func testDoubleClickAtWordEnd() {
        let v = makeViewer("foo bar")
        v._testSelectWord(at: 3)                    // "foo" の直後（空白位置）
        XCTAssertEqual(v._testSelection, 0..<3)     // 直前の語 "foo"
    }

    func testDoubleClickMultibyteWord() {
        let v = makeViewer("あいう bbb")            // "あいう"=9バイト
        v._testSelectWord(at: 3)                    // 2文字目
        XCTAssertEqual(v._testSelection, 0..<9)
    }

    func testTripleClickSelectsLine() {
        let v = makeViewer("line one\nline two\nthree")
        v._testSelectLine(at: 11)                   // 2行目内
        XCTAssertEqual(v._testSelection, 9..<18)    // "line two\n"（行頭〜次行頭）
    }

    /// Shift+クリックは既存キャレット（アンカー）からクリック位置まで選択を拡張する。
    func testShiftClickExtendsSelection() {
        let v = makeViewer("hello world")
        v._testClick(at: 2)                         // 通常クリックでアンカーを 2 に
        XCTAssertNil(v._testSelection)              // 選択なし
        v._testClick(at: 8, extend: true)           // Shift+クリック
        XCTAssertEqual(v._testSelection, 2..<8)     // 2〜8 を選択
        // さらに Shift+クリックでアンカー据え置きのまま端点だけ動く（逆方向も可）。
        v._testClick(at: 0, extend: true)
        XCTAssertEqual(v._testSelection, 0..<2)
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

    func testCancelledSaveLeavesDocumentDirtyAndNoFile() throws {
        let v = makeViewer("hello")
        v._testSetCaret(5); v._testInsert(" world")
        XCTAssertTrue(v._testIsDirty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-cancel-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let done = expectation(description: "completion")
        v._testSaveAsync(to: url,
                         onBegin: { v.cancelSave() },       // 書き出し開始前に中断予約
                         progress: { _ in },
                         completion: { ok in
                             XCTAssertFalse(ok)              // キャンセルは失敗扱い（アラート無し）
                             done.fulfill()
                         })
        wait(for: [done], timeout: 5)

        XCTAssertTrue(v._testIsDirty)                        // 保存されていないので dirty のまま
        XCTAssertFalse(v._testIsSaving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))   // 出力は残さない
    }

    /// 大ファイル経路: 保存エンコードを Shift-JIS に変えて保存すると、実体が Shift-JIS になる。
    /// （setSaveEncoding → saveAsync の transcode → atomic 差し替え → 開き直しまでを通す。）
    func testSetSaveEncodingThenSaveReencodesLargePath() throws {
        let text = "日本語のログ\nエラー: 発生\n最終行"    // 複数行・末尾改行なし・マルチバイト
        let v = makeViewer("")
        v._testLoad(Array(text.utf8))                       // source = UTF-8
        v._testSetSaveEncoding(.shiftJIS)                   // 変換を予約
        XCTAssertEqual(v._testSaveEncoding, .shiftJIS)
        XCTAssertTrue(v._testIsDirty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-convert-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let done = expectation(description: "completion")
        v._testSaveAsync(to: url,
                         onBegin: {}, progress: { _ in },
                         completion: { ok in XCTAssertTrue(ok); done.fulfill() })
        wait(for: [done], timeout: 5)

        let saved = try Data(contentsOf: url)
        XCTAssertEqual(saved, text.data(using: .shiftJIS))  // ディスク実体が Shift-JIS
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

    // MARK: LineEnding 検出

    func testLineEndingDetect() {
        func detect(_ s: String, _ enc: DetectedEncoding = .utf8) -> LineEnding {
            LineEnding.detect(s.data(using: enc.stringEncoding)!, encoding: enc)
        }
        XCTAssertEqual(detect("a\nb"), .lf)
        XCTAssertEqual(detect("a\r\nb"), .crlf)
        XCTAssertEqual(detect("a\rb"), .cr)          // 旧 Mac（LF を伴わない CR）
        XCTAssertEqual(detect("no newline"), .lf)    // 改行が無ければ LF 既定
        // UTF-16 は 2 バイト単位でも正しく分類する。
        XCTAssertEqual(detect("a\r\nb", .utf16LE), .crlf)
        XCTAssertEqual(detect("a\nb", .utf16BE), .lf)
    }

    func testLineEndingNormalize() {
        XCTAssertEqual(LineEnding.crlf.normalize("a\nb\r\nc\rd"), "a\r\nb\r\nc\r\nd")
        XCTAssertEqual(LineEnding.lf.normalize("a\r\nb\rc"), "a\nb\nc")
        XCTAssertEqual(LineEnding.cr.normalize("a\r\nb\nc"), "a\rb\rc")
        XCTAssertEqual(LineEnding.crlf.normalize("no newline"), "no newline")
    }
}
