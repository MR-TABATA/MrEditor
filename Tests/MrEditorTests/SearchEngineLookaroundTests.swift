import XCTest
@testable import MrEditor

/// 正規表現のルックアラウンド（先読み・後読み）が検索エンジンで機能することの回帰テスト。
/// エンジンは `NSRegularExpression`（ICU）をそのまま通すため、ICU 側の退行を将来検知する保険。
final class SearchEngineLookaroundTests: XCTestCase {
    /// 与えた本文をファイルに落とし、regex パターンで一致した行番号（0 始まり）を返す。
    private func matchingLines(_ content: String, pattern: String) -> [Int] {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("searchla-\(UUID().uuidString).log")
        try? content.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let buffer = FileBuffer(url: url) else { XCTFail("buffer"); return [] }
        let engine = SearchEngine(buffer: buffer, encoding: .utf8)
        let rx = try! NSRegularExpression(pattern: pattern)
        let done = expectation(description: "search")
        var lines: [Int] = []
        engine.search(.regex(rx), progress: { _, _ in }, completion: { res in
            lines = res.lines
            done.fulfill()
        })
        wait(for: [done], timeout: 5)
        return lines
    }

    func testPositiveLookahead() {
        let text = "foobar\nfoobaz\nfooqux\n"
        // 直後に "bar" が続く "foo" を含む行だけ。
        XCTAssertEqual(matchingLines(text, pattern: "foo(?=bar)"), [0])
    }

    func testNegativeLookahead() {
        let text = "error: disk\nerror: ok\nwarn: disk\n"
        // "error" のうち直後が " ok" でないもの。
        XCTAssertEqual(matchingLines(text, pattern: "error(?!: ok)"), [0])
    }

    func testPositiveLookbehind() {
        let text = "id=42\nno match here\nkey=99\n"
        // "=" の直後の数字。
        XCTAssertEqual(matchingLines(text, pattern: "(?<==)\\d+"), [0, 2])
    }

    func testNegativeLookbehind() {
        let text = "x123\n 456\nabc\n"
        // 直前が数字でない数字列。
        XCTAssertEqual(matchingLines(text, pattern: "(?<!\\d)\\d+"), [0, 1])
    }

    func testVariableLengthLookbehind() {
        let text = "user@example.com\nname@other.org\n"
        // "@example" の直前の語（可変長後読み込みの一致）。
        XCTAssertEqual(matchingLines(text, pattern: "\\w+(?=@example)"), [0])
    }
}
