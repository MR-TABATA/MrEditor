import AppKit

/// ファイルをドロップで受けるコンテナ（ドキュメント未選択時の空き領域用）。
final class DropView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}

/// メインウィンドウ。左に開いているドキュメントの縦リスト、右に本文＋ステータスバー。
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let statusBar = StatusBarView()
    private let searchBar = SearchBarView()
    private let readOnlyBanner = ReadOnlyBanner()

    private let sidebar = SidebarView()
    private let viewerContainer = DropView()

    /// 読み取り専用バナーを当セッション中は二度と出さない（× で閉じられたら true）。
    private var readOnlyBannerDismissed = false

    /// 開いているファイル（1ファイル＝1ペイン。表示を切り替えるだけ）。
    private var viewers: [DocumentPane] = []
    private var activeIndex = -1
    private var activeViewer: DocumentPane? {
        (activeIndex >= 0 && activeIndex < viewers.count) ? viewers[activeIndex] : nil
    }

    private let sidebarWidth: CGFloat = 200

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.center()
        window.setFrameAutosaveName("MrEditorMainWindow")
        window.tabbingMode = .disallowed
        self.init(window: window)
        window.delegate = self
        setupContent()
        NotificationCenter.default.addObserver(self, selector: #selector(lineWrapChanged),
                                               name: .mrEditorLineWrapChanged, object: nil)
    }

    @objc private func lineWrapChanged() { viewers.forEach { $0.applyLineWrap() } }

    /// 未保存変更でウィンドウを閉じる際の二重確認を抑止するフラグ。
    private var forceClose = false

    private func setupContent() {
        guard let content = window?.contentView else { return }
        content.translatesAutoresizingMaskIntoConstraints = true

        // サイドバー（開いているドキュメント一覧）
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.onSelect = { [weak self] i in self?.activate(i) }

        viewerContainer.translatesAutoresizingMaskIntoConstraints = false
        viewerContainer.onDropFiles = { [weak self] urls in urls.forEach { self?.open(url: $0) } }
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(viewerContainer)
        content.addSubview(statusBar)
        content.addSubview(sidebar)   // サイドバーを前面側に（合成不具合回避の試行）

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth),

            viewerContainer.topAnchor.constraint(equalTo: content.topAnchor),
            viewerContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            viewerContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            viewerContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height),
        ])

        // 検索バー（本文領域の右上に浮かべる。初期は非表示）
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = true
        content.addSubview(searchBar)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: viewerContainer.topAnchor, constant: 10),
            searchBar.trailingAnchor.constraint(equalTo: viewerContainer.trailingAnchor, constant: -28),
            searchBar.widthAnchor.constraint(equalToConstant: 440),
            searchBar.heightAnchor.constraint(equalToConstant: SearchBarView.height),
        ])
        searchBar.onQueryChange = { [weak self] q in self?.activeViewer?.setSearchQuery(q) }
        searchBar.onNext = { [weak self] in self?.activeViewer?.findNext() }
        searchBar.onPrev = { [weak self] in self?.activeViewer?.findPrev() }
        searchBar.onClose = { [weak self] in self?.hideSearch() }
        searchBar.onCaseToggle = { [weak self] on in self?.activeViewer?.setCaseSensitive(on) }
        searchBar.onRegexToggle = { [weak self] on in self?.activeViewer?.setRegexMode(on) }
        searchBar.onFilterToggle = { [weak self] on in self?.activeViewer?.setFilterMode(on) }
        searchBar.onReplace = { [weak self] r in self?.activeViewer?.replaceCurrent(with: r) }
        searchBar.onReplaceAll = { [weak self] r in self?.activeViewer?.replaceAll(with: r) }

        // 読み取り専用バナー（本文領域の左上に浮かべる。大ファイルを開いたときだけ表示）
        readOnlyBanner.translatesAutoresizingMaskIntoConstraints = false
        readOnlyBanner.isHidden = true
        readOnlyBanner.onClose = { [weak self] in
            self?.readOnlyBannerDismissed = true
            self?.readOnlyBanner.isHidden = true
        }
        content.addSubview(readOnlyBanner)
        NSLayoutConstraint.activate([
            readOnlyBanner.topAnchor.constraint(equalTo: viewerContainer.topAnchor, constant: 10),
            readOnlyBanner.leadingAnchor.constraint(equalTo: viewerContainer.leadingAnchor, constant: 14),
            readOnlyBanner.heightAnchor.constraint(equalToConstant: ReadOnlyBanner.height),
        ])
    }

    // MARK: - ドキュメント管理

    /// ファイルを開く（既に開いていれば選択、なければ追加）。
    func open(url: URL) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)

        if let i = viewers.firstIndex(where: { $0.fileURL == url }) {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            activate(i); return
        }

        let v = makePane(for: url)
        install(v)
        guard v.open(url: url) else { v.removeFromSuperview(); return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)
    }

    /// 空の新規ドキュメントを作って開く（パスは保存時に確定）。
    func newDocument() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let v = EditableViewer()
        install(v)
        v.newDocument()
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)
    }

    /// ペインを本文領域に敷き詰めて配置し、ハンドラを繋ぐ（初期は非表示）。
    private func install(_ v: DocumentPane) {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        wire(v)
        viewerContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: viewerContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: viewerContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: viewerContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: viewerContainer.bottomAnchor),
        ])
    }

    /// ファイルサイズで開くペインを決める（小＝NSTextView 編集、大＝piece table 編集ビューア）。
    private func makePane(for url: URL) -> DocumentPane {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let size, size <= EditableViewer.sizeThreshold {
            return EditableViewer()
        }
        // 大ファイルは piece table バックの編集ビューア（mmap + 索引 + 検索/追従 + その場編集/保存）。
        return PieceTableViewer()
    }

    private func reloadSidebar() {
        sidebar.reload(names: viewers.map { displayName(of: $0) }, active: activeIndex)
    }

    /// サイドバー／タイトル用の表示名（未保存の新規ドキュメントは「名称未設定」）。
    private func displayName(of v: DocumentPane) -> String {
        v.fileURL?.lastPathComponent ?? L("doc.untitled")
    }

    // MARK: - アクティブなドキュメントの能力（メニュー検証用）

    /// 編集・保存できるドキュメントが開いているか。
    var canSave: Bool { activeViewer?.canEdit ?? false }
    /// 検索できるドキュメントが開いているか。
    var canSearch: Bool { activeViewer?.supportsSearch ?? false }
    /// 末尾追従できるドキュメントが開いているか。
    var canFollow: Bool { activeViewer?.supportsFollow ?? false }
    /// 何かドキュメントが開いているか。
    var hasActiveDocument: Bool { activeIndex >= 0 }
    /// アクティブなドキュメントが末尾追従中か。
    var isFollowingActive: Bool { activeViewer?.isFollowing ?? false }

    /// 各ビューアにステータス/検索/ドロップのハンドラを繋ぐ（アクティブな時だけ反映）。
    private func wire(_ v: DocumentPane) {
        v.onStateChange = { [weak self, weak v] state in
            guard let self, self.activeViewer === v else { return }
            self.statusBar.update(state)
        }
        v.onSearchState = { [weak self, weak v] cur, tot, searching, prog, invalid in
            guard let self, self.activeViewer === v else { return }
            self.searchBar.setCount(current: cur, total: tot, searching: searching, progress: prog, invalid: invalid)
        }
        v.onDropFiles = { [weak self] urls in urls.forEach { self?.open(url: $0) } }
        v.onDirtyChange = { [weak self, weak v] dirty in
            guard let self, self.activeViewer === v else { return }
            self.window?.isDocumentEdited = dirty
        }
    }

    /// タイトルバーの編集済みドット（active なペインの未保存状態を反映）。
    private func updateEditedState() {
        window?.isDocumentEdited = activeViewer?.isDirty ?? false
    }

    /// 指定インデックスのドキュメントをアクティブにする。
    private func activate(_ index: Int) {
        guard index >= 0, index < viewers.count else { return }
        if !searchBar.isHidden { hideSearch() }   // 切替時は検索を閉じる
        for (i, v) in viewers.enumerated() { v.isHidden = (i != index) }
        activeIndex = index
        let v = viewers[index]
        v.reEmitState()                            // ステータスバーを現在の状態に更新
        sidebar.setActive(index)
        window?.title = displayName(of: v) + " — " + AppInfo.name
        updateEditedState()
        updateReadOnlyBanner()
        v.focusContent()
    }

    /// 読み取り専用バナーの表示可否を更新する（編集不可のペイン＝LargeFileViewer のときだけ出す）。
    private func updateReadOnlyBanner() {
        let isReadOnly = activeViewer != nil && !(activeViewer?.canEdit ?? false)
        readOnlyBanner.isHidden = !(isReadOnly && !readOnlyBannerDismissed)
    }

    /// アクティブなドキュメントを閉じる（なければウィンドウを閉じる）。未保存なら確認する。
    func closeActiveDocument() {
        guard activeIndex >= 0 else { window?.performClose(nil); return }
        let pane = viewers[activeIndex]
        confirmClose(pane) { [weak self] proceed in
            guard let self, proceed else { return }
            self.removePane(pane)
        }
    }

    /// 未保存なら確認シートを出し、閉じてよいか（保存/破棄=true、キャンセル=false）を返す。
    private func confirmClose(_ pane: DocumentPane, _ completion: @escaping (Bool) -> Void) {
        guard pane.isDirty, let win = window else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = L("close.unsavedTitle", displayName(of: pane))
        alert.informativeText = L("close.unsavedMessage")
        alert.addButton(withTitle: L("common.save"))       // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))     // .alertSecondButtonReturn
        alert.addButton(withTitle: L("common.dontSave"))   // .alertThirdButtonReturn
        alert.beginSheetModal(for: win) { resp in
            switch resp {
            case .alertFirstButtonReturn: completion(pane.save())
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }

    /// ペインを実際に閉じる（確認済み前提）。
    private func removePane(_ pane: DocumentPane) {
        guard let idx = viewers.firstIndex(where: { $0 === pane }) else { return }
        if !searchBar.isHidden { hideSearch() }
        let v = viewers.remove(at: idx)
        v.removeFromSuperview()
        if viewers.isEmpty {
            activeIndex = -1
            reloadSidebar()
            window?.title = AppInfo.name
            statusBar.setPlaceholder()
            updateEditedState()
            updateReadOnlyBanner()
        } else {
            activeIndex = min(idx, viewers.count - 1)
            reloadSidebar()
            activate(activeIndex)
        }
    }

    // MARK: - 保存

    func saveActiveDocument() { performSave(saveAs: false) }
    func saveActiveDocumentAs() { performSave(saveAs: true) }

    /// 保存を実行する。巨大ファイル（PieceTableViewer）は非同期＋進捗表示で UI を固めない。
    /// 小ファイル（EditableViewer）は即時なので従来どおり同期保存。
    private func performSave(saveAs: Bool) {
        guard let v = activeViewer, v.canEdit else { NSSound.beep(); return }
        if let pt = v as? PieceTableViewer {
            let style = AppSettings.saveProgressStyle
            savingPane = pt
            pt.saveAsync(
                saveAs: saveAs,
                onBegin: { [weak self] in self?.beginSaveUI(style) },
                progress: { [weak self] f in self?.updateSaveUI(style, f) },
                completion: { [weak self] ok in
                    self?.savingPane = nil
                    self?.endSaveUI(style)
                    if ok { self?.afterSave(pt) }
                })
        } else {
            if (saveAs ? v.saveAs() : v.save()) { afterSave(v) }
        }
    }

    // MARK: - 保存中の進捗 UI（A: ステータスバー / B: シート・config で切替。キャンセル可）

    private var savePresenting = false
    private var saveSheet: NSPanel?
    private var saveProgress: NSProgressIndicator?
    private var saveSheetLabel: NSTextField?
    /// 保存中のペイン（キャンセルの委譲先）。
    private weak var savingPane: PieceTableViewer?

    /// 実行中の保存をキャンセルする（進捗 UI のキャンセルボタンから）。
    @objc private func cancelActiveSave() { savingPane?.cancelSave() }

    private func beginSaveUI(_ style: SaveProgressStyle) {
        savePresenting = true
        switch style {
        case .statusBar:
            statusBar.showSaving(L("status.saving", 0), onCancel: { [weak self] in self?.cancelActiveSave() })
        case .sheet:
            presentSaveSheet()
        }
    }

    private func updateSaveUI(_ style: SaveProgressStyle, _ fraction: Double) {
        let pct = Int((fraction * 100).rounded())
        switch style {
        case .statusBar: statusBar.updateSaving(L("status.saving", pct))
        case .sheet:
            saveProgress?.doubleValue = Double(pct)
            saveSheetLabel?.stringValue = L("status.saving", pct)
        }
    }

    private func endSaveUI(_ style: SaveProgressStyle) {
        guard savePresenting else { return }
        savePresenting = false
        switch style {
        case .statusBar:
            statusBar.clearMessage()
            activeViewer?.reEmitState()
        case .sheet:
            if let sheet = saveSheet { window?.endSheet(sheet) }
            saveSheet = nil; saveProgress = nil; saveSheetLabel = nil
        }
    }

    /// モーダルの保存中シート（進捗バー＋ラベル＋キャンセル）を出す。
    private func presentSaveSheet() {
        guard let window else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 132),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = L("save.sheetTitle")
        guard let content = panel.contentView else { return }

        let label = NSTextField(labelWithString: L("status.saving", 0))
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 100; bar.doubleValue = 0
        let cancel = NSButton(title: L("common.cancel"), target: self, action: #selector(cancelActiveSave))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"   // Escape でキャンセル
        for v in [label, bar, cancel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 14),

            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 16),
        ])
        saveSheet = panel; saveProgress = bar; saveSheetLabel = label
        window.beginSheet(panel, completionHandler: nil)
    }

    /// 保存後の UI 更新（保存先変更でファイル名が変わりうる）。
    private func afterSave(_ v: DocumentPane) {
        if let url = v.fileURL { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        reloadSidebar()
        if activeViewer === v {
            window?.title = displayName(of: v) + " — " + AppInfo.name
        }
        updateEditedState()
    }

    // MARK: - NSWindowDelegate

    /// ウィンドウを閉じる前に未保存のドキュメントを確認する。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if forceClose { return true }
        let dirty = viewers.filter { $0.isDirty }
        if dirty.isEmpty { return true }
        let alert = NSAlert()
        alert.messageText = L("close.unsavedAllTitle", dirty.count)
        alert.informativeText = L("close.unsavedMessage")
        alert.addButton(withTitle: L("common.saveAll"))    // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))     // .alertSecondButtonReturn
        alert.addButton(withTitle: L("common.discard"))    // .alertThirdButtonReturn
        alert.beginSheetModal(for: sender) { [weak self] resp in
            guard let self else { return }
            switch resp {
            case .alertFirstButtonReturn:
                if dirty.allSatisfy({ $0.save() }) { self.forceClose = true; sender.close() }
            case .alertThirdButtonReturn:
                self.forceClose = true; sender.close()
            default: break
            }
        }
        return false
    }

    /// アプリ終了前の未保存確認（同期）。終了してよければ true。
    func confirmTerminate() -> Bool {
        let dirty = viewers.filter { $0.isDirty }
        if dirty.isEmpty { return true }
        let alert = NSAlert()
        alert.messageText = L("close.unsavedAllTitle", dirty.count)
        alert.informativeText = L("close.unsavedMessage")
        alert.addButton(withTitle: L("common.saveAll"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.addButton(withTitle: L("common.discard"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return dirty.allSatisfy { $0.save() }
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: - 検索 / 追従（アクティブなビューアへ委譲）

    @discardableResult
    func toggleFollow() -> Bool {
        guard let v = activeViewer, v.supportsFollow else { NSSound.beep(); return false }
        v.setFollowMode(!v.isFollowing)
        return v.isFollowing
    }

    func findNext() { activeViewer?.findNext() }
    func findPrev() { activeViewer?.findPrev() }

    // MARK: - フォント拡大縮小（全ドキュメント共通）

    func zoomIn()    { applyFontSize(EditorFont.currentSize + 1) }
    func zoomOut()   { applyFontSize(EditorFont.currentSize - 1) }
    func zoomReset() { applyFontSize(EditorFont.defaultSize) }

    private func applyFontSize(_ size: CGFloat) {
        EditorFont.setSize(size)
        viewers.forEach { $0.applyCurrentFontSize() }
    }

    /// 行番号ジャンプのダイアログ。
    func promptGoToLine() {
        guard let v = activeViewer, let win = window else { return }
        let alert = NSAlert()
        alert.messageText = L("gotoLine.prompt")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("gotoLine.go"))
        alert.addButton(withTitle: L("common.cancel"))
        // シート表示直後に入力欄へフォーカスを当てる（beginSheetModal 後の
        // makeFirstResponder はシートでは安定して効かないため initialFirstResponder を使う）。
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { resp in
            if resp == .alertFirstButtonReturn, let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) {
                v.goToLine(n)
            }
        }
    }

    func showSearch() {
        guard let v = activeViewer, v.supportsSearch else { NSSound.beep(); return }
        searchBar.isHidden = false
        searchBar.focusField()
    }

    func hideSearch() {
        searchBar.isHidden = true
        if let v = activeViewer {
            v.setFilterMode(false)
            v.setRegexMode(false)
            v.setCaseSensitive(false)
            v.setSearchQuery("")
            v.focusContent()
        }
        searchBar.clear()
    }

    // MARK: - 開く

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            if response == .OK { panel.urls.forEach { self?.open(url: $0) } }
        }
    }
}
