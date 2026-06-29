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
        let closeItem = NSMenuItem(title: L("menu.close"),
                                   action: #selector(performCloseDocument(_:)), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)

        // 編集メニュー（検索）
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        // コピー（⌘C）: target nil でレスポンダチェーン（DocumentView.copy）へ。
        let copyItem = NSMenuItem(title: L("menu.copy"),
                                  action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(copyItem)
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

        NSApp.mainMenu = mainMenu
    }
}
