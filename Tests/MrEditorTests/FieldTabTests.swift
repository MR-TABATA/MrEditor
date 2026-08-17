import XCTest
import AppKit
@testable import MrEditorCore

/// 桁ガイドがあるとき、Tab が「次の項目の桁まで空白を詰める」こと。
///
/// **欲しいのはキャレットが飛ぶことではなく、桁が揃うこと。** ワープロのタブ位置と同じで、
/// 打っている途中で Tab を押したら、後ろの字がその桁までずれる。
final class FieldTabTests: XCTestCase {

    private func pane(_ text: String, guides: [Int]) -> EditableViewer {
        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        v._testSetText(text)
        v.setColumnGuides(guides)
        v._testSelect(NSRange(location: 0, length: 0))
        return v
    }

    /// 打ちかけの行で Tab を押すと、次の項目の桁まで空白が入って**字がずれる**。
    func testTabPadsToNextFieldStart() {
        let v = pane("123\n", guides: [9, 15])
        v._testSelect(NSRange(location: 3, length: 0))     // "123" の直後＝4 桁目
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testText, "123     \n", "9 桁目まで空白 5 つ")
        XCTAssertEqual(v._testSelection.location, 8)
    }

    /// 後ろに字があるときは、その字ごと次の桁へずれる（挿入なので当然だが、ここが要件）。
    func testTabShiftsFollowingText() {
        let v = pane("12TOKYO\n", guides: [9])
        v._testSelect(NSRange(location: 2, length: 0))
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testText, "12      TOKYO\n", "TOKYO が 9 桁目へずれる")
    }

    /// **タブ文字は入れない。** 固定長にタブが混ざると、他の道具で読んだ瞬間に桁が崩れる。
    func testTabNeverInsertsATabCharacter() {
        let v = pane("1\n", guides: [5])
        v._testSelect(NSRange(location: 1, length: 0))
        XCTAssertTrue(v._testFieldTab())
        XCTAssertFalse(v._testText.contains("\t"))
        XCTAssertEqual(v._testText, "1   \n")
    }

    /// 桁は表示幅（全角＝2）。文字数で詰めると全角の行だけ揃わない。
    func testPadsByDisplayWidth() {
        let v = pane("東京\n", guides: [7])       // 全角 2 文字＝4 桁ぶん
        v._testSelect(NSRange(location: 2, length: 0))
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testText, "東京  \n", "5・6 桁目を空白で埋めて 7 桁目へ")
    }

    /// ⇧Tab は詰めた空白を**前の項目の桁まで**取り除く（字は消さない）。
    func testBacktabRemovesPaddingOnly() {
        let v = pane("123     \n", guides: [9, 15])
        v._testSelect(NSRange(location: 8, length: 0))
        XCTAssertTrue(v._testFieldTab(backwards: true))
        XCTAssertEqual(v._testText, "123\n", "空白だけが消える")

        let v2 = pane("12345678ABC\n", guides: [9])
        v2._testSelect(NSRange(location: 11, length: 0))
        XCTAssertTrue(v2._testFieldTab(backwards: true))
        XCTAssertEqual(v2._testText, "12345678ABC\n", "空白でない字は消さない")
    }

    /// 最後の項目より右では詰めない（行がどこまでも伸びるのを防ぐ）。
    func testNoPaddingPastTheLastField() {
        let v = pane("12345678ABCDEF0123\n", guides: [9, 15])
        v._testSelect(NSRange(location: 18, length: 0))
        XCTAssertTrue(v._testFieldTab(), "受けはするが")
        XCTAssertEqual(v._testText, "12345678ABCDEF0123\n", "本文は変わらない")
    }

    /// ガイドが無ければ受けない＝**タブ文字がこれまでどおり入る**。
    func testNoGuidesFallsBackToTabCharacter() {
        XCTAssertFalse(pane("00012345TOKYO\n", guides: [])._testFieldTab())
        XCTAssertFalse(pane("abc\n", guides: [1])._testFieldTab(), "1 桁目のガイドは切れ目ではない")
    }

    // MARK: - 1 行目の桁割りを、残りの行へ

    /// **これが本命。** 1 行目を Tab で整えたら、同じ桁割りを全行へ当てる。
    func testAlignAppliesTheLayoutToEveryLine() {
        let v = pane("123 TOKYO 20260815\n4567 OSAKA 20260101\n89 NAGOYA 20251231\n", guides: [9, 15])
        XCTAssertTrue(v.alignToColumnGuides())
        XCTAssertEqual(v._testText,
                       "123     TOKYO 20260815\n4567    OSAKA 20260101\n89      NAGOYA 20251231\n")
    }

    /// 選択があるときは、その選択が掛かっている行だけ（行の途中で切らない）。
    func testAlignOnlyTouchesSelectedLines() {
        let v = pane("123 TOKYO\n4567 OSAKA\n", guides: [9])
        v._testSelect(NSRange(location: 2, length: 2))     // 1 行目の途中だけを選択
        XCTAssertTrue(v.alignToColumnGuides())
        XCTAssertEqual(v._testText, "123     TOKYO\n4567 OSAKA\n", "2 行目は触らない")
    }

    /// 1 アンドゥで元に戻る（何百行を当てても 1 回）。
    func testAlignIsOneUndo() {
        let v = pane("1 A\n2 B\n", guides: [9])
        v.alignToColumnGuides()
        XCTAssertEqual(v._testText, "1       A\n2       B\n")
        v._testUndo()
        XCTAssertEqual(v._testText, "1 A\n2 B\n")
    }

    /// 切れ目が無ければ何もしない。
    func testAlignNeedsBoundaries() {
        XCTAssertFalse(pane("1 A\n", guides: [])._testText.isEmpty)
        XCTAssertFalse(pane("1 A\n", guides: []).alignToColumnGuides())
    }

    /// 詰めた空白は 1 アンドゥで戻る。
    func testPaddingIsOneUndo() {
        let v = pane("123\n", guides: [9])
        v._testSelect(NSRange(location: 3, length: 0))
        v._testFieldTab()
        XCTAssertEqual(v._testText, "123     \n")
        v._testUndo()
        XCTAssertEqual(v._testText, "123\n")
    }
}
