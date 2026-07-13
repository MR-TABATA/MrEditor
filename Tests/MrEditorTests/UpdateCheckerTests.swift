import XCTest
@testable import MrEditor

/// 更新チェックの中核（バージョン比較・GitHub JSON の解析）を検証する。
/// ネットワークには触れない。
final class UpdateCheckerTests: XCTestCase {

    // MARK: - バージョン比較

    func testComponentsStripsTagPrefix() {
        XCTAssertEqual(UpdateChecker.components("v1.2"), [1, 2])
        XCTAssertEqual(UpdateChecker.components("1.2.3"), [1, 2, 3])
        XCTAssertEqual(UpdateChecker.components("v0.7"), [0, 7])
    }

    /// 1.0 は 0.7 より新しい。文字列比較だと "1.0" < "0.7" にはならないが
    /// "0.10" < "0.7" になってしまうため、数値で比べる必要がある。
    func testNewerAcrossMajorBump() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.7"))
        XCTAssertFalse(UpdateChecker.isNewer("0.7", than: "1.0"))
    }

    /// 二桁のマイナーが一桁より新しいと判定される（文字列比較のワナ）。
    func testNewerWithTwoDigitMinor() {
        XCTAssertTrue(UpdateChecker.isNewer("0.10", than: "0.7"))
        XCTAssertFalse(UpdateChecker.isNewer("0.7", than: "0.10"))
    }

    /// 桁数が違っても比較できる。同一版は「新しくない」。
    func testNewerWithDifferentDepthAndEquality() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.7", than: "0.7"))
    }

    // MARK: - GitHub の JSON 解析

    func testParsePicksTagPageAndDmg() throws {
        let json = """
        {
          "tag_name": "v1.0",
          "html_url": "https://github.com/MR-TABATA/MrEditor/releases/tag/v1.0",
          "assets": [
            {"browser_download_url": "https://example.com/notes.txt"},
            {"browser_download_url": "https://example.com/MrEditor-1.0.dmg"}
          ]
        }
        """.data(using: .utf8)!

        let r = try XCTUnwrap(UpdateChecker.parse(json))
        XCTAssertEqual(r.version, "1.0")                       // "v" は落ちる
        XCTAssertEqual(r.dmgURL?.lastPathComponent, "MrEditor-1.0.dmg")
        XCTAssertEqual(r.pageURL.lastPathComponent, "v1.0")
    }

    /// dmg が添付されていないリリースでも、ページを開けるので成功扱い。
    func testParseWithoutDmgStillSucceeds() throws {
        let json = """
        {"tag_name": "v1.0",
         "html_url": "https://github.com/MR-TABATA/MrEditor/releases/tag/v1.0",
         "assets": []}
        """.data(using: .utf8)!
        let r = try XCTUnwrap(UpdateChecker.parse(json))
        XCTAssertNil(r.dmgURL)
        XCTAssertEqual(r.version, "1.0")
    }

    /// 壊れた応答・数字を含まないタグでは nil（＝黙って失敗させる）。
    func testParseRejectsGarbage() {
        XCTAssertNil(UpdateChecker.parse(Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parse(Data(#"{"tag_name":"latest","html_url":"https://x.test/"}"#.utf8)))
        XCTAssertNil(UpdateChecker.parse(Data(#"{"html_url":"https://x.test/"}"#.utf8)))
    }

    /// **桁数が変わるリリース**。1.0.3 の利用者に 1.1 が「新しい」と伝わらなければ、
    /// 更新通知は死ぬ（文字列比較だと "1.1" < "1.0.3" になりかねない）。
    func testVersionComparisonAcrossDigitCounts() {
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0.3"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.1", than: "1.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.1", than: "1.0.3"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.3", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1.1"))
    }
}
