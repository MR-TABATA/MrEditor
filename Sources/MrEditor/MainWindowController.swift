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
    private let structuredBanner = StructuredBanner()

    private let sidebar = SidebarView()
    private let viewerContainer = DropView()

    /// 読み取り専用バナーを当セッション中は二度と出さない（× で閉じられたら true）。
    private var readOnlyBannerDismissed = false

    /// 開いているファイル（1ファイル＝1ペイン。表示を切り替えるだけ）。
    private var viewers: [DocumentPane] = []
    private var activeIndex = -1

    /// 未保存の本文（draft）の置き場。**セッションとは別の器**で、消えたら戻せない本文だけを持つ。
    var draftStore: DraftStore = .shared

    /// 前回終了時のセッション。**生成時に読み込む**（起動時に開いたファイルが
    /// `persistSession` 経由で上書きする前に確保しておく必要がある）。
    private var pendingSession: SessionState? = AppSettings.session
    /// 復元を済ませたか。済むまでセッションを書き出さない（下の `persistSession` を参照）。
    private var didRestoreSession = false

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
        NotificationCenter.default.addObserver(self, selector: #selector(fontChanged),
                                               name: .mrEditorFontChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
                                               name: .mrEditorDisplayChanged, object: nil)
    }

    @objc private func lineWrapChanged() { viewers.forEach { $0.applyLineWrap() } }
    @objc private func fontChanged() { viewers.forEach { $0.applyCurrentFontSize() } }
    @objc private func displayChanged() {
        viewers.forEach { $0.applyDisplaySettings() }
        applyChrome()
    }

    /// 周辺 UI（タイトルバー・サイドバー・ステータス・検索パネル）へテーマを適用する。
    /// ダーク/ライト系テーマでは窓のアピアランスも合わせ、framework コントロール
    /// （検索フィールド・スクロールバー・タイトル文字・信号ボタン）の明暗を揃える。
    private func applyChrome() {
        let theme = EditorTheme.current()
        if let name = theme.appearanceName {
            window?.appearance = NSAppearance(named: name)
            window?.titlebarAppearsTransparent = true
            window?.backgroundColor = theme.chromeBackground
        } else {
            window?.appearance = nil
            window?.titlebarAppearsTransparent = false
            window?.backgroundColor = .windowBackgroundColor
        }
        sidebar.applyTheme()
        statusBar.applyTheme()
        searchBar.applyTheme()
    }

    /// 未保存変更でウィンドウを閉じる際の二重確認を抑止するフラグ。
    private var forceClose = false

    private func setupContent() {
        guard let content = window?.contentView else { return }
        content.translatesAutoresizingMaskIntoConstraints = true

        // サイドバー（開いているドキュメント一覧）
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.onSelect = { [weak self] i in self?.activate(i) }
        sidebar.onClose = { [weak self] i in self?.closeDocument(at: i) }

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

        // 構造化表示バナー（本文領域の左上・構造化中だけ表示。「元に戻す」で通常表示へ）
        structuredBanner.translatesAutoresizingMaskIntoConstraints = false
        structuredBanner.isHidden = true
        structuredBanner.onRevert = { [weak self] in self?.setActiveStructuredMode(nil) }
        content.addSubview(structuredBanner)
        NSLayoutConstraint.activate([
            // 右上に浮かべる（左のヘッダ列を隠さない。検索バーは構造化中に閉じるため競合しない）。
            structuredBanner.topAnchor.constraint(equalTo: viewerContainer.topAnchor, constant: 10),
            structuredBanner.trailingAnchor.constraint(equalTo: viewerContainer.trailingAnchor, constant: -28),
            structuredBanner.heightAnchor.constraint(equalToConstant: StructuredBanner.height),
        ])

        applyChrome()   // 永続化されたテーマを起動時に反映する。
    }

    // MARK: - ドキュメント管理

    /// ファイルを開く（既に開いていれば選択、なければ追加）。
    func open(url: URL) {
        OpenTiming.begin()      // MREDITOR_TIMING=1 のときだけ動く
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
        v.draftStore = draftStore
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
        sidebar.reload(names: viewers.map { displayName(of: $0) },
                       dirty: viewers.map { $0.isDirty },
                       active: activeIndex)
    }

    /// 開いているドキュメント一覧を永続化する（次回起動時に復元）。
    /// 保存済みはパス、未保存の新規は本文つきで残す（空の新規タブは対象外）。
    /// 保存/オープン/クローズ/切替、および終了直前に呼ぶ。
    ///
    /// **復元前は書かない。** 起動時に引数や Finder から開いたファイルも `activate` を通るため、
    /// 無条件に書くと、これから読むはずのセッション（未保存の新規の本文を含む）を潰してしまう。
    private func persistSession() {
        guard didRestoreSession else { return }
        let docs = viewers.map {
            (url: $0.fileURL, text: $0.restorableText, draftID: $0.draftID, dirty: $0.isDirty)
        }
        AppSettings.session = SessionState.make(docs: docs, activeIndex: activeIndex)
    }

    /// 開いている未保存の本文を今すぐ draft ファイルへ書き出す（終了直前・非アクティブ化時）。
    func flushDrafts() {
        viewers.forEach { $0.flushDraft() }
    }

    /// 前回終了時のドキュメント一覧を復元する（順序保持）。起動時に一度だけ呼ぶ。
    ///
    /// **セッションではなく draft ファイル（ディスク上の実体）を真実として読む。**
    /// セッションが無くても・壊れていても・起動時のオープンに上書きされていても、実在する
    /// 未保存の本文は必ず開き直す（`SessionState.restorePlan` が不変条件を持つ）。
    /// 保存済みファイルの一覧はセッションが持つが、これは失っても作り直せる情報。
    func restoreSession() {
        guard !didRestoreSession else { return }
        defer {
            // ここから先は通常どおり永続化する。抑止していた起動時の状態もここで書き出す。
            didRestoreSession = true
            persistSession()
        }

        // 旧版（〜1.0.1）はセッションに本文を直接入れていた。更新で取りこぼさないよう draft へ移す。
        let session = pendingSession.map { draftStore.migratingLegacyText(in: $0) }

        // 起動時に開いたファイル（引数 / Finder）。復元分はこの後ろに積む。
        let launchOpened = viewers.count
        let plan = SessionState.restorePlan(session: session,
                                            draftIDs: draftStore.allIDs(),
                                            hasOpenDocuments: launchOpened > 0)
        guard !plan.items.isEmpty else { return }

        let fm = FileManager.default
        for item in plan.items {
            switch item {
            case .file(let path):
                if fm.fileExists(atPath: path) { open(url: URL(fileURLWithPath: path)) }
            case .draft(let id, let dirty):
                guard let text = draftStore.read(id: id) else { continue }
                restoreDraft(id: id, text: text, dirty: dirty)
            }
        }
        if launchOpened > 0 {
            activate(launchOpened - 1)   // 起動時に開いたファイルをアクティブのままにする
        } else if plan.activeIndex >= 0, !viewers.isEmpty {
            // 欠損ファイルのスキップで位置がずれうるため範囲内にクランプ。
            activate(min(plan.activeIndex, viewers.count - 1))
        }
        // 復元直後のアクティブペインを確実に初回描画させる。
        activeViewer?.needsDisplay = true
        window?.displayIfNeeded()
    }

    /// 未保存の新規ドキュメントを draft の本文つきで復元してサイドバーに追加する。
    private func restoreDraft(id: String, text: String, dirty: Bool) {
        let v = EditableViewer()
        v.draftStore = draftStore
        install(v)
        v.restoreDraft(id: id, text: text, dirty: dirty)
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)   // activate 内で persistSession
    }

    /// サイドバー／タイトル用の表示名（未保存の新規ドキュメントは「名称未設定」）。
    private func displayName(of v: DocumentPane) -> String {
        if let d = v as? DiffViewer { return d.displayTitle }   // diff は 1 ファイルに属さない
        return v.fileURL?.lastPathComponent ?? L("doc.untitled")
    }

    // MARK: - diff（3 つの入口とも、ここに集まる）

    /// アクティブなペインが diff なら、それ（「次/前の差分へ」のメニュー用）。
    var activeDiffViewer: DiffViewer? { activeViewer as? DiffViewer }


    /// 比較タブを開く。ソースの用意（mmap・索引）と diff は背景で走る。
    /// `makeSources` は**背景スレッドで呼ばれる**（ここでメインを止めると 10GB で固まる）。
    func openDiff(title: String, makeSources: @escaping () -> (DiffSource, DiffSource)?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let v = DiffViewer()
        install(v)
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)

        v.onCompared = { [weak self] in self?.reloadSidebar() }
        v.beginCompare(title: title, makeSources: makeSources, onFailure: { [weak self, weak v] message in
            guard let self, let v, let i = self.viewers.firstIndex(where: { $0 === v }) else { return }
            self.closeDocument(at: i)
            let alert = NSAlert()
            alert.messageText = L("diff.failedTitle")
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        })
    }

    /// 入口 1: 2 つのファイルを選んで比べる。
    ///
    /// **1 つのパネルで 2 つ選ばせない。** 最初はそうしていたが、普通は「1 つ選んで開く」と
    /// 操作するので、⌘クリックで 2 つ選ばなかった人には**何も起きなかった**（黙って閉じるだけ）。
    /// 1 つ目 → 2 つ目、と順に訊く。まとめて 2 つ選んだ人はそのまま通す。
    func compareFiles() {
        let first = NSOpenPanel()
        first.message = L("diff.chooseFirst")
        first.prompt = L("diff.chooseNext")
        first.allowsMultipleSelection = true      // 2 つまとめて選ぶ人も通す
        first.canChooseDirectories = false
        guard first.runModal() == .OK, !first.urls.isEmpty else { return }

        var urls = first.urls
        if urls.count == 1 {
            let second = NSOpenPanel()
            second.message = L("diff.chooseSecond", urls[0].lastPathComponent)
            second.prompt = L("diff.compare")
            second.allowsMultipleSelection = false
            second.canChooseDirectories = false
            second.directoryURL = urls[0].deletingLastPathComponent()   // 同じ場所から始める
            guard second.runModal() == .OK, let u = second.urls.first else { return }
            urls.append(u)
        }

        let pick = Array(urls.prefix(2))
        let title = "\(pick[0].lastPathComponent) ↔ \(pick[1].lastPathComponent)"
        openDiff(title: title) {
            guard let l = FileDiffSource(url: pick[0]), let r = FileDiffSource(url: pick[1]) else { return nil }
            return (l, r)
        }
    }

    /// 入口 2: 開いているタブ 2 つ（アクティブと、その 1 つ前）を比べる。
    /// 未保存のタブも本文で比べられる（ディスク上のファイルでなく、いま見えているものを比べる）。
    func compareOpenDocuments() {
        let comparable = viewers.enumerated().filter { !($0.element is DiffViewer) }
        guard comparable.count >= 2 else { NSSound.beep(); return }
        let pick = comparable.suffix(2).map { $0.element }
        // 未保存の本文はメインスレッドで先に取る（ペインの状態はメインでしか触れない）。
        let recipes = pick.map { diffRecipe(for: $0) }
        let title = "\(displayName(of: pick[0])) ↔ \(displayName(of: pick[1]))"
        openDiff(title: title) {
            guard let l = recipes[0].makeSource(), let r = recipes[1].makeSource() else { return nil }
            return (l, r)
        }
    }

    /// 入口 3: クリップボードの中身と、いま開いているドキュメントを比べる。
    func compareWithClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep(); return
        }
        let clipName = L("diff.clipboard")
        guard let active = activeViewer, !(active is DiffViewer) else {
            openDiff(title: clipName) {
                (TextDiffSource(text: "", displayName: L("doc.untitled")),
                 TextDiffSource(text: text, displayName: clipName))
            }
            return
        }
        let recipe = diffRecipe(for: active)
        let title = "\(displayName(of: active)) ↔ \(clipName)"
        openDiff(title: title) {
            guard let l = recipe.makeSource() else { return nil }
            return (l, TextDiffSource(text: text, displayName: clipName))
        }
    }

    /// ペインを diff の入力にする「作り方」。**ペインの状態はメインで読み取り**、
    /// 実際の mmap と索引の構築（重い）は背景で走らせる。
    private struct DiffRecipe {
        let makeSource: () -> DiffSource?
    }

    /// 保存済みならファイルを mmap、未保存なら本文をそのまま比べる（いま見えているものを比べる）。
    private func diffRecipe(for pane: DocumentPane) -> DiffRecipe {
        let name = displayName(of: pane)
        if let text = pane.restorableText, pane.isDirty || pane.fileURL == nil {
            return DiffRecipe { TextDiffSource(text: text, displayName: name) }
        }
        if let url = pane.fileURL {
            return DiffRecipe { FileDiffSource(url: url) }
        }
        return DiffRecipe { nil }
    }

    // MARK: - アクティブなドキュメントの能力（メニュー検証用）

    /// 編集・保存できるドキュメントが開いているか。
    var canSave: Bool { activeViewer?.canEdit ?? false }
    /// 保存済みへ戻せるか（編集可能で未保存の変更があり、ファイルが確定している）。
    var canRevert: Bool {
        guard let v = activeViewer else { return false }
        return v.canEdit && v.isDirty && v.fileURL != nil
    }
    /// 検索できるドキュメントが開いているか。
    /// 印刷（＝PDF 出力）できるドキュメントが開いているか。巨大ファイルは不可。
    var canPrint: Bool { activeViewer?.canPrint ?? false }

    /// アクティブなドキュメントを印刷する（プリントダイアログから PDF 保存も可能）。
    func printActiveDocument() {
        guard let v = activeViewer, v.canPrint else { NSSound.beep(); return }
        v.printDocument()
    }

    var canSearch: Bool { activeViewer?.supportsSearch ?? false }
    /// 末尾追従できるドキュメントが開いているか。
    var canFollow: Bool { activeViewer?.supportsFollow ?? false }
    /// 何かドキュメントが開いているか。
    var hasActiveDocument: Bool { activeIndex >= 0 }
    /// アクティブなドキュメントが末尾追従中か。
    var isFollowingActive: Bool { activeViewer?.isFollowing ?? false }
    /// 構造化表示できるか（View メニューの有効化）。
    var canStructured: Bool { activeViewer?.supportsStructured ?? false }
    /// アクティブなドキュメントの構造化表示モード（メニューのチェック用）。
    var activeStructuredMode: StructuredMode? { activeViewer?.structuredMode }
    /// アクティブなドキュメントの構造化表示モードを設定する。
    func setActiveStructuredMode(_ mode: StructuredMode?) {
        guard let v = activeViewer, v.supportsStructured else { NSSound.beep(); return }
        v.setStructuredMode(mode)
        if mode != nil, !searchBar.isHidden { hideSearch() }   // 構造化中は検索を閉じる
        updateStructuredBanner()
        updateReadOnlyBanner()
    }

    /// 構造化表示バナーの表示可否を更新する（構造化中だけ出す）。
    private func updateStructuredBanner() {
        if let mode = activeStructuredMode {
            structuredBanner.configure(mode: mode)
            structuredBanner.isHidden = false
        } else {
            structuredBanner.isHidden = true
        }
    }

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
            guard let self, let v else { return }
            // どのペインの未保存状態でもサイドバーの目印を更新する。
            if let idx = self.viewers.firstIndex(where: { $0 === v }) {
                self.sidebar.setDirty(idx, dirty)
            }
            // タイトルバーの編集済みドットはアクティブなペインのみ反映。
            if self.activeViewer === v { self.window?.isDocumentEdited = dirty }
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
        v.ensureVisibleLayout()                    // 非表示中に差し込んだ本文を確実に描画
        v.reEmitState()                            // ステータスバーを現在の状態に更新
        sidebar.setActive(index)
        window?.title = displayName(of: v) + " — " + AppInfo.name
        updateEditedState()
        updateStructuredBanner()
        updateReadOnlyBanner()
        v.focusContent()
        persistSession()
    }

    /// 読み取り専用バナーの表示可否を更新する（編集不可のペイン＝LargeFileViewer のときだけ出す）。
    private func updateReadOnlyBanner() {
        // 構造化表示による読み取り専用は専用バナーで案内するため除外する。
        // diff も除外する（「大きすぎて編集できません」は嘘。そもそも編集する画面ではない）。
        let isReadOnly = activeViewer != nil && !(activeViewer?.canEdit ?? false)
            && activeViewer?.structuredMode == nil
            && !(activeViewer is DiffViewer)
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

    /// 指定インデックスのドキュメントを閉じる（サイドバーの × から）。未保存なら確認する。
    func closeDocument(at index: Int) {
        guard index >= 0, index < viewers.count else { return }
        let pane = viewers[index]
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
        // ドキュメントを閉じるのはユーザーの明示的な操作。ここが draft を消してよい 2 経路の
        // もう 1 つ（保存に成功したときはペイン側で消える）。閉じずに終了した draft は残る。
        pane.discardDraft()
        let v = viewers.remove(at: idx)
        v.removeFromSuperview()
        if viewers.isEmpty {
            activeIndex = -1
            reloadSidebar()
            window?.title = AppInfo.name
            statusBar.setPlaceholder()
            updateEditedState()
            updateReadOnlyBanner()
            persistSession()
        } else {
            activeIndex = min(idx, viewers.count - 1)
            reloadSidebar()
            activate(activeIndex)   // activate 内で persistSession
        }
    }

    /// アクティブなドキュメントをディスクの保存済み内容へ戻す（未保存の変更を破棄）。
    func revertActiveDocument() {
        guard activeIndex >= 0 else { return }
        let pane = viewers[activeIndex]
        guard pane.canEdit, pane.isDirty, let url = pane.fileURL, let win = window else { return }
        let alert = NSAlert()
        alert.messageText = L("revert.confirmTitle", displayName(of: pane))
        alert.informativeText = L("revert.confirmMessage")
        alert.addButton(withTitle: L("revert.confirm"))    // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))     // .alertSecondButtonReturn
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            guard let idx = self.viewers.firstIndex(where: { $0 === pane }) else { return }
            _ = pane.open(url: url)          // 再読込（dirty=false・状態リセット）
            self.reloadSidebar()
            self.activate(idx)               // タイトル／ステータス／編集ドットを更新
        }
    }

    /// アクティブなドキュメントのバッファ文字コード（「開き直す」メニューのチェック表示用）。
    var activeEncoding: DetectedEncoding? { activeViewer?.currentEncoding }
    /// アクティブなドキュメントの保存エンコード（「テキストエンコーディング」メニューのチェック表示用）。
    var activeSaveEncoding: DetectedEncoding? { activeViewer?.currentSaveEncoding }
    /// エンコード指定で開き直せるか（ファイルが確定している）。
    var canReopenWithEncoding: Bool { (activeViewer?.fileURL) != nil }

    /// アクティブなドキュメントを指定エンコードで開き直す（自動判定ミスの文字化けを直す）。
    /// 未保存の変更があれば確認する（開き直すと編集は破棄される）。
    func reopenActiveDocument(withEncoding enc: DetectedEncoding) {
        guard activeIndex >= 0 else { return }
        let pane = viewers[activeIndex]
        guard pane.fileURL != nil, enc != pane.currentEncoding else { return }

        let apply: () -> Void = { [weak self] in
            guard let self, let idx = self.viewers.firstIndex(where: { $0 === pane }) else { return }
            _ = pane.reopen(withEncoding: enc)
            self.reloadSidebar()
            self.activate(idx)
        }
        guard pane.isDirty, let win = window else { apply(); return }
        let alert = NSAlert()
        alert.messageText = L("reopen.confirmTitle", displayName(of: pane))
        alert.informativeText = L("reopen.confirmMessage")
        alert.addButton(withTitle: L("reopen.confirm"))    // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))     // .alertSecondButtonReturn
        alert.beginSheetModal(for: win) { resp in
            if resp == .alertFirstButtonReturn { apply() }
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

    /// アクティブなドキュメントの「保存時のエンコード」を設定する（まだ書き出さない）。
    /// dirty になり、実際の変換書き出しは次の保存（⌘S）で進捗表示付きで行われる。
    func setActiveSaveEncoding(to enc: DetectedEncoding) {
        guard let v = activeViewer, v.canEdit, enc != v.currentSaveEncoding else { NSSound.beep(); return }
        v.setSaveEncoding(enc)
        updateEditedState()
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
        persistSession()   // 保存で URL が確定/変更されうるため一覧を更新
    }

    // MARK: - NSWindowDelegate

    /// ウィンドウを閉じる前に未保存のドキュメントを確認する。
    /// 未保存の新規（URL 未確定）はセッション復元で残るため確認せず、保存済みファイルの
    /// 未保存編集だけを確認する。閉じる直前に最新の本文をセッションへ書き出す。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if forceClose { return true }
        flushDrafts()      // 未保存の本文をディスクへ（デバウンス待ちの分を取りこぼさない）
        persistSession()
        let dirty = viewers.filter { $0.isDirty && $0.fileURL != nil }
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
    /// 未保存の新規はセッション復元で残るため確認しない。終了直前に最新の本文を書き出す。
    func confirmTerminate() -> Bool {
        flushDrafts()      // 未保存の本文をディスクへ（デバウンス待ちの分を取りこぼさない）
        persistSession()
        let dirty = viewers.filter { $0.isDirty && $0.fileURL != nil }
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
        // setSize が .mrEditorFontChanged を投げ、全ウィンドウが applyCurrentFontSize で反映する。
        EditorFont.setSize(size)
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
            // 全角数字（日本語入力ON）とカンマ区切りを受ける。詳細は LineNumberInput。
            if resp == .alertFirstButtonReturn, let n = LineNumberInput.parse(field.stringValue) {
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
