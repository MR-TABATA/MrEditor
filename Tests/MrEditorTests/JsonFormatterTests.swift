import XCTest
@testable import MrEditor

/// `JsonFormatter.pretty` の字下げ整形・キー順保持・空コンテナ・不正入力・文字列内保持を検証する。
final class JsonFormatterTests: XCTestCase {

    func testCompactObjectIndented() {
        let out = JsonFormatter.pretty(#"{"a":1,"b":2}"#)
        XCTAssertEqual(out, "{\n  \"a\": 1,\n  \"b\": 2\n}")
    }

    func testKeyOrderPreserved() {
        // JSONSerialization はキー順を保たないが、こちらは出現順を保つ。
        let out = JsonFormatter.pretty(#"{"z":1,"a":2,"m":3}"#)
        XCTAssertEqual(out, "{\n  \"z\": 1,\n  \"a\": 2,\n  \"m\": 3\n}")
    }

    func testNestedAndArray() {
        let out = JsonFormatter.pretty(#"{"a":[1,2],"b":{"c":3}}"#)
        XCTAssertEqual(out, """
        {
          "a": [
            1,
            2
          ],
          "b": {
            "c": 3
          }
        }
        """)
    }

    func testEmptyContainersStayInline() {
        XCTAssertEqual(JsonFormatter.pretty(#"{"a":{},"b":[]}"#),
                       "{\n  \"a\": {},\n  \"b\": []\n}")
    }

    func testStringContentsPreserved() {
        // 文字列内のコロン・カンマ・波括弧・エスケープはそのまま。
        let out = JsonFormatter.pretty(#"{"k":"a:b, {c}\n\"q\""}"#)
        XCTAssertEqual(out, "{\n  \"k\": \"a:b, {c}\\n\\\"q\\\"\"\n}")
    }

    func testTopLevelScalarAndArray() {
        XCTAssertEqual(JsonFormatter.pretty("42"), "42")
        XCTAssertEqual(JsonFormatter.pretty("[1,2]"), "[\n  1,\n  2\n]")
    }

    func testAlreadyPrettyIsIdempotent() {
        let pretty = "{\n  \"a\": 1,\n  \"b\": [\n    2\n  ]\n}"
        XCTAssertEqual(JsonFormatter.pretty(pretty), pretty)
    }

    func testTrailingCommaTolerated() {
        // Foundation は末尾カンマを許容。整形時に落として素直に出す。
        XCTAssertEqual(JsonFormatter.pretty(#"{"a":1,}"#), "{\n  \"a\": 1\n}")
    }

    func testInvalidReturnsNil() {
        XCTAssertNil(JsonFormatter.pretty("not json"))
        XCTAssertNil(JsonFormatter.pretty(#"{"a":1}{"b":2}"#))    // 複数トップレベル = NDJSON の担当
        XCTAssertNil(JsonFormatter.pretty(""))
    }
}
