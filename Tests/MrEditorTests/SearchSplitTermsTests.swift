import XCTest
@testable import MrEditorCore

/// 検索欄の文字列 → 語。空白だけの入力（半角スペースを探したい）が「語ゼロ個」になって
/// 何もヒットしなかった不具合の固定。
final class SearchSplitTermsTests: XCTestCase {

    func testSplitsOnWhitespace() {
        XCTAssertEqual(SearchMode.splitTerms("foo  bar\tbaz"), ["foo", "bar", "baz"])
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(SearchMode.splitTerms(""), [])
    }

    func testWhitespaceOnlyIsOneTerm() {
        XCTAssertEqual(SearchMode.splitTerms(" "), [" "])
        XCTAssertEqual(SearchMode.splitTerms("  "), ["  "])
    }

    func testSingleSpaceMatchesLineWithSpace() {
        let m = LineMatcher(mode: .terms(SearchMode.splitTerms(" ")), caseSensitive: false, encoding: .utf8)
        XCTAssertFalse(m.isEmpty)
        let hit = [UInt8]("a b".utf8), miss = [UInt8]("ab".utf8)
        XCTAssertTrue(hit.withUnsafeBufferPointer { m.matches($0) })
        XCTAssertFalse(miss.withUnsafeBufferPointer { m.matches($0) })
    }
}
