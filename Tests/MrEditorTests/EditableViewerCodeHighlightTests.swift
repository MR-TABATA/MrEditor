import XCTest
import AppKit
@testable import MrEditorCore

/// コード言語のハイライトが拡張子で切り替わることの配線確認。
/// 役割ごとの範囲判定そのものは `CodeSyntaxTests` が受け持つ。
final class EditableViewerCodeHighlightTests: XCTestCase {
    private func open(_ text: String, ext: String) throws -> (EditableViewer, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-code-\(UUID().uuidString).\(ext)")
        try text.data(using: .utf8)!.write(to: url)
        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        return (v, url)
    }

    func testPythonFileDetectedAndKeywordColored() throws {
        let (v, url) = try open("def f():\n    return 1", ext: "py")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(v._testCodeLanguage, .python)
        XCTAssertFalse(v._testIsMarkdownFile)
        XCTAssertNotNil(v._testMarkdownColor(at: 0))   // "def" が塗られている
    }

    func testUnknownExtensionSkipsHighlighting() throws {
        let (v, url) = try open("def f(): return 1", ext: "xyz")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(v._testCodeLanguage)
        XCTAssertNil(v._testMarkdownColor(at: 0))
    }

    func testSwitchingLanguageOnReopenRefreshesHighlight() throws {
        // .py で開いたときの色付けが、拡張子違いのファイルを開き直したときに残らないこと。
        let (v, pyURL) = try open("import os", ext: "py")
        defer { try? FileManager.default.removeItem(at: pyURL) }
        XCTAssertNotNil(v._testMarkdownColor(at: 0))

        let cssURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-code-\(UUID().uuidString).css")
        defer { try? FileManager.default.removeItem(at: cssURL) }
        try "plain text, no css keywords here".data(using: .utf8)!.write(to: cssURL)
        XCTAssertTrue(v.open(url: cssURL))
        XCTAssertEqual(v._testCodeLanguage, .css)
        XCTAssertNil(v._testMarkdownColor(at: 0))   // CSS に予約語ハイライトは無い
    }

    /// 宣言名（def の後の関数名・YAML のキーなど）は Bold ではなく色で見分けさせる
    /// （Bold はフォントに実体が無いと崩れるため、Monaco 等でも確実な色のほうを選んだ）。
    func testDefinitionNameUsesColorNotBold() throws {
        let text = "def greet():\n    pass"
        let (v, url) = try open(text, ext: "py")
        defer { try? FileManager.default.removeItem(at: url) }
        let nameLocation = (text as NSString).range(of: "greet").location
        XCTAssertNotNil(v._testMarkdownColor(at: nameLocation))
        XCTAssertFalse(v._testMarkdownFontTraits(at: nameLocation).contains(.bold))
    }

    func testYamlKeyUsesColorNotBold() throws {
        let text = "image: nginx"
        let (v, url) = try open(text, ext: "yml")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(v._testMarkdownColor(at: 0))
        XCTAssertFalse(v._testMarkdownFontTraits(at: 0).contains(.bold))
    }
}
