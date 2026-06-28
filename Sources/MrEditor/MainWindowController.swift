import AppKit

/// メインウィンドウ。ビューアとステータスバーを縦に並べる。
final class MainWindowController: NSWindowController {
    private let viewer = LargeFileViewer()
    private let statusBar = StatusBarView()
    private let searchBar = SearchBarView()

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

        // 検索バー（ビューア右上に浮かべる。初期は非表示）
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = true
        content.addSubview(searchBar)  // 最前面（viewer/statusBar より後に追加）
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: viewer.topAnchor, constant: 10),
            searchBar.trailingAnchor.constraint(equalTo: viewer.trailingAnchor, constant: -28),
            searchBar.widthAnchor.constraint(equalToConstant: 360),
            searchBar.heightAnchor.constraint(equalToConstant: SearchBarView.height),
        ])
        searchBar.onQueryChange = { [weak self] q in self?.viewer.setSearchQuery(q) }
        searchBar.onNext = { [weak self] in self?.viewer.findNext() }
        searchBar.onPrev = { [weak self] in self?.viewer.findPrev() }
        searchBar.onClose = { [weak self] in self?.hideSearch() }
        searchBar.onRegexToggle = { [weak self] on in self?.viewer.setRegexMode(on) }
        searchBar.onFilterToggle = { [weak self] on in self?.viewer.setFilterMode(on) }
        viewer.onSearchState = { [weak self] cur, tot, searching, prog, invalid in
            self?.searchBar.setCount(current: cur, total: tot, searching: searching, progress: prog, invalid: invalid)
        }
    }

    /// 末尾追従（tail -f）を切替え、結果の状態を返す。
    @discardableResult
    func toggleFollow() -> Bool {
        viewer.setFollowMode(!viewer.isFollowing)
        return viewer.isFollowing
    }

    /// 検索バーを表示してフォーカス。
    func showSearch() {
        searchBar.isHidden = false
        searchBar.focusField()
    }

    /// 検索バーを閉じ、フィルタ/強調を解除して本文へフォーカスを戻す。
    func hideSearch() {
        searchBar.isHidden = true
        viewer.setFilterMode(false)     // フィルタ解除（見ていた行へ戻す）
        viewer.setRegexMode(false)
        viewer.setSearchQuery("")       // 強調クリア
        searchBar.clear()
        viewer.focusContent()
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
