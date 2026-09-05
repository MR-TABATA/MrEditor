import XCTest
@testable import MrEditorCore

/// 検索バーの件数表示。**「いつ終わったか」が読めることを固定する。**
///
/// 2026-09-05 に本人から「いつが終わりかわからない」と言われて見つけた。
/// 「検索中… N%」を `total == 0` のときだけ出していたので、1 件でも当たった瞬間に
/// 「13 件」へ切り替わり、**まだ走査中なのに確定したように見えていた**。1GB の
/// ファイルでは件数がそのあとも増え続けるので、これは嘘に近い。
final class SearchCountTextTests: XCTestCase {

    private func text(current: Int = 0, total: Int, searching: Bool, progress: Int = 0,
                      invalid: Bool = false, capped: Bool = false) -> String {
        SearchBarView.countText(query: "あ", current: current, total: total,
                                searching: searching, progress: progress,
                                invalid: invalid, capped: capped)
    }

    /// 走査中は、件数だけを出して終わったように見せない。
    func testSearchingShowsProgressAlongsideCount() {
        let t = text(total: 13, searching: true, progress: 42)
        XCTAssertTrue(t.contains("13"), "見つかった件数は出す: \(t)")
        XCTAssertTrue(t.contains("42"), "進み具合も出す: \(t)")
    }

    /// 終わったら進み具合は消える。**消えたことが終わりの合図。**
    func testFinishedDropsProgress() {
        let t = text(total: 13, searching: false)
        XCTAssertTrue(t.contains("13"))
        XCTAssertFalse(t.contains("%"), "終わったら % は出さない: \(t)")
    }

    /// 同じ件数でも、走査中と終了後で文言が変わること（変わらなければ区別できない）。
    func testSearchingAndFinishedDiffer() {
        XCTAssertNotEqual(text(total: 13, searching: true, progress: 90),
                          text(total: 13, searching: false))
    }

    /// 走査中は「何件目か」を出さない。バーの幅が足りず末尾から切れるため
    /// （実機で「1,365,193 件中 2 件目（検索中 0%」と閉じ括弧ごと消えた）。
    /// 走っている最中に要るのは件数と進み具合で、何件目かは動かしてから読める。
    ///
    /// **文字数では判じない。** 最初そう書いたら、日本語では短いのに英語では長くなって
    /// CI（英語で走る）だけ落ちた。言語に関係なく言えるのは「位置を出さない」ほう。
    func testSearchingDropsThePosition() {
        let atThird = text(current: 3, total: 1_365_193, searching: true, progress: 55)
        let atStart = text(current: 0, total: 1_365_193, searching: true, progress: 55)
        XCTAssertEqual(atThird, atStart, "走査中は何件目かで文言が変わらない: \(atThird)")
        XCTAssertTrue(atThird.contains("55"), "進み具合は出す: \(atThird)")

        let done = text(current: 3, total: 1_365_193, searching: false)
        XCTAssertNotEqual(done, text(current: 0, total: 1_365_193, searching: false),
                          "終わったら何件目かを出す: \(done)")
    }

    /// まだ 1 件も当たっていないあいだは従来どおり「検索中… N%」だけ。
    /// 「0 件」と断言しない（走査が終わっていないので、まだ分からない）。
    func testNoMatchYet() {
        let t = text(total: 0, searching: true, progress: 7)
        XCTAssertTrue(t.contains("7"), "\(t)")
        XCTAssertNotEqual(t, text(total: 0, searching: false), "終わったときと同じ文言にしない: \(t)")
    }

    /// 終わって 1 件も無ければ「該当なし」。進み具合は出さない。
    func testFinishedWithNoMatch() {
        let t = text(total: 0, searching: false)
        XCTAssertFalse(t.contains("%"), "\(t)")
        XCTAssertFalse(t.isEmpty)
    }

    /// 上限で打ち切ったときは「N 件以上」。走査中ならそこにも進み具合が付く。
    func testCappedKeepsItsOwnWording() {
        let capped = text(total: 1_000_000, searching: false, capped: true)
        let plain = text(total: 1_000_000, searching: false, capped: false)
        XCTAssertNotEqual(capped, plain, "打ち切りを断言と同じ文言にしない")
        XCTAssertTrue(text(total: 1_000_000, searching: true, progress: 30, capped: true).contains("30"))
    }

    /// 語が空なら何も出さない。式が壊れていればその旨だけ（進み具合は付けない）。
    func testEmptyAndInvalid() {
        XCTAssertEqual(SearchBarView.countText(query: "", current: 0, total: 0, searching: true,
                                               progress: 50, invalid: false, capped: false), "")
        let bad = text(total: 0, searching: true, progress: 50, invalid: true)
        XCTAssertFalse(bad.contains("50"), "\(bad)")
    }
}
