import XCTest
@testable import MrEditorCore

/// しおり。**調査は往復する** —— 絞り込んで見つけた行から本文へ飛び、周りを読み、
/// また戻る。戻り先を覚えていられるのは 1 つか 2 つで、超えると行番号をメモに
/// 書き写すことになる。その写し取りを道具の中に入れる。
final class BookmarkTests: XCTestCase {

    private func viewer(_ text: String) -> EditableViewer {
        let v = EditableViewer()
        v.newDocument()
        v._testSetText(text)
        v._testSelect(NSRange(location: 0, length: 0))
        return v
    }

    func testTogglingTwiceLeavesNoBookmark() {
        let v = viewer("a\nb\nc\n")
        v.toggleBookmark()
        XCTAssertEqual(v.bookmarkedLines, [0])
        v.toggleBookmark()
        XCTAssertTrue(v.bookmarkedLines.isEmpty)
    }

    func testBookmarksLandOnTheCaretLine() {
        let v = viewer("a\nb\nc\n")
        v._testSelect(NSRange(location: 2, length: 0))   // 2 行目
        v.toggleBookmark()
        XCTAssertEqual(v.bookmarkedLines, [1])
    }

    func testJumpMovesToTheNextBookmarkNotTheCurrentLine() {
        // いまの行そのものへ飛ぶと、押しても動かないボタンになる。
        let v = viewer("a\nb\nc\nd\n")
        v._testSelect(NSRange(location: 0, length: 0)); v.toggleBookmark()   // 1 行目
        v._testSelect(NSRange(location: 4, length: 0)); v.toggleBookmark()   // 3 行目
        v._testSelect(NSRange(location: 0, length: 0))
        v.goToBookmark(forward: true)
        XCTAssertEqual(v._testSelection.location, 4)
    }

    func testJumpBackwardFindsTheEarlierBookmark() {
        let v = viewer("a\nb\nc\nd\n")
        v._testSelect(NSRange(location: 0, length: 0)); v.toggleBookmark()
        v._testSelect(NSRange(location: 6, length: 0))                       // 4 行目
        v.goToBookmark(forward: false)
        XCTAssertEqual(v._testSelection.location, 0)
    }

    func testNothingToJumpToLeavesThePositionAlone() {
        // 飛び先が無ければ動かない（メニューも無効になる）。黙って先頭へ戻ると、
        // 見ていた場所を失う。
        let v = viewer("a\nb\n")
        v._testSelect(NSRange(location: 2, length: 0))
        v.goToBookmark(forward: true)
        XCTAssertEqual(v._testSelection.location, 2)
    }
}
