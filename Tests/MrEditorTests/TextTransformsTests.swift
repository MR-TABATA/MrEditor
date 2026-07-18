import XCTest
@testable import MrEditor

final class TextTransformsTests: XCTestCase {
    func testUppercase() {
        XCTAssertEqual(TextTransform.uppercase.apply("Hello, World"), "HELLO, WORLD")
    }
    func testLowercase() {
        XCTAssertEqual(TextTransform.lowercase.apply("Hello, WORLD"), "hello, world")
    }
    func testTitlecase() {
        XCTAssertEqual(TextTransform.titlecase.apply("hello world foo"), "Hello World Foo")
    }
    func testTogglecaseSwapsEachLetter() {
        XCTAssertEqual(TextTransform.togglecase.apply("Hello, World!"), "hELLO, wORLD!")
    }
    func testNonLatinPassesThrough() {
        // 日本語など大小の概念がない文字はそのまま（変換で壊さない）。
        XCTAssertEqual(TextTransform.uppercase.apply("こんにちはabc"), "こんにちはABC")
        XCTAssertEqual(TextTransform.togglecase.apply("あA1z"), "あa1Z")
    }

    // MARK: エンコード／デコード

    func testUrlEncodeReservedAndSpace() {
        XCTAssertEqual(TextTransform.urlEncode.apply("a b&c=?/"), "a%20b%26c%3D%3F%2F")
    }
    func testUrlEncodeMultibyte() {
        XCTAssertEqual(TextTransform.urlEncode.apply("あ"), "%E3%81%82")   // UTF-8 3 バイト
    }
    func testUrlRoundTrip() {
        let s = "https://例え.test/path?q=a b&x=1"
        let encoded = try! XCTUnwrap(TextTransform.urlEncode.apply(s))
        XCTAssertEqual(TextTransform.urlDecode.apply(encoded), s)
    }
    func testBase64RoundTripIncludingMultibyte() {
        XCTAssertEqual(TextTransform.base64Encode.apply("hello"), "aGVsbG8=")
        XCTAssertEqual(TextTransform.base64Decode.apply("aGVsbG8="), "hello")
        let s = "日本語 mixed 🚀"
        let enc = try! XCTUnwrap(TextTransform.base64Encode.apply(s))
        XCTAssertEqual(TextTransform.base64Decode.apply(enc), s)
    }
    func testBase64DecodeIgnoresWrappingNewlines() {
        XCTAssertEqual(TextTransform.base64Decode.apply("aGVs\nbG8="), "hello")
    }
    func testBase64DecodeInvalidReturnsNil() {
        XCTAssertNil(TextTransform.base64Decode.apply("hello"))          // 4 の倍数でない
        XCTAssertNil(TextTransform.base64Decode.apply("////"))          // 有効 Base64 だが UTF-8 でない
    }

    // MARK: HTML エンティティ

    func testHtmlEncodeEscapesFive() {
        XCTAssertEqual(TextTransform.htmlEncode.apply("<a href=\"x\">Tom & 'Jerry'</a>"),
                       "&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;")
    }
    func testHtmlDecodeNamedNumericAndHex() {
        XCTAssertEqual(TextTransform.htmlDecode.apply("&lt;p&gt;A&amp;B &#169; &#x1F600;"),
                       "<p>A&B © 😀")
    }
    func testHtmlDecodeIsSinglePassNotRecursive() {
        // "&amp;lt;" は「&lt;」に一度だけ復号し、さらに "<" まで進めない。
        XCTAssertEqual(TextTransform.htmlDecode.apply("&amp;lt;"), "&lt;")
    }
    func testHtmlDecodeLeavesUnknownEntity() {
        XCTAssertEqual(TextTransform.htmlDecode.apply("&bogus; &amp;"), "&bogus; &")
    }
    func testHtmlRoundTrip() {
        let s = "if (a < b && c > d) x=\"1\";"
        let enc = try! XCTUnwrap(TextTransform.htmlEncode.apply(s))
        XCTAssertEqual(TextTransform.htmlDecode.apply(enc), s)
    }

    // MARK: 行操作

    func testSortAscendingAndDescending() {
        XCTAssertEqual(TextTransform.sortAscending.apply("banana\napple\ncherry"), "apple\nbanana\ncherry")
        XCTAssertEqual(TextTransform.sortDescending.apply("banana\napple\ncherry"), "cherry\nbanana\napple")
    }
    func testSortPreservesTrailingNewline() {
        XCTAssertEqual(TextTransform.sortAscending.apply("b\na\n"), "a\nb\n")   // 末尾改行を保ち空行を先頭に出さない
    }
    func testUniqueLinesKeepsFirstOccurrenceOrder() {
        XCTAssertEqual(TextTransform.uniqueLines.apply("b\na\nb\nc\na"), "b\na\nc")
    }
    func testReverseLines() {
        XCTAssertEqual(TextTransform.reverseLines.apply("1\n2\n3"), "3\n2\n1")
        XCTAssertEqual(TextTransform.reverseLines.apply("1\n2\n3\n"), "3\n2\n1\n")
    }
    func testNumberLines() {
        XCTAssertEqual(TextTransform.numberLines.apply("foo\nbar\nbaz"), "1\tfoo\n2\tbar\n3\tbaz")
    }

    func testEmptyString() {
        // 空入力でもクラッシュしない（ケース系は "" を返す）。
        XCTAssertEqual(TextTransform.uppercase.apply(""), "")
        XCTAssertEqual(TextTransform.base64Encode.apply(""), "")
        XCTAssertEqual(TextTransform.sortAscending.apply(""), "")
        XCTAssertEqual(TextTransform.numberLines.apply(""), "1\t")   // 空1行に連番
    }
}
