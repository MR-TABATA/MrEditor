import XCTest
import AppKit
@testable import MrEditorCore

final class InspectorTests: XCTestCase {
    private var suiteName: String!
    private var testDefaults: UserDefaults!
    private var savedInspectorWidth: CGFloat = 260
    private var savedIsInspectorVisible: Bool = false

    override func setUp() {
        super.setUp()
        suiteName = "MrEditorTests.Inspector.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        savedInspectorWidth = AppSettings.inspectorWidth
        savedIsInspectorVisible = AppSettings.isInspectorVisible
    }

    override func tearDown() {
        AppSettings.inspectorWidth = savedInspectorWidth
        AppSettings.isInspectorVisible = savedIsInspectorVisible
        testDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - AppSettings

    func testInspectorWidthDefaultIs260() {
        XCTAssertEqual(AppSettings.inspectorWidth(from: testDefaults), AppSettings.defaultInspectorWidth)
        XCTAssertEqual(AppSettings.defaultInspectorWidth, 260)
    }

    func testInspectorWidthClampsBelowMinimum() {
        testDefaults.set(100.0, forKey: "MrEditor.inspectorWidth")
        XCTAssertEqual(AppSettings.inspectorWidth(from: testDefaults), AppSettings.minInspectorWidth)
        XCTAssertEqual(AppSettings.minInspectorWidth, 200)
    }

    func testInspectorWidthClampsAboveMaximum() {
        testDefaults.set(900.0, forKey: "MrEditor.inspectorWidth")
        XCTAssertEqual(AppSettings.inspectorWidth(from: testDefaults), AppSettings.maxInspectorWidth)
        XCTAssertEqual(AppSettings.maxInspectorWidth, 500)
    }

    func testInspectorWidthAcceptsValidValue() {
        testDefaults.set(320.0, forKey: "MrEditor.inspectorWidth")
        XCTAssertEqual(AppSettings.inspectorWidth(from: testDefaults), 320.0)
    }

    func testIsInspectorVisibleDefaultIsFalse() {
        XCTAssertFalse(AppSettings.isInspectorVisible(from: testDefaults))
        testDefaults.set(true, forKey: "MrEditor.isInspectorVisible")
        XCTAssertTrue(AppSettings.isInspectorVisible(from: testDefaults))
    }

    // MARK: - MainWindowController クランプ計算

    func testMaxInspectorWidthCalculation() {
        // 窓幅 1000px: 40% = 400px (200〜500 の範囲内)
        XCTAssertEqual(MainWindowController.maxInspectorWidth(forWindowWidth: 1000), 400)

        // 窓幅 1600px: 40% = 640px ➔ max 500px でクランプ
        XCTAssertEqual(MainWindowController.maxInspectorWidth(forWindowWidth: 1600), 500)

        // 窓幅 400px: 40% = 160px ➔ min 200px でクランプ
        XCTAssertEqual(MainWindowController.maxInspectorWidth(forWindowWidth: 400), 200)
    }

    // MARK: - InspectorPanelView HitTest

    func testHitTestReturnsSelfNearLeftEdge() {
        let panel = InspectorPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        // 左端 6px 以内はリサイズハンドルとして自身を返す
        XCTAssertTrue(panel.isNearLeftEdge(NSPoint(x: 0, y: 100)))
        XCTAssertTrue(panel.isNearLeftEdge(NSPoint(x: 3, y: 100)))
        XCTAssertTrue(panel.isNearLeftEdge(NSPoint(x: 6, y: 100)))

        // 6px を超えるとハンドルではない
        XCTAssertFalse(panel.isNearLeftEdge(NSPoint(x: 7, y: 100)))
        XCTAssertFalse(panel.isNearLeftEdge(NSPoint(x: 50, y: 100)))
        XCTAssertFalse(panel.isNearLeftEdge(NSPoint(x: -1, y: 100)))
    }

    // MARK: - DocumentInfo フォーマット

    func testDocumentInfoFormatting() {
        let info = DocumentInfo(
            fileName: "test.log",
            path: "/path/to/test.log",
            fileSize: 1048576, // 1 MB
            lineCount: 12500,
            encodingName: "UTF-8",
            lineEndingName: "LF",
            formatName: "Log",
            isReadOnly: false,
            isDirty: true
        )

        XCTAssertTrue(info.formattedSize.contains("1 MB") || info.formattedSize.contains("1,048,576"))
        XCTAssertEqual(info.formattedLineCount, "12,500 行")
        XCTAssertTrue(info.formattedStatus.contains("編集可能"))
        XCTAssertTrue(info.formattedStatus.contains("未保存"))
    }

    func testDocumentInfoNilSize() {
        let info = DocumentInfo(
            fileName: "untitled",
            path: nil,
            fileSize: nil,
            lineCount: 0,
            encodingName: "UTF-8",
            lineEndingName: "LF",
            formatName: "Plain Text",
            isReadOnly: true,
            isDirty: false
        )

        XCTAssertEqual(info.formattedSize, "—")
        XCTAssertEqual(info.formattedLineCount, "0 行")
        XCTAssertTrue(info.formattedStatus.contains("読み取り専用"))
        XCTAssertFalse(info.formattedStatus.contains("未保存"))
    }

    // MARK: - タブ切り替え

    func testInspectorTabSwitching() {
        let panel = InspectorPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        XCTAssertEqual(panel.currentTab, .bookmarks)

        panel.showTab(.info)
        XCTAssertEqual(panel.currentTab, .info)

        panel.showTab(.summary)
        XCTAssertEqual(panel.currentTab, .summary)

        panel.showTab(.bookmarks)
        XCTAssertEqual(panel.currentTab, .bookmarks)
    }

    // MARK: - しおりビューの更新

    func testBookmarkViewUpdate() {
        let view = BookmarkInspectorView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        // 初期状態は空
        view.updateBookmarks([])

        // アイテムを追加
        var selectedLine: Int?
        var removedLine: Int?
        view.onSelectLine = { selectedLine = $0 }
        view.onRemoveLine = { removedLine = $0 }

        view.updateBookmarks([
            (line: 10, text: "let a = 1"),
            (line: 42, text: "let b = 2")
        ])

        // 再度空に更新
        view.updateBookmarks([])
        XCTAssertNil(selectedLine)
        XCTAssertNil(removedLine)
    }
}
