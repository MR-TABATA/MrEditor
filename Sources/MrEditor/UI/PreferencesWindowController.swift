import AppKit

/// 環境設定ウィンドウ（⌘,）。今は「保存中の表示」の切替のみ。
/// 将来ここにフォント等の設定を集約する。
final class PreferencesWindowController: NSWindowController {
    private var statusBarRadio: NSButton!
    private var sheetRadio: NSButton!

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("prefs.title")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
        window.center()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let heading = NSTextField(labelWithString: L("prefs.saveProgress"))
        heading.font = .boldSystemFont(ofSize: 13)

        statusBarRadio = NSButton(radioButtonWithTitle: L("menu.saveProgress.statusBar"),
                                  target: self, action: #selector(radioChanged(_:)))
        sheetRadio = NSButton(radioButtonWithTitle: L("menu.saveProgress.sheet"),
                              target: self, action: #selector(radioChanged(_:)))

        let hint = NSTextField(wrappingLabelWithString: L("prefs.saveProgress.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, statusBarRadio, sheetRadio, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        syncRadios()
    }

    private func syncRadios() {
        let s = AppSettings.saveProgressStyle
        statusBarRadio.state = (s == .statusBar) ? .on : .off
        sheetRadio.state = (s == .sheet) ? .on : .off
    }

    @objc private func radioChanged(_ sender: NSButton) {
        AppSettings.saveProgressStyle = (sender === sheetRadio) ? .sheet : .statusBar
        syncRadios()
    }

    /// ウィンドウを最前面に出す（無ければ生成済みのものを再利用）。
    func show() {
        syncRadios()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
