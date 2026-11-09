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

    // MARK: - NSString 版（打鍵のたびに呼ばれる。String 版と同じ結果を、先頭行だけを読んで作る）

    /// 同じ入力で、String 版と NSString 版が一致する（空・空白・改行・CRLF・全角空白・絵文字・長い行・長い本文）。
    func testTheNSStringPathAgreesWithTheStringPath() {
        let samples = [
            "", "   ", "\n\n", "title", "  title  \nbody", "\n\n  \n title\nbody", "a\r\nb", "\r\n\r\nfirst\r\nsecond",
            "\u{3000}\u{3000}全角の空白で始まる\n次の行", "a \t\t b    c", "x\u{2028}y", "x\u{85}y", "\u{A0}\u{A0}nbsp then text",
            "👨‍👩‍👧 family\nnext", String(repeating: "あ", count: 80), String(repeating: "z", count: UntitledTitle.scanLimit * 3),
            "head\n" + String(repeating: "y", count: 200_000),
            String(repeating: "\n", count: UntitledTitle.scanLimit + 5) + "after the scan range",
        ]
        for text in samples {
            XCTAssertEqual(UntitledTitle.make(from: text as NSString), UntitledTitle.make(from: text),
                           "一致しない: \(text.prefix(30).debugDescription)")
        }
    }

    /// 先頭 scanLimit のあとにしか中身が無い本文は、タイトルを作らない（それ以上は読まない）。
    func testNothingIsReadPastTheScanRange() {
        let text = String(repeating: " ", count: UntitledTitle.scanLimit) + "hidden"
        XCTAssertNil(UntitledTitle.make(from: text as NSString))
    }

    /// 本文の長さによらず、先頭行だけを読む（巨大な本文でも、結果が変わらず、速い）。
    func testAHugeNSStringIsCheap() {
        let huge = ("head\n" + String(repeating: "y\n", count: 3_000_000)) as NSString
        measure { XCTAssertEqual(UntitledTitle.make(from: huge), "head") }
    }

    // MARK: - 表示名の決め方（サイドバー・タイトルバー）

    func testDisplayNamePrefersTheFileNameThenTheFirstLineThenUntitled() {
        XCTAssertEqual(UntitledTitle.displayName(fileName: "a.txt", autoTitle: "first line", untitled: "Untitled"), "a.txt")
        XCTAssertEqual(UntitledTitle.displayName(fileName: nil, autoTitle: "first line", untitled: "Untitled"), "first line")
        XCTAssertEqual(UntitledTitle.displayName(fileName: nil, autoTitle: nil, untitled: "Untitled"), "Untitled")
    }

    func testAFirstLineLongerThanTheScanRangeStillGivesAShortTitle() {
        let huge = String(repeating: "z", count: UntitledTitle.scanLimit * 3)
        XCTAssertEqual(UntitledTitle.make(from: huge)?.count, UntitledTitle.maxLength + 1)   // 24 文字 + 「…」
    }
}
