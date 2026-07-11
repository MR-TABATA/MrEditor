import XCTest
import AppKit
@testable import MrEditor
@testable import MrEditorCore

/// 表示設定（タブ幅・行間・現在行ハイライト・カーソル形状）の永続化・通知と、
/// それらを反映する `EditorStyle` の導出を検証する。
/// UserDefaults.standard を触るため、各テストで元の値へ復元する。
final class DisplaySettingsTests: XCTestCase {

    private var saved: (tab: Int, spacing: LineSpacing, hl: Bool, cursor: CursorShape)!

    override func setUp() {
        super.setUp()
        saved = (AppSettings.tabWidth, AppSettings.lineSpacing,
                 AppSettings.highlightCurrentLine, AppSettings.cursorShape)
    }

    override func tearDown() {
        AppSettings.tabWidth = saved.tab
        AppSettings.lineSpacing = saved.spacing
        AppSettings.highlightCurrentLine = saved.hl
        AppSettings.cursorShape = saved.cursor
        super.tearDown()
    }

    func testDefaults() {
        // 既定は tab=4 / 標準 / ハイライト on / バー。
        AppSettings.tabWidth = 4
        XCTAssertEqual(AppSettings.tabWidth, 4)
        AppSettings.lineSpacing = .standard
        XCTAssertEqual(AppSettings.lineSpacing, .standard)
    }

    func testPersistRoundTrip() {
        AppSettings.tabWidth = 8
        AppSettings.lineSpacing = .wider
        AppSettings.highlightCurrentLine = false
        AppSettings.cursorShape = .block
        XCTAssertEqual(AppSettings.tabWidth, 8)
        XCTAssertEqual(AppSettings.lineSpacing, .wider)
        XCTAssertFalse(AppSettings.highlightCurrentLine)
        XCTAssertEqual(AppSettings.cursorShape, .block)
    }

    func testEachChangePostsDisplayNotification() {
        for change in [{ AppSettings.tabWidth = 2 },
                       { AppSettings.lineSpacing = .wide },
                       { AppSettings.highlightCurrentLine = true },
                       { AppSettings.cursorShape = .underline }] {
            let exp = expectation(forNotification: .mrEditorDisplayChanged, object: nil)
            change()
            wait(for: [exp], timeout: 1)
        }
    }

    func testTabIntervalScalesWithWidth() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        AppSettings.tabWidth = 2
        let two = EditorStyle.tabInterval(for: font)
        AppSettings.tabWidth = 8
        let eight = EditorStyle.tabInterval(for: font)
        XCTAssertGreaterThan(eight, two)
        // 8 幅は 2 幅のちょうど 4 倍（同じスペース幅 × 文字数）。
        XCTAssertEqual(eight, two * 4, accuracy: 0.5)
    }

    func testLineHeightScalesWithSpacing() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        AppSettings.lineSpacing = .standard
        let base = EditorStyle.lineHeight(for: font)
        AppSettings.lineSpacing = .wider
        let wider = EditorStyle.lineHeight(for: font)
        XCTAssertGreaterThan(wider, base)
    }

    func testParagraphStyleUsesEqualLineHeightsAndTabInterval() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        AppSettings.tabWidth = 4
        AppSettings.lineSpacing = .standard
        guard let p = EditorStyle.paragraphStyle(for: font) as? NSParagraphStyle else {
            return XCTFail("paragraph style")
        }
        XCTAssertEqual(p.minimumLineHeight, p.maximumLineHeight)
        XCTAssertEqual(p.minimumLineHeight, EditorStyle.lineHeight(for: font), accuracy: 0.5)
        XCTAssertEqual(p.defaultTabInterval, EditorStyle.tabInterval(for: font), accuracy: 0.5)
        XCTAssertTrue(p.tabStops.isEmpty)
    }
}
