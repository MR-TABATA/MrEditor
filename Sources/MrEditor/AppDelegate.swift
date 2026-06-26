import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

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

    // MARK: - メニュー

    private func buildMenu() {
        let mainMenu = NSMenu()

        // アプリメニュー
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let appName = "MrEditor"
        appMenu.addItem(withTitle: "\(appName) について", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "\(appName) を隠す",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "\(appName) を終了",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // ファイルメニュー
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "ファイル")
        fileMenuItem.submenu = fileMenu
        let openItem = NSMenuItem(title: "開く…",
                                  action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "ウィンドウを閉じる",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
    }
}
