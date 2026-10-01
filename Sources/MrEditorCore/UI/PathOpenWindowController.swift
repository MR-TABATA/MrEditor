import AppKit

/// 「パスを指定して開く…」（⌥⌘O）。ターミナルや AI の回答からコピーしたローカルパスを
/// 貼り付けて開くための小さな窓。狙いは独自性ではなく、パスを迷わず開ける使いやすさ。
///
/// フォルダが渡されたら、フォルダの窓（ツリー）を開く。窓を出す係（`folderHandler`）が
/// 渡されていなければ、従来どおり Finder で見せる。
final class PathOpenWindowController: NSWindowController {

    private let pathField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let openHandler: (URL) -> Void
    private let folderHandler: ((URL) -> Void)?

    init(openHandler: @escaping (URL) -> Void, folderHandler: ((URL) -> Void)? = nil) {
        self.openHandler = openHandler
        self.folderHandler = folderHandler
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 110),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("pathOpen.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    /// ウィンドウを最前面に出す（無ければ生成済みのものを再利用）。呼ぶたびに入力欄を空にする。
    func show() {
        pathField.stringValue = ""
        errorLabel.stringValue = ""
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(pathField)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        pathField.placeholderString = L("pathOpen.placeholder")
        pathField.target = self
        pathField.action = #selector(openTapped)
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

        let openButton = NSButton(title: L("pathOpen.open"), target: self, action: #selector(openTapped))
        openButton.keyEquivalent = "\r"

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)

        let row = NSStackView(views: [pathField, openButton])
        row.orientation = .horizontal
        row.spacing = 8

        let stack = NSStackView(views: [row, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        ])
    }

    @objc private func openTapped() {
        guard let url = Self.resolve(pathField.stringValue) else {
            errorLabel.stringValue = L("pathOpen.notFound")
            return
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            if let folderHandler { folderHandler(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } else {
            openHandler(url)
        }
        window?.performClose(nil)
    }

    /// 入力文字列を実在するファイル/フォルダの URL にする。無ければ nil。
    /// 前後の空白と、コピー時に付く外側の引用符（1 組だけ）を落とし、`~` を展開する。
    /// 相対パスは対応しない（GUI アプリの cwd は実用上 `/` になるだけで、基準にならない）。
    static func resolve(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2 {
            let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}")]
            for (open, close) in pairs where s.first == open && s.last == close {
                s = String(s.dropFirst().dropLast())
                break
            }
        }
        s = (s as NSString).expandingTildeInPath
        guard !s.isEmpty, FileManager.default.fileExists(atPath: s) else { return nil }
        return URL(fileURLWithPath: s)
    }
}
