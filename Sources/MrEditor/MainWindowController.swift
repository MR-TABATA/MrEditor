import AppKit

/// メインウィンドウ。ビューアとステータスバーを縦に並べる。
final class MainWindowController: NSWindowController {
    private let viewer = LargeFileViewer()
    private let statusBar = StatusBarView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.center()
        window.setFrameAutosaveName("MrEditorMainWindow")
        window.tabbingMode = .disallowed
        self.init(window: window)
        setupContent()
    }

    private func setupContent() {
        guard let content = window?.contentView else { return }
        content.translatesAutoresizingMaskIntoConstraints = true

        viewer.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(viewer)
        content.addSubview(statusBar)

        NSLayoutConstraint.activate([
            viewer.topAnchor.constraint(equalTo: content.topAnchor),
            viewer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            viewer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height),
        ])

        viewer.onStateChange = { [weak self] state in
            self?.statusBar.update(state)
        }
    }

    /// ファイルを開く。
    func open(url: URL) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        viewer.open(url: url)
    }

    /// NSOpenPanel でファイルを選んで開く。
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.open(url: url)
            }
        }
    }
}
