import XCTest
import AppKit
@testable import MrEditorCore

final class SidebarResizeTests: XCTestCase {
    private var suiteName: String!
    private var testDefaults: UserDefaults!
    private var savedSidebarWidth: CGFloat = 200

    override func setUp() {
        super.setUp()
        suiteName = "MrEditorTests.SidebarResize.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        savedSidebarWidth = AppSettings.sidebarWidth
    }

    override func tearDown() {
        AppSettings.sidebarWidth = savedSidebarWidth
        testDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - AppSettings

    func testSidebarWidthDefaultIs200() {
        XCTAssertEqual(AppSettings.sidebarWidth(from: testDefaults), AppSettings.defaultSidebarWidth)
        XCTAssertEqual(AppSettings.defaultSidebarWidth, 200)
    }

    func testSidebarWidthClampsBelowMinimum() {
        testDefaults.set(100.0, forKey: "MrEditor.sidebarWidth")
        XCTAssertEqual(AppSettings.sidebarWidth(from: testDefaults), AppSettings.minSidebarWidth)
        XCTAssertEqual(AppSettings.minSidebarWidth, 140)
    }

    func testSidebarWidthClampsAboveMaximum() {
        testDefaults.set(800.0, forKey: "MrEditor.sidebarWidth")
        XCTAssertEqual(AppSettings.sidebarWidth(from: testDefaults), AppSettings.maxSidebarWidth)
        XCTAssertEqual(AppSettings.maxSidebarWidth, 500)
    }

    func testSidebarWidthAcceptsValidValue() {
        testDefaults.set(280.0, forKey: "MrEditor.sidebarWidth")
        XCTAssertEqual(AppSettings.sidebarWidth(from: testDefaults), 280.0)
    }

    // MARK: - SidebarView HitTest & Events

    func testHitTestReturnsSelfNearRightEdge() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        sidebar.reload(names: ["Document 1"], dirty: [false], active: 0)
        sidebar.layoutSubtreeIfNeeded()

        // 右端 6pt 以内（x = 197）はリサイズハンドルとして自身を返す
        XCTAssertTrue(sidebar.isNearRightEdge(NSPoint(x: 197, y: 200)))
        let hitEdge = sidebar.hitTest(NSPoint(x: 197, y: 200))
        XCTAssertTrue(hitEdge === sidebar, "右端付近はリサイズハンドルとして SidebarView 自身がヒットする")

        // 中央（x = 100）はリサイズ判定にならない
        XCTAssertFalse(sidebar.isNearRightEdge(NSPoint(x: 100, y: 200)))
        XCTAssertFalse(sidebar.isNearRightEdge(NSPoint(x: -1, y: 200)))
        XCTAssertFalse(sidebar.isNearRightEdge(NSPoint(x: 205, y: 200)))
    }

    func testResetWidthTriggeredOnDoubleClick() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        var resetCalled = false
        sidebar.onResetWidth = { resetCalled = true }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView?.addSubview(sidebar)

        // 右端（x = 198）で clickCount = 2 の mouseDown
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 198, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1.0
        )!

        sidebar.mouseDown(with: event)
        XCTAssertTrue(resetCalled, "右端ダブルクリックで onResetWidth が呼ばれる")
    }

    func testDragResizeTriggersOnResize() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        var resizedWidth: CGFloat?
        sidebar.onResize = { width in resizedWidth = width }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView?.addSubview(sidebar)

        // 右端で mouseDown（ドラッグ開始）
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 198, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        sidebar.mouseDown(with: downEvent)

        // 右へ 50pt ドラッグ（x = 248）
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 248, y: 200),
            modifierFlags: [],
            timestamp: 0.1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1.0
        )!
        sidebar.mouseDragged(with: dragEvent)

        XCTAssertEqual(resizedWidth, 250.0, "初期幅 200 + 移動量 50 = 250 が通知される")
    }

    func testDragResizeLeftShrinksWidth() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        var resizedWidth: CGFloat?
        sidebar.onResize = { width in resizedWidth = width }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView?.addSubview(sidebar)

        // 右端で mouseDown
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 198, y: 200),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0)!
        sidebar.mouseDown(with: downEvent)

        // 左へ 30pt ドラッグ（x = 168）
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 168, y: 200),
            modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1.0)!
        sidebar.mouseDragged(with: dragEvent)

        XCTAssertEqual(resizedWidth, 170.0, "初期幅 200 - 移動量 30 = 170 が通知される")
    }

    func testDragIgnoredWhenMouseDownOutsideRightEdge() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        sidebar.reload(names: ["Doc"], dirty: [false], active: 0)
        var resizeCalled = false
        sidebar.onResize = { _ in resizeCalled = true }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView?.addSubview(sidebar)

        // 中央付近（x = 100）で mouseDown
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 100, y: 200),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0)!
        sidebar.mouseDown(with: downEvent)

        // ドラッグしてもリサイズは始まらない
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 150, y: 200),
            modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1.0)!
        sidebar.mouseDragged(with: dragEvent)

        XCTAssertFalse(resizeCalled, "右端以外でのクリック・ドラッグではリサイズが発火しない")
    }

    func testMouseUpTriggersOnResizeEndAndReleasesDrag() {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        var resizeEndWidth: CGFloat?
        var resizeCallCount = 0
        sidebar.onResize = { _ in resizeCallCount += 1 }
        sidebar.onResizeEnd = { width in resizeEndWidth = width }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView?.addSubview(sidebar)

        // ドラッグ開始
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 198, y: 200),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0)!
        sidebar.mouseDown(with: downEvent)

        // ドラッグ
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 230, y: 200),
            modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1.0)!
        sidebar.mouseDragged(with: dragEvent)
        XCTAssertEqual(resizeCallCount, 1)

        // マウスを離す（mouseUp）
        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 230, y: 200),
            modifierFlags: [], timestamp: 0.2, windowNumber: window.windowNumber,
            context: nil, eventNumber: 3, clickCount: 1, pressure: 0.0)!
        sidebar.mouseUp(with: upEvent)

        XCTAssertEqual(resizeEndWidth, 200.0, "ドラッグ終了時に bounds.width が onResizeEnd に通知される")

        // mouseUp 後のドラッグでは onResize が呼ばれない（状態解除確認）
        sidebar.mouseDragged(with: dragEvent)
        XCTAssertEqual(resizeCallCount, 1, "mouseUp 後はドラッグ状態が解除され追加通知されない")
    }

    // MARK: - Integration with MainWindowController

    func testSidebarWidthPersistenceOnResizeEndAndReset() {
        // 本物の MainWindowController を通してドラッグ終了時の保存とリセットを検証
        let controller = MainWindowController()
        guard let window = controller.window else {
            XCTFail("MainWindowController のウィンドウが取得できない")
            return
        }
        window.setContentSize(NSSize(width: 1000, height: 600))
        window.layoutIfNeeded()

        // 1. ドラッグ終了で 280 に変更して保存される
        controller.sidebar.onResize?(280)
        controller.sidebar.onResizeEnd?(280)
        XCTAssertEqual(AppSettings.sidebarWidth, 280, "ドラッグ終了で幅が AppSettings に保存される")
        XCTAssertEqual(controller.sidebarWidthConstraint?.constant, 280, "制約に 280 が反映される")

        // 2. ダブルクリックリセットで 200 に戻る
        controller.sidebar.onResetWidth?()
        XCTAssertEqual(AppSettings.sidebarWidth, AppSettings.defaultSidebarWidth, "リセットで保存値が既定値 200 に戻る")
        XCTAssertEqual(controller.sidebarWidthConstraint?.constant, AppSettings.defaultSidebarWidth, "制約も既定値 200 に戻る")
    }

    func testMainWindowControllerClampsSidebarWidthOnResize() {
        // 窓幅 600 で幅 400 を要求して 240 にクランプされる（実際の窓・コールバックで検証）
        let controller = MainWindowController()
        guard let window = controller.window else {
            XCTFail("MainWindowController のウィンドウが取得できない")
            return
        }
        window.setContentSize(NSSize(width: 600, height: 400))
        window.layoutIfNeeded()

        controller.sidebar.onResize?(400)
        XCTAssertEqual(controller.sidebarWidthConstraint?.constant, 240, "窓幅 600 の 40% 上限である 240 にクランプされる")

        // 下限テスト: 幅 50 を要求しても 140 にクランプ
        controller.sidebar.onResize?(50)
        XCTAssertEqual(controller.sidebarWidthConstraint?.constant, 140, "下限幅 140 にクランプされる")
    }

    func testWindowShrinkClampsSidebarWidth() {
        // 窓幅 1000 で幅 500 を要求（400 にクランプ）したのち、窓幅を 500 に縮めたときにサイドバー幅が 40% 上限の 200 に縮まることを検証
        let controller = MainWindowController()
        guard let window = controller.window else {
            XCTFail("MainWindowController のウィンドウが取得できない")
            return
        }
        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 600), display: true)
        window.layoutIfNeeded()

        // 窓幅 1000 で幅 500 を設定 -> 40% 上限の 400 にクランプ
        controller.sidebar.onResize?(500)
        controller.sidebar.onResizeEnd?(500)
        XCTAssertEqual(controller.sidebarWidthConstraint?.constant, 400, "1000 窓での 40% 上限である 400 にクランプ")

        // 窓を 500 に縮小 -> windowDidResize で 40% 上限の 200 に縮まる
        window.setFrame(NSRect(x: 0, y: 0, width: 500, height: 600), display: true)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertEqual(controller.sidebarWidthConstraint?.constant, 200, "窓を 500 に縮めると 40% 上限の 200 にクランプされる")
    }

    func testDragAndReleaseReflectsConstrainedWidthAndPersists() {
        // 実際の窓でドラッグを行い、制約が反映された幅が bounds.width および保存値に同期することを検証
        let controller = MainWindowController()
        guard let window = controller.window else {
            XCTFail("MainWindowController のウィンドウが取得できない")
            return
        }
        window.setContentSize(NSSize(width: 1000, height: 600))
        window.layoutIfNeeded()

        let sidebar = controller.sidebar
        sidebar.layoutSubtreeIfNeeded()
        let initialWidth = sidebar.bounds.width
        XCTAssertEqual(initialWidth, 200)

        // 右端（x = 198）でドラッグ開始
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 198, y: 200),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0)!
        sidebar.mouseDown(with: downEvent)

        // 右へ 30pt ドラッグ（x = 228）
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 228, y: 200),
            modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1.0)!
        sidebar.mouseDragged(with: dragEvent)

        // レイアウト更新後の見た目の幅を検証
        XCTAssertEqual(sidebar.bounds.width, 230, "ドラッグ中に制約が反映され見た目の幅が 230 になる")

        // マウスを離す（mouseUp）
        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 228, y: 200),
            modifierFlags: [], timestamp: 0.2, windowNumber: window.windowNumber,
            context: nil, eventNumber: 3, clickCount: 1, pressure: 0.0)!
        sidebar.mouseUp(with: upEvent)

        XCTAssertEqual(AppSettings.sidebarWidth, 230, "ドラッグ終了で制限後の幅 230 が保存される")
    }

    func testToggleSidebarRestoresClampedWidth() {
        // 窓幅 500・保存幅 400 で畳んで開き直すと 200 になることを検証
        AppSettings.sidebarWidth = 400
        let controller = MainWindowController()
        guard let window = controller.window else {
            XCTFail("MainWindowController のウィンドウが取得できない")
            return
        }
        window.setContentSize(NSSize(width: 500, height: 600))
        window.layoutIfNeeded()

        // 初期状態で 500 の 40% = 200 にクランプされている
        XCTAssertEqual(controller.sidebarWidthConstraint?.constant, 200)

        // 畳む
        controller.toolbarToggleSidebar(nil)
        XCTAssertEqual(controller.sidebarWidthConstraint?.constant, 0, "畳むと幅制約は 0 になる")
        XCTAssertTrue(controller.sidebar.isHidden)

        // 開き直す
        controller.toolbarToggleSidebar(nil)
        XCTAssertEqual(controller.sidebarWidthConstraint?.constant, 200, "開き直すと窓幅 500 の 40% である 200 で復元される")
        XCTAssertFalse(controller.sidebar.isHidden)
    }

    // MARK: - Window Width 40% Clamp Formula

    func testMaxSidebarWidthForWindowWidth() {
        // 窓幅 1000 -> 40% = 400
        XCTAssertEqual(MainWindowController.maxSidebarWidth(forWindowWidth: 1000), 400.0)

        // 窓幅 600 -> 40% = 240（500で保存されていても 240 に抑えられる）
        XCTAssertEqual(MainWindowController.maxSidebarWidth(forWindowWidth: 600), 240.0)

        // 窓幅 2000 -> 40% = 800 だが maxSidebarWidth (500) でクランプ
        XCTAssertEqual(MainWindowController.maxSidebarWidth(forWindowWidth: 2000), AppSettings.maxSidebarWidth)

        // 窓幅 300 -> 40% = 120 だが minSidebarWidth (140) を下限として保持
        XCTAssertEqual(MainWindowController.maxSidebarWidth(forWindowWidth: 300), AppSettings.minSidebarWidth)
    }
}
