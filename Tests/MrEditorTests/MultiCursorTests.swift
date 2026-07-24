import XCTest
import AppKit
@testable import MrEditor

/// マルチカーソル（範囲計算＋NSTextView 上の実挙動）、連番のパラメータ化、
/// 置換のケース維持を検証する。
final class MultiCursorTests: XCTestCase {

    // MARK: - 範囲の集合（MultiCursor）

    func testTogglingAddsThenRemovesSameCaret() {
        let one = [NSRange(location: 3, length: 0)]
        let two = MultiCursor.toggling(one, at: NSRange(location: 7, length: 0))
        XCTAssertEqual(two, [NSRange(location: 3, length: 0), NSRange(location: 7, length: 0)])
        // 同じ位置をもう一度 ⌘クリック＝そのキャレットを外す。
        XCTAssertEqual(MultiCursor.toggling(two, at: NSRange(location: 7, length: 0)), one)
    }

    /// 最後の 1 個は外せない（キャレットが 0 個になる状態を作らない）。
    func testTogglingKeepsLastCaret() {
        let one = [NSRange(location: 3, length: 0)]
        XCTAssertEqual(MultiCursor.toggling(one, at: NSRange(location: 3, length: 0)), one)
    }

    func testNormalizeSortsAndMergesOverlaps() {
        let ranges = [NSRange(location: 10, length: 3), NSRange(location: 0, length: 2),
                      NSRange(location: 11, length: 5)]
        XCTAssertEqual(MultiCursor.normalize(ranges),
                       [NSRange(location: 0, length: 2), NSRange(location: 10, length: 6)])
    }

    /// 選択の内側／端に落ちた空キャレットは選択に吸収する（重複キャレットを作らない）。
    func testNormalizeAbsorbsCaretsInsideSelection() {
        let ranges = [NSRange(location: 5, length: 3), NSRange(location: 6, length: 0),
                      NSRange(location: 8, length: 0)]
        XCTAssertEqual(MultiCursor.normalize(ranges), [NSRange(location: 5, length: 3)])
    }

    // MARK: - 上下にキャレットを足す

    func testAddCaretBelowKeepsColumn() {
        let text = "abcdef\nghijkl\n" as NSString
        let ranges = [NSRange(location: 3, length: 0)]           // 1 行目・3 桁目
        let out = MultiCursor.addingCaret(to: ranges, above: false, in: text)
        XCTAssertEqual(out, [NSRange(location: 3, length: 0), NSRange(location: 10, length: 0)])
    }

    /// 隣の行が短いときは行末で止める（改行を飛び越えてさらに次の行へ入らない）。
    func testAddCaretBelowClampsToShorterLine() {
        let text = "abcdef\ngh\n" as NSString
        let out = MultiCursor.addingCaret(to: [NSRange(location: 5, length: 0)], above: false, in: text)
        XCTAssertEqual(out.last, NSRange(location: 9, length: 0))   // "gh" の行末
    }

    func testAddCaretAboveAtFirstLineDoesNothing() {
        let text = "abc\ndef" as NSString
        let ranges = [NSRange(location: 1, length: 0)]
        XCTAssertEqual(MultiCursor.addingCaret(to: ranges, above: true, in: text), ranges)
    }

    func testAddCaretBelowAtLastLineDoesNothing() {
        let text = "abc\ndef" as NSString
        let ranges = [NSRange(location: 5, length: 0)]
        XCTAssertEqual(MultiCursor.addingCaret(to: ranges, above: false, in: text), ranges)
    }

    // MARK: - 次の同じ語（⌘D）

    func testWordRangeAtCaretInsideAndAfterWord() {
        let text = "let total = 1" as NSString
        XCTAssertEqual(MultiCursor.wordRange(at: 5, in: text), NSRange(location: 4, length: 5))
        // 語の直後にキャレットがあるときも同じ語を掴む。
        XCTAssertEqual(MultiCursor.wordRange(at: 9, in: text), NSRange(location: 4, length: 5))
        XCTAssertNil(MultiCursor.wordRange(at: 11, in: text))  // "=" の後ろの空白＝掴む語が無い
    }

    func testNextOccurrenceSkipsAlreadySelectedAndWraps() {
        let text = "foo bar foo baz foo" as NSString
        let selected = [NSRange(location: 0, length: 3)]
        let second = MultiCursor.nextOccurrence(of: "foo", in: text, after: 3, excluding: selected)
        XCTAssertEqual(second, NSRange(location: 8, length: 3))

        // 末尾まで採ったら先頭へ回り込み、すでに選択済みの一致は飛ばして nil。
        let all = [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3), NSRange(location: 16, length: 3)]
        XCTAssertNil(MultiCursor.nextOccurrence(of: "foo", in: text, after: 19, excluding: all))
    }

    // MARK: - 編集後のキャレット位置

    func testCaretsAfterReplacingAccumulateOffsets() {
        let ranges = [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0)]
        XCTAssertEqual(MultiCursor.caretsAfterReplacing(ranges, with: ["X", "X"]),
                       [NSRange(location: 1, length: 0), NSRange(location: 6, length: 0)])
    }

    func testCaretsAfterReplacingSelections() {
        let ranges = [NSRange(location: 0, length: 3), NSRange(location: 10, length: 3)]
        // 1 つ目で 1 文字縮んだぶん、2 つ目のキャレットは 10+2-1=11。
        XCTAssertEqual(MultiCursor.caretsAfterReplacing(ranges, with: ["ab", "ab"]),
                       [NSRange(location: 2, length: 0), NSRange(location: 11, length: 0)])
    }

    func testDeletionRangesBackwardDropsCaretAtDocumentStart() {
        let text = "abc\ndef" as NSString
        let ranges = [NSRange(location: 0, length: 0), NSRange(location: 6, length: 0)]
        XCTAssertEqual(MultiCursor.deletionRanges(ranges, forward: false, in: text),
                       [NSRange(location: 5, length: 1)])
    }

    func testDeletionRangesForwardKeepsSelections() {
        let text = "abcdef" as NSString
        let ranges = [NSRange(location: 1, length: 2), NSRange(location: 5, length: 0)]
        XCTAssertEqual(MultiCursor.deletionRanges(ranges, forward: true, in: text),
                       [NSRange(location: 1, length: 2), NSRange(location: 5, length: 1)])
    }

    // MARK: - NSTextView 上の実挙動（EditorTextView）

    private func makeTextView(_ s: String) -> EditorTextView {
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = s
        return tv
    }

    /// NSTextView は長さ 0 の範囲を複数持てないので、キャレット列は専用の口から入れる。
    private func setCarets(_ tv: EditorTextView, _ ranges: [NSRange]) {
        tv._testSetCarets(ranges)
    }

    func testTypingInsertsAtEveryCaret() {
        let tv = makeTextView("aaa\nbbb\nccc")
        setCarets(tv, [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0),
                       NSRange(location: 8, length: 0)])
        tv.insertText("- ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "- aaa\n- bbb\n- ccc")
        // 挿入した文字列の直後へキャレットが動く。
        XCTAssertEqual(tv._testCarets,
                       [NSRange(location: 2, length: 0), NSRange(location: 8, length: 0),
                        NSRange(location: 14, length: 0)])
    }

    /// 選択が複数あるときは各選択が置き換わる（⌘D で語を集めてから打ち直す流れ）。
    func testTypingReplacesEverySelection() {
        let tv = makeTextView("foo bar foo")
        setCarets(tv, [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
        tv.insertText("qux", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "qux bar qux")
    }

    func testDeleteBackwardAtEveryCaret() {
        let tv = makeTextView("a1b\na2b")
        setCarets(tv, [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0)])
        tv.deleteBackward(nil)
        XCTAssertEqual(tv.string, "ab\nab")
    }

    func testSingleCaretKeepsStandardBehaviour() {
        let tv = makeTextView("abc")
        setCarets(tv, [NSRange(location: 3, length: 0)])
        tv.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "abcd")
        XCTAssertFalse(tv.hasMultipleCarets)
    }

    func testSelectNextOccurrenceGrowsSelectionThenEscapeCollapses() {
        let tv = makeTextView("foo bar foo baz foo")
        setCarets(tv, [NSRange(location: 1, length: 0)])   // 1 つ目の foo の中
        tv.selectNextOccurrence()                          // 語を掴む
        XCTAssertEqual(tv._testCarets, [NSRange(location: 0, length: 3)])
        tv.selectNextOccurrence()                          // 2 つ目
        tv.selectNextOccurrence()                          // 3 つ目
        XCTAssertEqual(tv._testCarets.count, 3)
        XCTAssertTrue(tv.hasMultipleCarets)

        tv.cancelOperation(nil)                            // Esc で単一へ
        XCTAssertFalse(tv.hasMultipleCarets)
    }

    func testAddCaretBelowThenTypeHitsBothLines() {
        let tv = makeTextView("abc\ndef")
        setCarets(tv, [NSRange(location: 0, length: 0)])
        tv.addCaret(above: false)
        tv.insertText("#", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "#abc\n#def")
    }

    // MARK: - 連番のパラメータ化

    func testNumberLinesDefaultsMatchPlainTransform() {
        let source = "a\nb\nc\n"
        XCTAssertEqual(LineNumberer.number(source, options: .init()), "1\ta\n2\tb\n3\tc\n")
        XCTAssertEqual(TextTransform.numberLines.apply(source), LineNumberer.number(source, options: .init()))
    }

    func testNumberLinesStartStepAndPad() {
        let opts = LineNumberer.Options(start: 10, step: 5, padWidth: 4, separator: ": ")
        XCTAssertEqual(LineNumberer.number("a\nb\nc", options: opts), "0010: a\n0015: b\n0020: c")
    }

    func testNumberLinesNegativeStepAndSign() {
        let opts = LineNumberer.Options(start: 1, step: -2, padWidth: 3, separator: " ")
        XCTAssertEqual(LineNumberer.number("a\nb\nc", options: opts), "001 a\n-001 b\n-003 c")
    }

    /// 区切りは分割ダイアログと同じエスケープ（`\t` / 日本語キーボードの `¥t`）で書ける。
    func testNumberLinesSeparatorEscapes() {
        XCTAssertEqual(LineNumberer.number("a", options: .init(separator: "\\t")), "1\ta")
        XCTAssertEqual(LineNumberer.number("a", options: .init(separator: "¥t")), "1\ta")
    }

    func testNumberLinesKeepsTrailingNewline() {
        XCTAssertEqual(LineNumberer.number("a\nb", options: .init()), "1\ta\n2\tb")
        XCTAssertEqual(LineNumberer.number("a\nb\n", options: .init()), "1\ta\n2\tb\n")
    }

    // MARK: - 置換のケース維持

    func testPreserveCaseAppliesMatchedShape() {
        XCTAssertEqual(CasePreserving.apply("timeout", matching: "DEADLINE"), "TIMEOUT")
        XCTAssertEqual(CasePreserving.apply("timeout", matching: "deadline"), "timeout")
        XCTAssertEqual(CasePreserving.apply("timeout", matching: "Deadline"), "Timeout")
    }

    /// 判定できない綴り（camelCase・記号のみ・日本語）は置換文字列をそのまま使う。
    func testPreserveCaseLeavesMixedAlone() {
        XCTAssertEqual(CasePreserving.apply("newValue", matching: "oldValue"), "newValue")
        XCTAssertEqual(CasePreserving.apply("newValue", matching: "---"), "newValue")
        XCTAssertEqual(CasePreserving.apply("newValue", matching: "見出し"), "newValue")
    }

    /// 先頭が英字でない置換文字列でも、最初の英字だけを大文字にする。
    func testPreserveCaseCapitalizesFirstLetterOnly() {
        XCTAssertEqual(CasePreserving.apply("_value", matching: "Old"), "_Value")
        XCTAssertEqual(CasePreserving.apply("", matching: "Old"), "")
    }

    func testPreserveCaseStyleDetection() {
        XCTAssertEqual(CasePreserving.style(of: "ABC"), .upper)
        XCTAssertEqual(CasePreserving.style(of: "abc"), .lower)
        XCTAssertEqual(CasePreserving.style(of: "Abc"), .capitalized)
        XCTAssertEqual(CasePreserving.style(of: "aBc"), .mixed)
        XCTAssertEqual(CasePreserving.style(of: "123"), .mixed)
    }
}

extension CasePreserving.Style: Equatable {}
