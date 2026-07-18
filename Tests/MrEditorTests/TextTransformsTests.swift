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
    func testEmptyString() {
        for t in TextTransform.allCases { XCTAssertEqual(t.apply(""), "") }
    }
}
