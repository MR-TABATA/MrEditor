import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowController: MainWindowController?
    private var followItem: NSMenuItem?
    private var recentMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let controller = MainWindowController()
        self.windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // コマンドライン引数で渡されたパスを全て開く。
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in args {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { controller.open(url: url) }
        }

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = windowController else { return .terminateNow }
        return c.confirmTerminate() ? .terminateNow : .terminateCancel
    }

    // Finder からの「で開く」/ ファイルドロップ（複数可）
    func application(_ application: NSApplication, open urls: [URL]) {
        let c = ensureController()
        urls.forEach { c.open(url: $0) }
    }

    private func ensureController() -> MainWindowController {
        if let c = windowController { return c }
        let c = MainWindowController()
        windowController = c
        return c
    }

    @objc private func newDocument(_ sender: Any?) {
        ensureController().newDocument()
    }

    @objc private func openDocument(_ sender: Any?) {
        ensureController().openDocument(sender)
    }

    @objc private func performFind(_ sender: Any?) {
        windowController?.showSearch()
    }

    @objc private func performFindNext(_ sender: Any?) { windowController?.findNext() }
    @objc private func performFindPrev(_ sender: Any?) { windowController?.findPrev() }

    @objc private func performCloseDocument(_ sender: Any?) {
        if let c = windowController { c.closeActiveDocument() } else { NSApp.keyWindow?.performClose(nil) }
    }

    @objc private func performSave(_ sender: Any?) { windowController?.saveActiveDocument() }
    @objc private func performSaveAs(_ sender: Any?) { windowController?.saveActiveDocumentAs() }

    @objc private func performGoToLine(_ sender: Any?) { windowController?.promptGoToLine() }

    @objc private func performZoomIn(_ sender: Any?) { windowController?.zoomIn() }
    @objc private func performZoomOut(_ sender: Any?) { windowController?.zoomOut() }
    @objc private func performZoomReset(_ sender: Any?) { windowController?.zoomReset() }

    // MARK: - 最近使った項目

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        ensureController().open(url: url)
    }

    @objc private func clearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    /// File ＞ 最近使った項目 サブメニューを開くたびに再構築する。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let empty = NSMenuItem(title: L("menu.recentEmpty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L("menu.clearRecent"),
                               action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func performFollow(_ sender: Any?) {
        let on = windowController?.toggleFollow() ?? false
        followItem?.state = on ? .on : .off
    }

    // MARK: - メニュー有効/無効

    /// アクティブなドキュメントの能力に応じてメニュー項目を有効/無効にする。
    /// （target nil の編集系＝Undo/Cut 等は NSTextView が自動で検証する。）
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // 保存中の進捗表示のラジオ（windowController 不要・常に有効）。
        switch item.action {
        case #selector(setSaveProgressStatusBar(_:)):
            item.state = AppSettings.saveProgressStyle == .statusBar ? .on : .off
            return true
        case #selector(setSaveProgressSheet(_:)):
            item.state = AppSettings.saveProgressStyle == .sheet ? .on : .off
            return true
        default: break
        }
        guard let c = windowController else { return true }
        switch item.action {
        case #selector(performSave(_:)), #selector(performSaveAs(_:)):
            return c.canSave
        case #selector(performFind(_:)), #selector(performFindNext(_:)), #selector(performFindPrev(_:)):
            return c.canSearch
        case #selector(performFollow(_:)):
            item.state = c.isFollowingActive ? .on : .off
            return c.canFollow
        case #selector(performGoToLine(_:)), #selector(performCloseDocument(_:)):
            return c.hasActiveDocument
        default:
            return true
        }
    }

    // MARK: - メニュー

    private func buildMenu() {
        let mainMenu = NSMenu()

        // アプリメニュー
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let appName = AppInfo.name
        appMenu.addItem(withTitle: L("menu.about", appName), action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.hide", appName),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit", appName),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // ファイルメニュー
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: L("menu.file"))
        fileMenuItem.submenu = fileMenu
        let newItem = NSMenuItem(title: L("menu.new"),
                                 action: #selector(newDocument(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        let openItem = NSMenuItem(title: L("menu.open"),
                                  action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        // 最近使った項目（サブメニューは開くたびに menuNeedsUpdate で再構築）
        let recentItem = NSMenuItem(title: L("menu.openRecent"), action: nil, keyEquivalent: "")
        let recent = NSMenu(title: L("menu.openRecent"))
        recent.delegate = self
        recentItem.submenu = recent
        fileMenu.addItem(recentItem)
        self.recentMenu = recent
        fileMenu.addItem(.separator())
        let saveItem = NSMenuItem(title: L("menu.save"),
                                  action: #selector(performSave(_:)), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)
        let saveAsItem = NSMenuItem(title: L("menu.saveAs"),
                                    action: #selector(performSaveAs(_:)), keyEquivalent: "S")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = self
        fileMenu.addItem(saveAsItem)
        fileMenu.addItem(.separator())
        let closeItem = NSMenuItem(title: L("menu.close"),
                                   action: #selector(performCloseDocument(_:)), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)

        // 編集メニュー（検索）
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        // アンドゥ／リドゥ（⌘Z / ⌘⇧Z）: target nil でレスポンダチェーン（NSTextView）へ。
        let undoItem = NSMenuItem(title: L("menu.undo"),
                                  action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: L("menu.redo"),
                                  action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        // 切り取り／コピー／貼り付け／全選択: target nil でレスポンダチェーンへ
        // （編集ペインは NSTextView、ビューアはコピーのみ DocumentView が処理）。
        let cutItem = NSMenuItem(title: L("menu.cut"),
                                 action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(cutItem)
        let copyItem = NSMenuItem(title: L("menu.copy"),
                                  action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: L("menu.paste"),
                                   action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(pasteItem)
        let selectAllItem = NSMenuItem(title: L("menu.selectAll"),
                                       action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(selectAllItem)
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: L("menu.find"),
                                  action: #selector(performFind(_:)), keyEquivalent: "f")
        findItem.target = self
        editMenu.addItem(findItem)
        let findNextItem = NSMenuItem(title: L("menu.findNext"),
                                      action: #selector(performFindNext(_:)), keyEquivalent: "g")
        findNextItem.target = self
        editMenu.addItem(findNextItem)
        let findPrevItem = NSMenuItem(title: L("menu.findPrev"),
                                      action: #selector(performFindPrev(_:)), keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.target = self
        editMenu.addItem(findPrevItem)

        // 表示メニュー（末尾追従）
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        let gotoItem = NSMenuItem(title: L("menu.gotoLine"),
                                  action: #selector(performGoToLine(_:)), keyEquivalent: "l")
        gotoItem.target = self
        viewMenu.addItem(gotoItem)
        viewMenu.addItem(.separator())
        // フォント拡大縮小
        let zoomIn = NSMenuItem(title: L("menu.zoomIn"),
                                action: #selector(performZoomIn(_:)), keyEquivalent: "+")
        zoomIn.target = self
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: L("menu.zoomOut"),
                                 action: #selector(performZoomOut(_:)), keyEquivalent: "-")
        zoomOut.target = self
        viewMenu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: L("menu.zoomReset"),
                                   action: #selector(performZoomReset(_:)), keyEquivalent: "0")
        zoomReset.target = self
        viewMenu.addItem(zoomReset)
        viewMenu.addItem(.separator())
        let follow = NSMenuItem(title: L("menu.follow"),
                                action: #selector(performFollow(_:)), keyEquivalent: "f")
        follow.keyEquivalentModifierMask = [.command, .option]
        follow.target = self
        viewMenu.addItem(follow)
        self.followItem = follow

        // 保存中の進捗表示（A: ステータスバー / B: シート）をラジオで切り替える。
        viewMenu.addItem(.separator())
        let saveProgItem = NSMenuItem(title: L("menu.saveProgress"), action: nil, keyEquivalent: "")
        let saveProgMenu = NSMenu(title: L("menu.saveProgress"))
        let statusBarItem = NSMenuItem(title: L("menu.saveProgress.statusBar"),
                                       action: #selector(setSaveProgressStatusBar(_:)), keyEquivalent: "")
        statusBarItem.target = self
        let sheetItem = NSMenuItem(title: L("menu.saveProgress.sheet"),
                                   action: #selector(setSaveProgressSheet(_:)), keyEquivalent: "")
        sheetItem.target = self
        saveProgMenu.addItem(statusBarItem)
        saveProgMenu.addItem(sheetItem)
        saveProgItem.submenu = saveProgMenu
        viewMenu.addItem(saveProgItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func setSaveProgressStatusBar(_ sender: Any?) { AppSettings.saveProgressStyle = .statusBar }
    @objc private func setSaveProgressSheet(_ sender: Any?) { AppSettings.saveProgressStyle = .sheet }
}
