import XCTest
import AppKit
@testable import MrEditorCore

/// 桁ガイドがあるとき、Tab が「次の項目の先頭」へ飛ぶこと。
///
/// **引いた線がそのままタブ位置になる**——これが線を引いたことの最初の見返りなので、
/// 端（最初/最後の項目）と、全角を含む行での着地点を厚く見る。
final class FieldTabTests: XCTestCase {

    private func pane(_ text: String, guides: [Int]) -> EditableViewer {
        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        v._testSetText(text)
        v.setColumnGuides(guides)
        v._testSelect(NSRange(location: 0, length: 0))
        return v
    }

    /// 1 → 9 → 15 と項目の先頭を渡り歩く。
    func testTabWalksFieldStarts() {
        let v = pane("00012345TOKYO 20260815\n00000007OSAKA 20260101\n", guides: [9, 15])
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testSelection.location, 8, "9 桁目＝8 文字目")
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testSelection.location, 14, "15 桁目")
    }

    /// 最後の項目で Tab を押したら、次の行の先頭項目へ（入力フォームと同じ運び）。
    func testTabWrapsToNextLine() {
        let v = pane("00012345TOKYO 20260815\n00000007OSAKA 20260101\n", guides: [9, 15])
        v._testSelect(NSRange(location: 14, length: 0))   // 1 行目の最後の項目
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testSelection.location, 23, "2 行目の 1 桁目（1 行目は 22 桁＋改行）")
    }

    /// ⇧Tab は前の項目へ。最初の項目からは前の行の**最後の項目**へ。
    func testBacktabWalksBackwards() {
        let v = pane("00012345TOKYO 20260815\n00000007OSAKA 20260101\n", guides: [9, 15])
        v._testSelect(NSRange(location: 14, length: 0))
        XCTAssertTrue(v._testFieldTab(backwards: true))
        XCTAssertEqual(v._testSelection.location, 8)
        XCTAssertTrue(v._testFieldTab(backwards: true))
        XCTAssertEqual(v._testSelection.location, 0)
        XCTAssertTrue(v._testFieldTab(backwards: true))
        XCTAssertEqual(v._testSelection.location, 0, "先頭行の先頭項目より前は無い（タブ文字も入れない）")
    }

    /// ガイドが無ければ受けない＝**タブ文字がこれまでどおり入る**。
    func testNoGuidesFallsBackToTabCharacter() {
        let v = pane("00012345TOKYO 20260815\n", guides: [])
        XCTAssertFalse(v._testFieldTab())
        XCTAssertFalse(pane("abc\n", guides: [1])._testFieldTab(), "1 桁目のガイドは切れ目ではない")
    }

    /// 桁は**表示幅**で数える（全角＝2）。文字数で数えると全角の行だけ着地点がズレる。
    func testLandsByDisplayWidthNotCharacterCount() {
        let v = pane("東京都渋谷区0001\n", guides: [7])       // 全角 3 文字＝6 桁、7 桁目は 4 文字目
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testSelection.location, 3, "全角 3 文字ぶん＝UTF-16 で 3")
    }

    /// 行が短くて項目の先頭に届かないときは行末に着ける（落ちない）。
    func testShortLineLandsAtEndOfLine() {
        let v = pane("0001\n00000007OSAKA\n", guides: [9, 15])
        XCTAssertTrue(v._testFieldTab())
        XCTAssertEqual(v._testSelection.location, 4, "4 文字しかない行の末尾")
    }
}
