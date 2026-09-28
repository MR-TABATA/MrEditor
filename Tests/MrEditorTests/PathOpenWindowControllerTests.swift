import XCTest
@testable import MrEditorCore

/// パス解決（引用符除去・`~`展開・存在確認）の純粋な部分を検証する。
final class PathOpenWindowControllerTests: XCTestCase {

    private var tempFile: URL!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempFile = tempDir.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: tempFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResolvesPlainExistingFile() {
        XCTAssertEqual(PathOpenWindowController.resolve(tempFile.path), tempFile)
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(PathOpenWindowController.resolve("  \(tempFile.path)  "), tempFile)
    }

    func testStripsOneSurroundingPairOfStraightQuotes() {
        XCTAssertEqual(PathOpenWindowController.resolve("\"\(tempFile.path)\""), tempFile)
    }

    func testStripsOneSurroundingPairOfSingleQuotes() {
        XCTAssertEqual(PathOpenWindowController.resolve("'\(tempFile.path)'"), tempFile)
    }

    func testDoesNotStripUnbalancedQuote() {
        XCTAssertNil(PathOpenWindowController.resolve("\"\(tempFile.path)"))
    }

    func testExpandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(PathOpenWindowController.resolve("~"), home)
    }

    func testResolvesExistingDirectory() {
        // フォルダは `URL(fileURLWithPath:)` が末尾に `/` を付けるので、パス文字列で比べる。
        XCTAssertEqual(PathOpenWindowController.resolve(tempDir.path)?.path, tempDir.path)
    }

    func testReturnsNilForMissingPath() {
        XCTAssertNil(PathOpenWindowController.resolve(tempDir.appendingPathComponent("does-not-exist").path))
    }

    func testReturnsNilForEmptyInput() {
        XCTAssertNil(PathOpenWindowController.resolve("   "))
    }
}
