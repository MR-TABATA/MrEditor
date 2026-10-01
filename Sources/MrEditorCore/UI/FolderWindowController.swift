import AppKit

/// 手元のフォルダを歩く窓。ツリーを展開して、名前で絞って、ファイルをダブルクリックで開く。
///
/// 中身は遠隔の窓と同じ `FileTreeView`（手元は `FileManager`、遠隔は ssh を呼ぶだけの違い）。
/// ファイルは本体のウィンドウで開く ―― この窓は**選ぶための面**で、編集はしない。
final class FolderWindowController: NSWindowController, NSWindowDelegate {

    let folderURL: URL
    private let tree = FileTreeView(provider: LocalDirectoryProvider())
    private let statusLabel = NSTextField(labelWithString: "")
    private let openHandler: (URL) -> Void
    private let onClose: (FolderWindowController) -> Void

    init(folderURL: URL, openHandler: @escaping (URL) -> Void, onClose: @escaping (FolderWindowController) -> Void) {
        self.folderURL = folderURL
        self.openHandler = openHandler
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = (folderURL.path as NSString).abbreviatingWithTildeInPath
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("")
        super.init(window: window)
        window.delegate = self
        window.center()
        build()
        tree.setRoot(path: folderURL.path)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    private func build() {
        guard let content = window?.contentView else { return }
        tree.onOpenFile = { [weak self] node in self?.openHandler(URL(fileURLWithPath: node.path)) }
        tree.onStatus = { [weak self] text in self?.statusLabel.stringValue = text }
        tree.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tree)
        NSLayoutConstraint.activate([
            tree.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            tree.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            tree.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tree.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        // 状態はツリー部品の下のラベルに出るので、この窓では二重に出さない
        statusLabel.isHidden = true
        window?.initialFirstResponder = nil
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        tree.focusFilter()
    }

    func windowWillClose(_ notification: Notification) { onClose(self) }
}
