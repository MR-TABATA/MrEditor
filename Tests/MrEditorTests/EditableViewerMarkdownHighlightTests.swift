import XCTest
import AppKit
@testable import MrEditorCore

/// Markdown 構文ハイライトの配線（`.md` で開いたときだけ塗る・打鍵で塗り直す）。
/// 役割ごとの範囲判定そのものは `MarkdownSyntaxTests` が受け持つ。
final class EditableViewerMarkdownHighlightTests: XCTestCase {
    private func tempURL(ext: String = "md") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-md-\(UUID().uuidString).\(ext)")
    }

    private func open(_ text: String, ext: String = "md") throws -> (EditableViewer, URL) {
        let url = tempURL(ext: ext)
        try text.data(using: .utf8)!.write(to: url)
        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        return (v, url)
    }

    // MARK: - 拡張子で判定する

    func testMarkdownExtensionDetected() throws {
        let (v, url) = try open("# hi")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(v._testIsMarkdownFile)
    }

    func testNonMarkdownExtensionNotHighlighted() throws {
        let (v, url) = try open("# not markdown", ext: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(v._testIsMarkdownFile)
        XCTAssertNil(v._testMarkdownColor(at: 0))
    }

    // MARK: - 実際に塗られる

    func testHeadingGetsColoredOnOpen() throws {
        let (v, url) = try open("# Title\nbody")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(v._testMarkdownColor(at: 0))
        // 本文行はテーマの基本色のまま（temporary attribute を足していない）。
        let bodyLocation = ("# Title\nbody" as NSString).range(of: "body").location
        XCTAssertNil(v._testMarkdownColor(at: bodyLocation))
    }

    func testBoldGetsBoldFontTrait() throws {
        let text = "plain **bold** plain"
        let (v, url) = try open(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let boldLocation = (text as NSString).range(of: "**bold**").location + 2
        XCTAssertTrue(v._testMarkdownFontTraits(at: boldLocation).contains(.bold))
    }

    func testStrikethroughApplied() throws {
        let text = "~~gone~~"
        let (v, url) = try open(text)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(v._testHasStrikethrough(at: 2))
    }

    // MARK: - 打鍵のたびに塗り直す

    func testHighlightRefreshesAfterEdit() throws {
        let (v, url) = try open("plain text")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(v._testMarkdownColor(at: 0))

        v._testSetText("# Now a heading")
        v._testRefreshMarkdownHighlight()
        XCTAssertNotNil(v._testMarkdownColor(at: 0))
    }

    // MARK: - 巨大ファイルでは塗らない（打鍵が重くならないように）

    func testOversizedMarkdownSkipsHighlighting() throws {
        // 上限（2MB）を超える本文では、見出しがあっても塗らない。
        let padding = String(repeating: "x", count: 2 * 1024 * 1024)
        let big = "# heading\n" + padding
        let (v, url) = try open(big)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(v._testMarkdownColor(at: 0))
    }

    // MARK: - Bold の実体が無いフォント（Monaco）でも太く見せる

    func testBoldFallsBackToSyntheticStrokeOnFontWithoutBoldFace() throws {
        // 前提確認：Monaco に本物の Bold 書体が無いこと（無ければこのテストの前提が崩れている）。
        let monaco = NSFont(name: "Monaco", size: 12)!
        var traits = monaco.fontDescriptor.symbolicTraits
        traits.insert(.bold)
        let boldDescriptor = monaco.fontDescriptor.withSymbolicTraits(traits)
        let hasRealBold = NSFont(descriptor: boldDescriptor, size: 12)?
            .fontDescriptor.symbolicTraits.contains(.bold) ?? false
        try XCTSkipIf(hasRealBold, "この環境の Monaco には Bold があるため前提が崩れている")

        let savedName = EditorFont.currentName
        EditorFont.setName("Monaco")
        defer { EditorFont.setName(savedName) }

        let text = "# heading"
        let (v, url) = try open(text)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(v._testMarkdownFontTraits(at: 0).contains(.bold))
        XCTAssertTrue(v._testHasSyntheticBoldStroke(at: 0))
        XCTAssertNotNil(v._testMarkdownColor(at: 0))   // 色は合成でも普通に付く
    }

    // MARK: - SF Mono など San Francisco 系フォントでも本物の Bold を見つけられる

    /// 旧 NSFontManager の `traits(of:)` は San Francisco 系フォントの Bold を
    /// 正しく認識できないことがあった（本文でこの API を使わなくなった理由そのもの）。
    /// NSFontDescriptor 経由なら見つかることを、既定フォント（SF Mono→Menlo フォールバック）で確認する。
    func testBoldFindsRealBoldOnDefaultSystemFont() throws {
        let savedName = EditorFont.currentName
        EditorFont.setName(nil)   // 既定のフォールバック順（SF Mono → Menlo → ...）
        defer { EditorFont.setName(savedName) }

        let text = "# heading"
        let (v, url) = try open(text)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(v._testMarkdownFontTraits(at: 0).contains(.bold))
        XCTAssertFalse(v._testHasSyntheticBoldStroke(at: 0))   // 合成フォールバックには落ちていない
    }
}
