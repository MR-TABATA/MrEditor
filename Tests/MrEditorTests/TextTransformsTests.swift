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

    func testEmptyString() {
        // 空入力でもクラッシュしない（ケース系は "" を返す）。
        XCTAssertEqual(TextTransform.uppercase.apply(""), "")
        XCTAssertEqual(TextTransform.base64Encode.apply(""), "")
    }
}
