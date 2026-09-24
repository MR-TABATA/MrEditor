import XCTest
import AppKit
@testable import MrEditorCore

/// 検索語の履歴（バックログ「検索語の履歴」）。
///
/// `NSSearchField.recentsAutosaveName` は「`recentSearches` をユーザ既定へ自動で
/// 読み書きする」までしかやってくれない。**確定した語を配列に積むのはこちら側の仕事**
/// （最初これを勘違いして Enter だけで自動的に溜まると思っていたが、実機で溜まらなかった）。
/// ここでは「積む・重複を消す・新しい順にする・上限で切る」という自前ロジックだけを見る。
final class SearchHistoryTests: XCTestCase {
    /// `recentsAutosaveName` はユーザ既定に永続化されるので、`SearchBarView()` を
    /// 新しく作っても前のテストの履歴を引き継ぐ。毎回消してから始める。
    private func freshBar() -> SearchBarView {
        let bar = SearchBarView()
        bar._testResetHistory()
        return bar
    }

    func testRecentsAutosaveNameEnabled() {
        let bar = freshBar()
        XCTAssertNotNil(bar._testSearchHistoryAutosaveName)
        XCTAssertFalse(bar._testSearchHistoryAutosaveName!.isEmpty)
    }

    /// メニューテンプレートが立っていないと、虫眼鏡アイコンに「最近の検索」メニュー自体が出ない。
    func testSearchMenuTemplateEnabled() {
        let bar = freshBar()
        XCTAssertTrue(bar._testSearchHistoryMenuEnabled)
    }

    func testCommittedSearchIsRemembered() {
        let bar = freshBar()
        bar._testCommitSearch("alpha")
        XCTAssertEqual(bar._testRecentSearches, ["alpha"])
    }

    func testMostRecentComesFirst() {
        let bar = freshBar()
        bar._testCommitSearch("alpha")
        bar._testCommitSearch("bravo")
        XCTAssertEqual(bar._testRecentSearches, ["bravo", "alpha"])
    }

    /// 同じ語を打ち直したら、重複させずに先頭へ繰り上げる。
    func testRepeatedSearchMovesToFrontWithoutDuplicate() {
        let bar = freshBar()
        bar._testCommitSearch("alpha")
        bar._testCommitSearch("bravo")
        bar._testCommitSearch("alpha")
        XCTAssertEqual(bar._testRecentSearches, ["alpha", "bravo"])
    }

    func testEmptyQueryIsNotRemembered() {
        let bar = freshBar()
        bar._testCommitSearch("")
        XCTAssertTrue(bar._testRecentSearches.isEmpty)
    }

    func testHistoryIsCappedAtMaximumRecents() {
        let bar = freshBar()
        for i in 0..<20 { bar._testCommitSearch("term\(i)") }
        XCTAssertLessThanOrEqual(bar._testRecentSearches.count, 10)
        XCTAssertEqual(bar._testRecentSearches.first, "term19")
    }

    /// 履歴メニューから選んだときは `stringValue` だけが変わり、`controlTextDidChange`
    /// （＝`onQueryChange`）は飛んでこない。`_testCommitSearch` はその経路（打鍵を経ない
    /// stringValue 変更→確定）を再現する。ここで同期しないと、検索欄の表示と実際に
    /// 検索している語がズレる（表示は選んだ語なのにヒットは前の語のまま、という壊れ方をした）。
    func testCommitSyncsQueryEvenWhenSetProgrammatically() {
        let bar = freshBar()
        var received: [String] = []
        bar.onQueryChange = { received.append($0) }
        bar._testCommitSearch("os")
        XCTAssertEqual(received, ["os"])
    }
}
