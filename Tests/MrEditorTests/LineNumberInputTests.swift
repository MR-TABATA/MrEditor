import XCTest
@testable import MrEditor

/// 行ジャンプ欄の入力パース。
/// 日本語入力が有効なまま数字を打つと全角で入り、変換候補にはカンマ付きも出る。
/// どちらも「跳べない」ではなく「跳べる」が正。
final class LineNumberInputTests: XCTestCase {

    func testHalfwidthDigits() {
        XCTAssertEqual(LineNumberInput.parse("86420337"), 86_420_337)
        XCTAssertEqual(LineNumberInput.parse("1"), 1)
    }

    /// IME を通した全角。これが nil を返していたのが元のバグ。
    func testFullwidthDigits() {
        XCTAssertEqual(LineNumberInput.parse("８６４２０３３７"), 86_420_337)
    }

    /// 変換候補に出る桁区切り。半角カンマも全角カンマも受ける。
    func testCommaSeparated() {
        XCTAssertEqual(LineNumberInput.parse("86,420,337"), 86_420_337)
        XCTAssertEqual(LineNumberInput.parse("８６，４２０，３３７"), 86_420_337)
    }

    func testSurroundingWhitespace() {
        XCTAssertEqual(LineNumberInput.parse("  42\n"), 42)
    }

    /// 数字以外が混じったものを勝手に読み替えない（"12abc" を 12 にしない）。
    func testRejectsNonNumeric() {
        XCTAssertNil(LineNumberInput.parse(""))
        XCTAssertNil(LineNumberInput.parse("   "))
        XCTAssertNil(LineNumberInput.parse("12abc"))
        XCTAssertNil(LineNumberInput.parse("八六四二〇三三七"))
        XCTAssertNil(LineNumberInput.parse("-5"))
        XCTAssertNil(LineNumberInput.parse("0"))
    }
}
