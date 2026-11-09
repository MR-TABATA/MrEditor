import XCTest
@testable import MrEditorCore

/// 未保存の新規ドキュメントのタブ名（本文の先頭行）。要望 #133。
final class UntitledTitleTests: XCTestCase {
    func testEmptyAndBlankTextHaveNoTitle() {
        XCTAssertNil(UntitledTitle.make(from: ""))
        XCTAssertNil(UntitledTitle.make(from: "   \t  "))
        XCTAssertNil(UntitledTitle.make(from: "\n\n \n"))
    }

    func testUsesTheFirstLine() {
        XCTAssertEqual(UntitledTitle.make(from: "Meeting notes\nsecond line"), "Meeting notes")
    }

    func testSkipsLeadingBlankLines() {
        XCTAssertEqual(UntitledTitle.make(from: "\n\n   \n  TODO list\nmore"), "TODO list")
    }

    func testCollapsesRunsOfWhitespace() {
        XCTAssertEqual(UntitledTitle.make(from: "  a \t\t b    c  "), "a b c")
    }

    func testCRLFIsALineBreak() {
        XCTAssertEqual(UntitledTitle.make(from: "first\r\nsecond"), "first")
    }

    func testLongLineIsCutWithAnEllipsis() {
        let line = String(repeating: "x", count: UntitledTitle.maxLength + 10)
        XCTAssertEqual(UntitledTitle.make(from: line), String(repeating: "x", count: UntitledTitle.maxLength) + "…")
    }

    func testALineOfExactlyTheMaximumIsNotCut() {
        let line = String(repeating: "x", count: UntitledTitle.maxLength)
        XCTAssertEqual(UntitledTitle.make(from: line), line)
    }

    func testJapaneseCountsByCharacter() {
        let line = String(repeating: "あ", count: UntitledTitle.maxLength + 1)
        XCTAssertEqual(UntitledTitle.make(from: line), String(repeating: "あ", count: UntitledTitle.maxLength) + "…")
    }

    /// 結合文字・絵文字（複数のコードポイントで 1 文字）を、途中で切らない。
    func testDoesNotSplitACharacterMadeOfSeveralCodePoints() {
        let family = "👨‍👩‍👧"                                            // 1 文字（コードポイントは 5 つ）
        let line = String(repeating: family, count: UntitledTitle.maxLength + 1)
        let title = UntitledTitle.make(from: line)
        XCTAssertEqual(title, String(repeating: family, count: UntitledTitle.maxLength) + "…")
    }

    /// 巨大な貼り付けでも、先頭の範囲しか見ない（結果は先頭行から作られる）。
    func testOnlyTheStartOfAHugeTextIsScanned() {
        let huge = "head\n" + String(repeating: "y", count: 5_000_000)
        XCTAssertEqual(UntitledTitle.make(from: huge), "head")
    }

    func testAFirstLineLongerThanTheScanRangeStillGivesAShortTitle() {
        let huge = String(repeating: "z", count: UntitledTitle.scanLimit * 3)
        XCTAssertEqual(UntitledTitle.make(from: huge)?.count, UntitledTitle.maxLength + 1)   // 24 文字 + 「…」
    }
}
