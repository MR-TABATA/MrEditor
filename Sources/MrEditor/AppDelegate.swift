import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var followItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let controller = MainWindowController()
        self.windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // コマンドライン引数でパスが渡されたら開く（開発時の動作確認用）。
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                controller.open(url: url)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // Finder からの「で開く」/ ファイルドロップ
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            ensureController().open(url: url)
        }
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
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("menu.closeWindow"),
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

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

        // 表示メニュー（末尾追従）
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        let follow = NSMenuItem(title: L("menu.follow"),
                                action: #selector(performFollow(_:)), keyEquivalent: "f")
        follow.keyEquivalentModifierMask = [.command, .option]
        follow.target = self
        viewMenu.addItem(follow)
        self.followItem = follow

        NSApp.mainMenu = mainMenu
    }
}
