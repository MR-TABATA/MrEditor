import XCTest
import AppKit
@testable import MrEditorCore

/// ⌘F を開いたときの漏斗（一致行だけ表示）の初期状態。
///
/// B2: 構造化されたものを読んでいる間、主目的は「一致行へ飛ぶ」ではなく「絞る」。
/// それなのに ⌘F はいつも素の検索で開き、毎回 1 手かけて漏斗を入れ直していた。
/// 覚えるのは**本人が押した意図**であって、ペインが漏斗を使えるかどうかとは別。
final class SearchFilterMemoryTests: XCTestCase {
    private var saved: Bool = false

    override func setUp() {
        super.setUp()
        saved = AppSettings.searchFilterOn
    }

    override func tearDown() {
        AppSettings.searchFilterOn = saved
        super.tearDown()
    }

    func testDefaultsToOffSoNothingChangesForSomeoneWhoNeverFilters() {
        UserDefaults.standard.removeObject(forKey: "MrEditor.searchFilterOn")
        XCTAssertFalse(AppSettings.searchFilterOn)
    }

    func testRemembersWhatWasPressed() {
        AppSettings.searchFilterOn = true
        XCTAssertTrue(AppSettings.searchFilterOn)
        AppSettings.searchFilterOn = false
        XCTAssertFalse(AppSettings.searchFilterOn)
    }

    /// 漏斗を使えないペインに移ったときは、**バーが降ろすだけ**で意図は残る。
    /// ここが消えると、構造化 → 素のテキストと往復するたびに入れ直しになる。
    func testMovingToAPaneThatCannotFilterDoesNotForgetTheIntent() {
        AppSettings.searchFilterOn = true

        let bar = SearchBarView()
        var userToggles: [Bool] = []
        var forcedOff = 0
        bar.onFilterToggle = { userToggles.append($0) }
        bar.onFilterUnavailable = { forcedOff += 1 }

        bar.setFilterAvailable(true)
        bar.setFilterOn(true)
        bar.setFilterAvailable(false)   // 構造化ペインへ移った

        XCTAssertEqual(forcedOff, 1, "使えなくなったことは伝わる")
        XCTAssertTrue(userToggles.isEmpty, "本人が押したことにしてはいけない")
        XCTAssertTrue(AppSettings.searchFilterOn, "意図は残る")
    }

    /// 漏斗が隠れている間は立てられない（見えないボタンの状態だけ on になると、
    /// 使えるペインへ戻った瞬間に理由の分からない絞り込みが起きる）。
    func testCannotRaiseTheFunnelWhileItIsHidden() {
        let bar = SearchBarView()
        bar.setFilterAvailable(false)
        bar.setFilterOn(true)
        bar.setFilterAvailable(true)
        var reported: [Bool] = []
        bar.onFilterToggle = { reported.append($0) }
        bar.setFilterOn(true)
        XCTAssertTrue(reported.isEmpty, "外から立てるのは通知を伴わない")
    }
}
