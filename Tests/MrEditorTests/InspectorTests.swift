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
        let testDate = Date(timeIntervalSince1970: 1730000000)
        let info = DocumentInfo(
            fileName: "test.log",
            path: "/path/to/test.log",
            fileSize: 1048576, // 1 MB
            lineCount: 12500,
            encodingName: "UTF-8",
            lineEndingName: "LF",
            fontName: "SF Mono, 13 pt",
            creationDate: testDate,
            modificationDate: testDate,
            generatorApp: "Xcode",
            formatName: "Log",
            isReadOnly: false,
            isDirty: true
        )

        XCTAssertTrue(info.formattedSize.contains("1 MB") || info.formattedSize.contains("1,048,576"))
        XCTAssertEqual(info.formattedLineCount, "12,500 行")
        XCTAssertEqual(info.fontName, "SF Mono, 13 pt")
        XCTAssertEqual(info.generatorApp, "Xcode")
        XCTAssertFalse(info.formattedCreationDate.isEmpty)
        XCTAssertFalse(info.formattedModificationDate.isEmpty)
        let writable = L("inspector.info.status.writable")
        let dirty = L("inspector.info.status.dirty")
        XCTAssertTrue(info.formattedStatus.contains(writable))
        XCTAssertTrue(info.formattedStatus.contains(dirty))
    }

    func testDocumentInfoNilSize() {
        let info = DocumentInfo(
            fileName: "untitled",
            path: nil,
            fileSize: nil,
            lineCount: 0,
            encodingName: "UTF-8",
            lineEndingName: "LF",
            fontName: "System Monospace, 13 pt",
            creationDate: nil,
            modificationDate: nil,
            generatorApp: nil,
            formatName: "Plain Text",
            isReadOnly: true,
            isDirty: false
        )

        XCTAssertEqual(info.formattedSize, "—")
        XCTAssertEqual(info.formattedLineCount, "0 行")
        XCTAssertEqual(info.formattedCreationDate, "—")
        XCTAssertEqual(info.formattedModificationDate, "—")
        XCTAssertNil(info.generatorApp)
        let readOnly = L("inspector.info.status.readOnly")
        let dirty = L("inspector.info.status.dirty")
        XCTAssertTrue(info.formattedStatus.contains(readOnly))
        XCTAssertFalse(info.formattedStatus.contains(dirty))
    }

    // MARK: - タブ切り替え

    func testInspectorTabSwitching() {
        let panel = InspectorPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        XCTAssertEqual(panel.currentTab, .bookmarks)

        panel.showTab(.info)
        XCTAssertEqual(panel.currentTab, .info)

        panel.showTab(.bookmarks)
        XCTAssertEqual(panel.currentTab, .bookmarks)
    }

    // MARK: - しおりビューの更新とコールバック

    func testBookmarkViewUpdate() {
        let view = BookmarkInspectorView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        // 初期状態は空
        view.updateBookmarks([])

        var selectedLine: Int?
        var removedLine: Int?
        view.onSelectLine = { selectedLine = $0 }
        view.onRemoveLine = { removedLine = $0 }

        view.updateBookmarks([
            (line: 10, text: "let a = 1"),
            (line: 42, text: "let b = 2")
        ])

        // コールバックの接続確認
        view.onSelectLine?(10)
        XCTAssertEqual(selectedLine, 10)
        // goToLine への変換（0-indexed + 1 = 11）
        XCTAssertEqual(selectedLine.map { $0 + 1 }, 11)

        view.onRemoveLine?(42)
        XCTAssertEqual(removedLine, 42)

        // 再度空に更新
        view.updateBookmarks([])
    }

    func testNearLeftEdgeDisabledWhenHiddenOrZeroWidth() {
        let panel = InspectorPanelView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        XCTAssertTrue(panel.isNearLeftEdge(NSPoint(x: 3, y: 100)))

        panel.isHidden = true
        XCTAssertFalse(panel.isNearLeftEdge(NSPoint(x: 3, y: 100)))

        panel.isHidden = false
        panel.frame = NSRect(x: 0, y: 0, width: 0, height: 500)
        XCTAssertFalse(panel.isNearLeftEdge(NSPoint(x: 0, y: 100)))
    }

    func testDocumentInfoDirtyAndReadOnlyStatus() {
        let info = DocumentInfo(
            fileName: "sample.txt",
            path: "/path/to/sample.txt",
            fileSize: 500,
            lineCount: 20,
            encodingName: "UTF-8",
            lineEndingName: "LF",
            fontName: "Hiragino Sans, 13 pt",
            creationDate: nil,
            modificationDate: nil,
            generatorApp: nil,
            formatName: "Plain Text",
            isReadOnly: false,
            isDirty: false
        )
        let writable = L("inspector.info.status.writable")
        let dirty = L("inspector.info.status.dirty")
        XCTAssertTrue(info.formattedStatus.contains(writable))
        XCTAssertFalse(info.formattedStatus.contains(dirty))

        let dirtyInfo = DocumentInfo(
            fileName: "sample.txt",
            path: "/path/to/sample.txt",
            fileSize: 500,
            lineCount: 20,
            encodingName: "UTF-8",
            lineEndingName: "LF",
            fontName: "Hiragino Sans, 13 pt",
            creationDate: nil,
            modificationDate: nil,
            generatorApp: nil,
            formatName: "Plain Text",
            isReadOnly: false,
            isDirty: true
        )
        XCTAssertTrue(dirtyInfo.formattedStatus.contains(dirty))
    }

    // MARK: - レビュー指摘対応テスト (tests #1 ~ #5, performance #2, performance #3)

    func testBookmarkViewCachesCurrentItemsToAvoidRedraw() {
        let view = BookmarkInspectorView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
        let items = [(line: 1, text: "alpha"), (line: 2, text: "beta")]
        view.updateBookmarks(items)
        XCTAssertEqual(view.currentItems.count, 2)
        XCTAssertEqual(view.currentItems[0].line, 1)

        // 同一内容で再度更新してもビュー再構築をスキップ
        view.updateBookmarks(items)
        XCTAssertEqual(view.currentItems.count, 2)

        // 異なる内容で更新
        view.updateBookmarks([(line: 3, text: "gamma")])
        XCTAssertEqual(view.currentItems.count, 1)
        XCTAssertEqual(view.currentItems[0].line, 3)
    }

    func testInspectorFileMetadataCacheInvalidationOnSave() throws {
        let controller = MainWindowController()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.txt")
        try "Initial Short Content".write(to: fileURL, atomically: true, encoding: .utf8)

        let viewer = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(viewer.open(url: fileURL))
        controller.viewers = [viewer]
        controller.activeIndex = 0

        // 初回フェッチでキャッシュ生成
        let meta1 = controller.fetchOrCachedMetadata(for: viewer, state: nil)
        XCTAssertEqual(controller.inspectorMetadataCache?.url, fileURL)
        XCTAssertEqual(meta1.url, fileURL)

        // ファイル更新
        let longContent = "Much Longer Content Overwritten In File To Change File Size"
        try longContent.write(to: fileURL, atomically: true, encoding: .utf8)

        // キャッシュ破棄（保存時や外部リロード時の挙動）
        controller.inspectorMetadataCache = nil
        XCTAssertNil(controller.inspectorMetadataCache)

        // 再フェッチで最新情報が取得されキャッシュされる
        let meta2 = controller.fetchOrCachedMetadata(for: viewer, state: nil)
        XCTAssertEqual(controller.inspectorMetadataCache?.url, fileURL)
        XCTAssertGreaterThan(meta2.size ?? 0, meta1.size ?? 0)
    }

    func testInspectorToggleStateConsistency() {
        let controller = MainWindowController()
        _ = controller.window // window をロード

        AppSettings.isInspectorVisible = false
        controller.inspectorPanel.isHidden = true
        XCTAssertFalse(AppSettings.isInspectorVisible)
        XCTAssertTrue(controller.inspectorPanel.isHidden)

        controller.toggleInspector(nil)
        XCTAssertTrue(AppSettings.isInspectorVisible)
        XCTAssertFalse(controller.inspectorPanel.isHidden)

        controller.toggleInspector(nil)
        XCTAssertFalse(AppSettings.isInspectorVisible)
        XCTAssertTrue(controller.inspectorPanel.isHidden)
    }

    func testInspectorUpdateSkippedWhenClosed() throws {
        let controller = MainWindowController()
        _ = controller.window

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.txt")
        try "Line 1\nLine 2\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let viewer = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(viewer.open(url: fileURL))
        controller.viewers = [viewer]
        controller.activeIndex = 0

        AppSettings.isInspectorVisible = false
        controller.inspectorPanel.isHidden = true
        controller.inspectorMetadataCache = nil

        // パネルが非表示の場合、refresh してもメタデータキャッシュは作られない（スキップされる）
        controller.refreshInspectorBookmarks()
        controller.refreshInspectorInfo()
        XCTAssertNil(controller.inspectorMetadataCache)
        XCTAssertTrue(controller.inspectorPanel.bookmarkView.currentItems.isEmpty)
    }

    func testBookmarkRemovalWithEditableViewer() throws {
        let controller = MainWindowController()
        _ = controller.window

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.txt")
        try "Line 0\nLine 1\nLine 2\nLine 3\nLine 4\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let viewer = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(viewer.open(url: fileURL))
        controller.viewers = [viewer]
        controller.activeIndex = 0

        // 行 2 にしおりを打つ
        viewer.toggleBookmark(line: 2)
        XCTAssertTrue(viewer.bookmarks.contains(2))

        // インスペクタを開いてしおり一覧を実物 viewer と結びつける
        AppSettings.isInspectorVisible = true
        controller.inspectorPanel.isHidden = false
        controller.refreshInspectorBookmarks()

        // しおり一覧のコールバックから行 2 のしおりを解除
        controller.inspectorPanel.bookmarkView.onRemoveLine?(2)
        XCTAssertFalse(viewer.bookmarks.contains(2))
    }

    func testTotalLineCountOnEditableAndPieceTableViewer() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let trailingNewlineURL = tempDir.appendingPathComponent("trailing_newline.txt")
        try "Line 1\nLine 2\nLine 3\n".write(to: trailingNewlineURL, atomically: true, encoding: .utf8)

        let noTrailingNewlineURL = tempDir.appendingPathComponent("no_trailing.txt")
        try "Line 1\nLine 2\nLine 3".write(to: noTrailingNewlineURL, atomically: true, encoding: .utf8)

        let emptyURL = tempDir.appendingPathComponent("empty.txt")
        try "".write(to: emptyURL, atomically: true, encoding: .utf8)

        // 1. 3行・末尾改行なしの比較（3行）
        let editableNoTrail = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(editableNoTrail.open(url: noTrailingNewlineURL))
        let pieceTableNoTrail = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(pieceTableNoTrail.open(url: noTrailingNewlineURL))

        XCTAssertEqual(editableNoTrail.totalLineCount, 3)
        XCTAssertEqual(pieceTableNoTrail.totalLineCount, 3)
        XCTAssertEqual(editableNoTrail.totalLineCount, pieceTableNoTrail.totalLineCount)

        // 2. 3行・末尾改行ありの比較（3行）
        let editableTrail = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(editableTrail.open(url: trailingNewlineURL))
        let pieceTableTrail = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(pieceTableTrail.open(url: trailingNewlineURL))

        XCTAssertEqual(editableTrail.totalLineCount, 3)
        XCTAssertEqual(pieceTableTrail.totalLineCount, 3)
        XCTAssertEqual(editableTrail.totalLineCount, pieceTableTrail.totalLineCount)

        // 3. 空文書の比較（0行）
        let editableEmpty = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(editableEmpty.open(url: emptyURL))
        let pieceTableEmpty = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(pieceTableEmpty.open(url: emptyURL))

        XCTAssertEqual(editableEmpty.totalLineCount, 0)
        XCTAssertEqual(pieceTableEmpty.totalLineCount, 0)
        XCTAssertEqual(editableEmpty.totalLineCount, pieceTableEmpty.totalLineCount)
    }

    func testBuildDocumentInfoUsesLineCountCache() throws {
        let controller = MainWindowController()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.txt")
        try "Alpha\nBeta\nGamma\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let viewer = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertTrue(viewer.open(url: fileURL))

        // state がある場合は state.lineCount を使いキャッシュ
        let state = ViewerState(
            encodingName: "UTF-8",
            lineCount: 42,
            lineCountIsExact: true,
            fileSize: 100,
            indexProgress: 1.0,
            caret: nil,
            charCount: nil
        )
        let info1 = controller.buildDocumentInfo(viewer: viewer, state: state)
        XCTAssertEqual(info1.lineCount, 42)
        XCTAssertEqual(controller.lineCountCache[ObjectIdentifier(viewer)], 42)

        // state がない場合でも、未編集ならキャッシュ値を利用
        let info2 = controller.buildDocumentInfo(viewer: viewer, state: nil)
        XCTAssertEqual(info2.lineCount, 42)
    }
}
