import XCTest
@testable import MrEditor

/// `JsonQuery` の path / インデックス / 投影 / フィルタ / 比較 / エラーを検証する。
final class JsonQueryTests: XCTestCase {

    private func eval(_ expr: String, _ json: String) throws -> Any {
        let root = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!, options: [.fragmentsAllowed])
        return try JsonQuery.evaluate(expr, on: root)
    }

    func testIdentity() throws {
        let r = try eval("@", #"{"a":1}"#) as? [String: Any]
        XCTAssertEqual(r?["a"] as? Int, 1)
        let r2 = try eval("", #"{"a":1}"#) as? [String: Any]
        XCTAssertNotNil(r2)
    }

    func testDottedField() throws {
        XCTAssertEqual(try eval("a.b", #"{"a":{"b":42}}"#) as? Int, 42)
    }

    func testQuotedField() throws {
        XCTAssertEqual(try eval("\"a b\".c", #"{"a b":{"c":9}}"#) as? Int, 9)
    }

    func testIndexAndNegative() throws {
        XCTAssertEqual(try eval("a[0]", #"{"a":[10,20,30]}"#) as? Int, 10)
        XCTAssertEqual(try eval("a[-1]", #"{"a":[10,20,30]}"#) as? Int, 30)
        XCTAssertTrue(try eval("a[9]", #"{"a":[1]}"#) is NSNull)   // 範囲外は null
    }

    func testMissingFieldIsNull() throws {
        XCTAssertTrue(try eval("a.x", #"{"a":{"b":1}}"#) is NSNull)
    }

    func testArrayWildcardProjection() throws {
        let r = try eval("items[*].name", #"{"items":[{"name":"a"},{"name":"b"},{"x":1}]}"#) as? [Any]
        XCTAssertEqual(r?.compactMap { $0 as? String }, ["a", "b"])   // name の無い要素は落ちる
    }

    func testObjectWildcard() throws {
        let r = try eval("m.*", #"{"m":{"x":1,"y":2}}"#) as? [Any]
        XCTAssertEqual(r?.compactMap { $0 as? Int }.sorted(), [1, 2])
    }

    func testFilterEquals() throws {
        let json = #"{"u":[{"name":"a","age":30},{"name":"b","age":7}]}"#
        let r = try eval("u[?name == 'a']", json) as? [Any]
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual((r?.first as? [String: Any])?["age"] as? Int, 30)
    }

    func testFilterNumericCompareThenProject() throws {
        let json = #"{"u":[{"name":"a","age":30},{"name":"b","age":7},{"name":"c","age":50}]}"#
        let r = try eval("u[?age >= 30].name", json) as? [Any]
        XCTAssertEqual(r?.compactMap { $0 as? String }, ["a", "c"])
    }

    func testFilterNotEquals() throws {
        let json = #"{"u":[{"k":"x"},{"k":"y"}]}"#
        let r = try eval("u[?k != 'x']", json) as? [Any]
        XCTAssertEqual(r?.count, 1)
    }

    func testRunProducesPrettyText() throws {
        let out = try JsonQuery.run("a", onJSONText: #"{"a":{"b":1}}"#)
        XCTAssertEqual(out, "{\n  \"b\": 1\n}")
    }

    func testRunScalarText() throws {
        XCTAssertEqual(try JsonQuery.run("a.b", onJSONText: #"{"a":{"b":42}}"#), "42")
        XCTAssertEqual(try JsonQuery.run("a", onJSONText: #"{"a":"hi"}"#), "hi")
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try JsonQuery.run("a", onJSONText: "not json"))
    }

    func testSyntaxErrorThrows() {
        XCTAssertThrowsError(try eval("a[", #"{"a":[1]}"#))         // 未終端 [
        XCTAssertThrowsError(try eval("a[?age]", #"{"a":[]}"#))     // 比較子なし
    }
}
