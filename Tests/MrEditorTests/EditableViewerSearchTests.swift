import XCTest
import AppKit
@testable import MrEditorCore

/// 小ファイル編集ペインの検索・置換・行ジャンプ。
/// （8MB 未満は EditableViewer が担うが、当初 `supportsSearch` が false で
/// ⌘F がビープするだけだった。その回帰を止めるためのテスト。）
final class EditableViewerSearchTests: XCTestCase {
    private func viewer(_ text: String) -> EditableViewer {
        let v = EditableViewer()
        v.newDocument()
        v._testSetText(text)
        v._testSelect(NSRange(location: 0, length: 0))
        return v
    }

    // MARK: 検索できること

    func testEditablePaneSupportsSearch() {
        XCTAssertTrue(viewer("abc").supportsSearch)
    }

    /// 構造化表示中は読み取り専用の見た目なので検索バーを出さない（巨大ファイル側と同じ）。
    func testSearchUnavailableWhileStructured() {
        let v = viewer("a,b\n1,2\n")
        v.setStructuredMode(.csv)
        XCTAssertFalse(v.supportsSearch)
        v.setStructuredMode(nil)
        XCTAssertTrue(v.supportsSearch)
    }

    /// 一致行フィルタ（live grep）は編集ペインでも使える。
    /// 以前は大ファイル専用で、普通のサイズのファイルでは漏斗ボタンが常に灰色だった。
    func testEditablePaneHasFilter() {
        XCTAssertTrue(viewer("abc").supportsSearchFilter)
    }

    /// 構造化表示中は本文が既に差し替わっているのでフィルタは受けない。
    func testFilterUnavailableWhileStructured() {
        let v = viewer("a,b\n1,2\n")
        v.setStructuredMode(.csv)
        XCTAssertFalse(v.supportsSearchFilter)
        v.setStructuredMode(nil)
        XCTAssertTrue(v.supportsSearchFilter)
    }

    /// フィルタ ON で本文が一致行だけになり、OFF で元に戻ること。
    func testFilterShowsOnlyMatchingLinesAndRestores() {
        let v = viewer("alpha\nbravo\nalpha again\ncharlie\n")
        v.setSearchQuery("alpha")
        v.setFilterMode(true)
        XCTAssertEqual(v._testText, "alpha\nalpha again\n")

        v.setFilterMode(false)
        XCTAssertEqual(v._testText, "alpha\nbravo\nalpha again\ncharlie\n")
    }

    /// クエリを変えると絞り込みも追従すること（live grep）。
    func testFilterFollowsQueryChanges() {
        let v = viewer("alpha\nbravo\ncharlie\n")
        v.setSearchQuery("alpha")
        v.setFilterMode(true)
        XCTAssertEqual(v._testText, "alpha\n")

        v.setSearchQuery("bravo")
        XCTAssertEqual(v._testText, "bravo\n")
    }

    /// **フィルタ中でも保存・行数が見るのは元の本文**。
    /// ここを取り違えると「絞り込んだまま保存したら他の行が消えた」になる。
    func testFilterKeepsWholeTextForSaving() {
        let whole = "alpha\nbravo\ncharlie\n"
        let v = viewer(whole)
        v.setSearchQuery("alpha")
        v.setFilterMode(true)
        XCTAssertEqual(v._testText, "alpha\n")          // 見えているのは一致行だけ
        XCTAssertEqual(v.restorableText, whole)          // 論理本文は丸ごと残っている
    }

    /// フィルタ中は読み取り専用（誤って一致行だけを編集させない）。
    func testFilterIsReadOnly() {
        let v = viewer("alpha\nbravo\n")
        v.setSearchQuery("alpha")
        v.setFilterMode(true)
        XCTAssertFalse(v.canEdit)
        v.setFilterMode(false)
        XCTAssertTrue(v.canEdit)
    }

    // MARK: 一致の数え方

    func testLiteralSearchCountsMatchesCaseInsensitiveByDefault() {
        let v = viewer("timeout\nTIMEOUT\nTimeout\nother\n")
        v.setSearchQuery("timeout")
        XCTAssertEqual(v._testMatchCount, 3)

        v.setCaseSensitive(true)
        XCTAssertEqual(v._testMatchCount, 1)
    }

    func testEmptyQueryClearsMatches() {
        let v = viewer("aaa")
        v.setSearchQuery("a")
        XCTAssertEqual(v._testMatchCount, 3)
        v.setSearchQuery("")
        XCTAssertEqual(v._testMatchCount, 0)
    }

    /// 空白区切りは語ごとの出現を全部拾う（本文順に並ぶ）。
    func testMultipleTermsAreCollectedInDocumentOrder() {
        let v = viewer("alpha beta\n")
        v.setSearchQuery("beta alpha")
        XCTAssertEqual(v._testMatchCount, 2)
        v.findNext()
        XCTAssertEqual(v._testSelection, NSRange(location: 0, length: 5))   // alpha が先
    }

    /// 正規表現の ^ は行頭に当たる（全文を 1 本の文字列として照合しない）。
    func testRegexAnchorsMatchLines() {
        let v = viewer("foo\nbarfoo\nfoo\n")
        v.setRegexMode(true)
        v.setSearchQuery("^foo")
        XCTAssertEqual(v._testMatchCount, 2)
    }

    func testRegexLookaheadWorks() {
        let v = viewer("ERROR: a\nERROR: b\nINFO: c\n")
        v.setRegexMode(true)
        v.setSearchQuery("ERROR(?=: b)")
        XCTAssertEqual(v._testMatchCount, 1)
    }

    func testInvalidRegexIsReportedAndFindsNothing() {
        let v = viewer("abc")
        v.setRegexMode(true)
        v.setSearchQuery("[")
        XCTAssertTrue(v._testSearchInvalid)
        XCTAssertEqual(v._testMatchCount, 0)
    }

    /// 編集で本文が変われば一致位置も数え直す。
    func testMatchesRecomputedAfterTextChanges() {
        let v = viewer("hit\n")
        v.setSearchQuery("hit")
        XCTAssertEqual(v._testMatchCount, 1)
        v._testSetText("hit\nhit\nhit\n")
        XCTAssertEqual(v._testMatchCount, 3)
    }

    // MARK: 送り・戻し

    func testFindNextAdvancesAndWrapsAround() {
        let v = viewer("x\nx\n")   // 一致は 0 と 2
        v.setSearchQuery("x")
        XCTAssertEqual(v._testMatchCount, 2)

        v.findNext()
        XCTAssertEqual(v._testSelection, NSRange(location: 0, length: 1))
        XCTAssertEqual(v._testCurrentMatch, 1)

        v.findNext()
        XCTAssertEqual(v._testSelection, NSRange(location: 2, length: 1))
        XCTAssertEqual(v._testCurrentMatch, 2)

        v.findNext()   // 末尾の次は先頭へ回り込む
        XCTAssertEqual(v._testSelection, NSRange(location: 0, length: 1))
        XCTAssertEqual(v._testCurrentMatch, 1)
    }

    func testFindPrevGoesBackwardAndWrapsAround() {
        let v = viewer("x\nx\n")
        v.setSearchQuery("x")

        v.findPrev()   // キャレット 0 の手前は無い＝末尾へ回り込む
        XCTAssertEqual(v._testSelection, NSRange(location: 2, length: 1))

        v.findPrev()
        XCTAssertEqual(v._testSelection, NSRange(location: 0, length: 1))
    }

    // MARK: 置換

    func testReplaceCurrentReplacesSelectionThenMovesOn() {
        let v = viewer("cat cat")
        v.setSearchQuery("cat")
        v.findNext()                       // 1 つ目を選択
        v.replaceCurrent(with: "dog")
        XCTAssertEqual(v._testText, "dog cat")
        XCTAssertEqual(v._testSelection, NSRange(location: 4, length: 3))   // 次の一致が選ばれている
    }

    /// 選択が一致でなければ置換せず次を探すだけ（＝押し続けで送れる）。
    func testReplaceCurrentWithoutMatchSelectionOnlyMoves() {
        let v = viewer("cat cat")
        v.setSearchQuery("cat")
        v.replaceCurrent(with: "dog")
        XCTAssertEqual(v._testText, "cat cat")
        XCTAssertEqual(v._testSelection, NSRange(location: 0, length: 3))
    }

    func testReplaceAllReplacesEveryMatch() {
        let v = viewer("cat\ncat\ncat\n")
        v.setSearchQuery("cat")
        v.replaceAll(with: "dog")
        XCTAssertEqual(v._testText, "dog\ndog\ndog\n")
        XCTAssertEqual(v._testMatchCount, 0)
    }

    /// すべて置換は 1 アンドゥで元へ戻る。
    func testReplaceAllIsSingleUndo() {
        let v = viewer("cat cat cat")
        v.setSearchQuery("cat")
        v.replaceAll(with: "dog")
        XCTAssertEqual(v._testText, "dog dog dog")
        v._testUndo()
        XCTAssertEqual(v._testText, "cat cat cat")
    }

    /// 正規表現の $1 展開が置換に効く。
    func testReplaceAllExpandsRegexGroups() {
        let v = viewer("key=value\nname=mr\n")
        v.setRegexMode(true)
        v.setSearchQuery("^(\\w+)=(\\w+)$")
        v.replaceAll(with: "$2:$1")
        XCTAssertEqual(v._testText, "value:key\nmr:name\n")
    }

    /// ケース維持オンなら一致した綴りの書式を置換文字列へ移す。
    func testReplaceAllPreservesCase() {
        let v = viewer("timeout TIMEOUT Timeout")
        v.setSearchQuery("timeout")
        v.setPreserveCase(true)
        v.replaceAll(with: "delay")
        XCTAssertEqual(v._testText, "delay DELAY Delay")
    }

    /// 読み取り専用の整形中は置換しない（本文を壊さない）。
    func testReplaceRefusedWhileStructured() {
        let v = viewer("a,b\n1,2\n")
        v.setSearchQuery("1")
        v.setStructuredMode(.csv)
        v.replaceAll(with: "9")
        v.setStructuredMode(nil)
        XCTAssertEqual(v._testText, "a,b\n1,2\n")
    }

    // MARK: 行ジャンプ（⌘L）

    func testGoToLineMovesCaretToLineHead() {
        let v = viewer("one\ntwo\nthree\n")
        v.goToLine(3)
        XCTAssertEqual(v._testSelection, NSRange(location: 8, length: 0))   // "one\ntwo\n" の後ろ
    }

    /// 行数を超える指定は末尾行へ丸める（beep もクラッシュもしない）。
    func testGoToLineClampsBeyondEnd() {
        let v = viewer("one\ntwo\n")
        v.goToLine(999)
        XCTAssertEqual(v._testSelection.location, 8)
    }
}

// MARK: - 件数の上限（丸めた数を断言しない）

extension EditableViewerSearchTests {

    /// 上限に達していなければ「打ち切った」印は立たない＝件数はそのまま断言してよい。
    func testMatchCountIsNotFlaggedCappedWhenUnderLimit() {
        let v = EditableViewer()
        v.newDocument()
        v._testSetText("hit hit hit")
        v.setSearchQuery("hit")
        XCTAssertEqual(v._testMatchCount, 3)
        XCTAssertFalse(v._testMatchesCapped)
    }

    /// 上限で打ち切ったら印を立てる（検索バーは「N 件以上」と出す）。
    /// 上限ぶんの一致を作るので本文は大きめ。同期で数える設計なのでここも実測になる。
    func testMatchCountFlagsCappedAtLimit() {
        let cap = EditableViewer._testMatchCap
        let v = EditableViewer()
        v.newDocument()
        v._testSetText(String(repeating: "a", count: cap + 100))
        v.setSearchQuery("a")
        XCTAssertEqual(v._testMatchCount, cap)      // 数え切らずに打ち切る
        XCTAssertTrue(v._testMatchesCapped)         // ＝総数ではなく下限
    }

    /// 打ち切りの文言が両言語にあり、キー名がそのまま出ていない。
    func testCappedCountStringsExist() {
        for key in ["search.foundCapped", "search.countCapped"] {
            XCTAssertNotEqual(L(key), key, key)
            XCTAssertFalse(L(key).isEmpty, key)
        }
    }
}

// MARK: - 行を指定して絞り込む（分析＝時間分布からの受け皿）

/// `showOnlyLines` は**検索とは無関係に**行を選ぶ。時間分布で時間帯をドラッグしたとき、
/// その時間帯に入る行だけを本文に残すために使う。
extension EditableViewerSearchTests {

    private func filtered(_ text: String, lines: [Int]) -> EditableViewer {
        let v = EditableViewer()
        v.newDocument()
        v._testSetText(text)
        v.showOnlyLines(lines)
        return v
    }

    func testShowOnlyLinesKeepsExactlyThoseLines() {
        let v = filtered("a\nb\nc\nd\n", lines: [1, 3])
        XCTAssertEqual(v.filterMatchLines ?? [], [1, 3])
    }

    /// 本文には選んだ行だけが残る（**検索していない**ので一致の色付けも起きない）。
    func testShowOnlyLinesReplacesTheVisibleText() {
        let v = filtered("a\nb\nc\n", lines: [2])
        XCTAssertEqual(v._testText, "c\n")
        XCTAssertEqual(v._testMatchCount, 0)
    }

    /// 空配列は解除（元の本文に戻る）。
    func testEmptyLinesClearsTheFilter() {
        let v = filtered("a\nb\nc\n", lines: [1])
        v.showOnlyLines([])
        XCTAssertNil(v.filterMatchLines)
    }
}
