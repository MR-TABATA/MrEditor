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
public final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let statusBar = StatusBarView()
    private let searchBar = SearchBarView()
    private let aiResultPanel = AIResultPanel()
    /// AI パネルを載せるフローティングウィンドウ（初回表示時に生成）。
    private var aiPanelWindow: AIPanelWindow?
    /// 進行中の AI ストリーム（解析し直し・パネルを閉じたときに捨てる）。
    private var aiStream: AIStreamHandle?
    private let readOnlyBanner = ReadOnlyBanner()
    private let structuredBanner = StructuredBanner()
    private let externalBanner = ExternalChangeBanner()

    // MARK: - 外部変更の取り込み
    //
    // 開いているファイルが他のアプリで書き換わったら、未保存でなければ黙って読み込み直す。
    // 潰せない状態（未保存・整形/絞り込み中）と、自動読み込みをオフにしている場合は
    // バナーで知らせるだけにする。**古い内容を黙って見せ続けることはしない**のが約束。

    private let externalWatcher = ExternalChangeWatcher()
    /// 外部で変わったが、まだ取り込んでいないペイン（バナーを出す対象）。
    private var externallyChangedPanes = Set<ObjectIdentifier>()
    /// 「読み込みました」の一時メッセージを消すタイマー。
    private var externalMessageTimer: Timer?

    private let sidebar = SidebarView()
    private let viewerContainer = DropView()

    /// 読み取り専用バナーを当セッション中は二度と出さない（× で閉じられたら true）。
    private var readOnlyBannerDismissed = false

    /// 本文の下端の制約。分析ペイン（Pro）を差し込むときに付け替える。
    private var viewerBottomConstraint: NSLayoutConstraint?
    /// 分析ペイン（Pro が差し込む）。core は中身を知らず、置き場所と高さだけを持つ。
    private var analysisAccessory: NSView?
    private var analysisHeightConstraint: NSLayoutConstraint?

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
    /// サイドバーの幅。開閉は幅を 0 にして畳む（`isHidden` だと本文側の制約が浮く）。
    private var sidebarWidthConstraint: NSLayoutConstraint?
    /// ツールバーの delegate。窓が持つのは weak なので、こちらで保持しておく。
    private var toolbarDelegate: MainToolbarDelegate?
    /// 検索バーの上端。構造化バナーが出ている間は、その下へ下げる（重なり回避）。
    /// 検索バーの掴み手（既定位置を構造化バナーに合わせて上下させる）。
    private var searchOverlay: DraggableOverlay?
    /// 掴んで動かせる小窓（検索バー・各バナー）。位置はアプリ全体で覚える。
    private var draggableOverlays: [DraggableOverlay] = []

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
        setupToolbar()
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
        let translucent = !EditorTheme.isOpaqueBackground
        let baseBG = theme.appearanceName != nil ? theme.chromeBackground : NSColor.windowBackgroundColor
        window?.appearance = theme.appearanceName.map { NSAppearance(named: $0) } ?? nil
        // 透明時はタイトルバーも透かす（窓全体を非不透明にして背後を見せる）。
        window?.titlebarAppearsTransparent = (theme.appearanceName != nil) || translucent
        window?.isOpaque = !translucent
        window?.backgroundColor = translucent ? EditorTheme.withBackgroundOpacity(baseBG) : baseBG
        sidebar.applyTheme()
        statusBar.applyTheme()
        searchBar.applyTheme()
        aiResultPanel.applyTheme()
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

        let sidebarWidthC = sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth)
        sidebarWidthConstraint = sidebarWidthC

        // 本文の下端。分析ペイン（Pro）を差すときだけ付け替える。
        let viewerContainerBottom = viewerContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        self.viewerBottomConstraint = viewerContainerBottom

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarWidthC,

            viewerContainer.topAnchor.constraint(equalTo: content.topAnchor),
            viewerContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            viewerContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            viewerContainerBottom,

            statusBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height),
        ])

        // 検索バー（本文領域の右上に浮かべる。初期は非表示）
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = true
        content.addSubview(searchBar)
        // 構造化バナーと同じ右上に浮くので、バナーが出ている間はその下へ逃がす。
        // 1.11 で構造化中も検索できるようにした結果、両方が同時に出るようになった
        // （それまでは構造化に切り替えると検索バーを閉じていたので重ならなかった）。
        let searchTop = searchBar.topAnchor.constraint(equalTo: viewerContainer.topAnchor, constant: 10)
        let searchTrailing = searchBar.trailingAnchor.constraint(equalTo: viewerContainer.trailingAnchor, constant: -28)
        NSLayoutConstraint.activate([
            searchTop, searchTrailing,
            // 「±N」の欄を足したぶん広げてある（440 のままだと「Aa」が「…」に潰れる）。
            searchBar.widthAnchor.constraint(equalToConstant: 512),
            searchBar.heightAnchor.constraint(equalToConstant: SearchBarView.height),
        ])
        searchOverlay = addDraggable("search", searchBar, horizontal: searchTrailing, .trailing, vertical: searchTop, .leading)
        searchBar.onQueryChange = { [weak self] q in self?.activeViewer?.setSearchQuery(q) }
        searchBar.onNext = { [weak self] in self?.activeViewer?.findNext() }
        searchBar.onPrev = { [weak self] in self?.activeViewer?.findPrev() }
        searchBar.onClose = { [weak self] in self?.hideSearch() }
        searchBar.onCaseToggle = { [weak self] on in self?.activeViewer?.setCaseSensitive(on) }
        searchBar.onRegexToggle = { [weak self] on in self?.activeViewer?.setRegexMode(on) }
        searchBar.onFilterToggle = { [weak self] on in
            // 本人が押した ＝ これが以後の既定。次の ⌘F はこの状態で開く。
            AppSettings.searchFilterOn = on
            self?.activeViewer?.setFilterMode(on)
            self?.refreshSearchBarCapabilities()   // 絞り込み中は置換を落とす
        }
        // 使えないペインへ移ったせいで降りた場合。ペインには反映するが、**意図は消さない**。
        searchBar.onFilterUnavailable = { [weak self] in
            self?.activeViewer?.setFilterMode(false)
        }
        searchBar.onContextChange = { [weak self] n in self?.activeViewer?.setFilterContextLines(n) }
        searchBar.onReplace = { [weak self] r in self?.activeViewer?.replaceCurrent(with: r) }
        searchBar.onReplaceAll = { [weak self] r in self?.activeViewer?.replaceAll(with: r) }
        searchBar.onPreserveCaseToggle = { [weak self] on in self?.activeViewer?.setPreserveCase(on) }

        // AI パネルは独立したフローティングウィンドウ（アプリ外へも動かせる）。ここでは配線だけ。
        aiResultPanel.onClose = { [weak self] in self?.hideAIResult() }
        aiResultPanel.onAnalyze = { [weak self] in self?.diagnoseSelectionWithAI() }
        aiResultPanel.onCopy = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.aiResultPanel.bodyText, forType: .string)
        }

        // 読み取り専用バナー（本文領域の左上に浮かべる。大ファイルを開いたときだけ表示）
        readOnlyBanner.translatesAutoresizingMaskIntoConstraints = false
        readOnlyBanner.isHidden = true
        readOnlyBanner.onClose = { [weak self] in
            self?.readOnlyBannerDismissed = true
            self?.readOnlyBanner.isHidden = true
        }
        content.addSubview(readOnlyBanner)
        let roTop = readOnlyBanner.topAnchor.constraint(equalTo: viewerContainer.topAnchor, constant: 10)
        let roLeading = readOnlyBanner.leadingAnchor.constraint(equalTo: viewerContainer.leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            roTop, roLeading,
            readOnlyBanner.heightAnchor.constraint(equalToConstant: ReadOnlyBanner.height),
        ])
        addDraggable("readonly", readOnlyBanner, horizontal: roLeading, .leading, vertical: roTop, .leading)

        // 構造化表示バナー（本文領域の左上・構造化中だけ表示。「元に戻す」で通常表示へ）
        structuredBanner.translatesAutoresizingMaskIntoConstraints = false
        structuredBanner.isHidden = true
        structuredBanner.onRevert = { [weak self] in self?.setActiveStructuredMode(nil) }
        content.addSubview(structuredBanner)
        // 右上に浮かべる（左のヘッダ列を隠さない）。検索バーと同じ角なので、既定では
        // 検索バーを下へ逃がす（下の searchBarTopConstraint）。どちらも掴んで動かせる。
        let stTop = structuredBanner.topAnchor.constraint(equalTo: viewerContainer.topAnchor, constant: 10)
        let stTrailing = structuredBanner.trailingAnchor.constraint(equalTo: viewerContainer.trailingAnchor, constant: -28)
        NSLayoutConstraint.activate([
            stTop, stTrailing,
            structuredBanner.heightAnchor.constraint(equalToConstant: StructuredBanner.height),
        ])
        addDraggable("structured", structuredBanner, horizontal: stTrailing, .trailing, vertical: stTop, .leading)

        // 外部変更バナー（本文領域の**下端**。上端は検索バー・読み取り専用・構造化で埋まっている）
        externalBanner.translatesAutoresizingMaskIntoConstraints = false
        externalBanner.isHidden = true
        externalBanner.onReload = { [weak self] in self?.reloadActiveFromDisk() }
        externalBanner.onClose = { [weak self] in self?.dismissExternalBanner() }
        content.addSubview(externalBanner)
        let exBottom = externalBanner.bottomAnchor.constraint(equalTo: viewerContainer.bottomAnchor, constant: -10)
        let exLeading = externalBanner.leadingAnchor.constraint(equalTo: viewerContainer.leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            exBottom, exLeading,
            externalBanner.heightAnchor.constraint(equalToConstant: ExternalChangeBanner.height),
        ])
        addDraggable("external", externalBanner, horizontal: exLeading, .leading, vertical: exBottom, .trailing)

        // 本文領域の大きさが変わったら浮きパネルを置き直す（サイドバー開閉・窓のリサイズ）。
        viewerContainer.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewerContainerResized),
                                               name: NSView.frameDidChangeNotification, object: viewerContainer)

        externalWatcher.onChange = { [weak self] key in self?.externalChangeDetected(key) }
        externalWatcher.start()

        applyChrome()   // 永続化されたテーマを起動時に反映する。
    }

    // MARK: - ドキュメント管理

    /// ファイルを開く（既に開いていれば選択、なければ追加）。
    ///
    /// gzip は展開してから開く。中身で判定する —— 拡張子は嘘をつく（`.log` のまま
    /// gzip されたもの、`.gz` なのに素のテキスト、どちらも実際にある）。
    func open(url: URL) {
        OpenTiming.begin()      // MREDITOR_TIMING=1 のときだけ動く
        if let head = try? FileHandle(forReadingFrom: url).read(upToCount: 4) {
            let magic = [UInt8](head)
            if Intake.isGzip(magic) {
                if let expanded = Intake.gunzip(url) {
                    openExpanded(expanded, origin: url)
                } else {
                    presentOpenFailure(url, reason: L("open.failed.gzip"))
                }
                return
            }
            if Intake.isZip(magic) { openZip(url); return }
        }
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

    /// 展開・受信した中身を開く。元がどこから来たかはタブに出す —— 一時ファイルの
    /// 名前だけが出ていると、何を見ているのか分からなくなる。
    private func openExpanded(_ url: URL, origin: URL?) {
        let v = makePane(for: url)
        install(v)
        guard v.open(url: url) else { v.removeFromSuperview(); return }
        if let origin { NSDocumentController.shared.noteNewRecentDocumentURL(origin) }
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)
    }

    /// パイプで受け取った中身を開く（`kubectl logs … | mreditor`）。
    func openPiped(_ url: URL) { openExpanded(url, origin: nil) }

    /// zip を開く。**1 つしか入っていなければ黙って開く** —— 選択肢が 1 つのダイアログは、
    /// 確認ではなく手間でしかない。複数なら名前を並べて選ばせる。
    private func openZip(_ url: URL) {
        let entries = Intake.zipEntries(url)
        guard !entries.isEmpty else {
            presentOpenFailure(url, reason: L("open.failed.zipEmpty")); return
        }
        guard entries.count > 1 else {
            openZipEntry(url, entry: entries[0]); return
        }

        let alert = NSAlert()
        alert.messageText = L("open.zip.chooseTitle")
        alert.informativeText = String(format: L("open.zip.chooseBody"),
                                       url.lastPathComponent, entries.count)
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        picker.addItems(withTitles: entries)
        alert.accessoryView = picker
        alert.addButton(withTitle: L("open.zip.open"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openZipEntry(url, entry: entries[picker.indexOfSelectedItem])
    }

    private func openZipEntry(_ url: URL, entry: String) {
        if let expanded = Intake.unzip(url, entry: entry) {
            openExpanded(expanded, origin: url)
        } else {
            presentOpenFailure(url, reason: L("open.failed.zipEntry"))
        }
    }

    private func presentOpenFailure(_ url: URL, reason: String) {
        let alert = NSAlert()
        alert.messageText = L("open.failed.title")
        alert.informativeText = String(format: reason, url.lastPathComponent)
        alert.runModal()
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
        syncExternalWatch()   // 開いているファイルの増減・保存先の変更に監視を合わせる
    }

    // MARK: - 外部変更の取り込み

    /// 監視リストを、いま開いているファイルに合わせる。
    private func syncExternalWatch() {
        externalWatcher.sync(viewers.compactMap { pane in
            pane.fileURL.map { (key: ObjectIdentifier(pane), url: $0) }
        })
    }

    /// ディスクの内容が変わったと分かったとき（監視タイマーから）。
    ///
    /// 黙って取り込むのは**未保存の変更が無く、本文をそのまま見せているペインだけ**。
    /// 整形・絞り込み・クエリ表示中は本文が差し替わっており（`canEdit == false`）、
    /// 読み込み直すとユーザーの作った見え方を勝手に壊すので、バナーで知らせて選ばせる。
    private func externalChangeDetected(_ key: ObjectIdentifier) {
        guard let pane = viewers.first(where: { ObjectIdentifier($0) == key }) else { return }
        guard AppSettings.autoReloadExternalChanges, !pane.isDirty, pane.canEdit else {
            externallyChangedPanes.insert(key)
            updateExternalBanner()
            return
        }
        applyDiskReload(to: pane)
    }

    /// ペインをディスクの内容へ更新し、周辺 UI を合わせる。
    private func applyDiskReload(to pane: DocumentPane) {
        guard let url = pane.fileURL, pane.reloadFromDisk() else { return }
        externallyChangedPanes.remove(ObjectIdentifier(pane))
        // いま取り込んだ版を「知っている版」にする（これをしないと同じ変更で鳴り続ける）。
        externalWatcher.note(key: ObjectIdentifier(pane), url: url)
        reloadSidebar()
        updateExternalBanner()
        updateEditedState()
        if pane === activeViewer { showExternalReloadMessage() }
    }

    /// バナーの「読み込む」。未保存の変更を潰すときだけ確認する。
    private func reloadActiveFromDisk() {
        guard let pane = activeViewer, pane.fileURL != nil else { return }
        guard pane.isDirty, let win = window else { applyDiskReload(to: pane); return }
        let alert = NSAlert()
        alert.messageText = L("external.confirmTitle", displayName(of: pane))
        alert.informativeText = L("external.confirmMessage")
        alert.addButton(withTitle: L("external.reload"))   // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))     // .alertSecondButtonReturn
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            self.applyDiskReload(to: pane)
        }
    }

    /// バナーの ×。取り込まないと決めたので、いまのディスクの版を「知っている版」にして黙る
    /// （次に変わったらまた知らせる）。
    private func dismissExternalBanner() {
        guard let pane = activeViewer, let url = pane.fileURL else { return }
        externallyChangedPanes.remove(ObjectIdentifier(pane))
        externalWatcher.note(key: ObjectIdentifier(pane), url: url)
        updateExternalBanner()
    }

    /// バナーはアクティブなペインのものだけを出す（ドキュメントごとの状態）。
    private func updateExternalBanner() {
        guard let pane = activeViewer else { externalBanner.isHidden = true; return }
        externalBanner.isHidden = !externallyChangedPanes.contains(ObjectIdentifier(pane))
    }

    /// 黙って差し替えると「勝手に変わった」と見えるので、数秒だけステータスバーで断る。
    private func showExternalReloadMessage() {
        statusBar.showMessage(L("external.reloaded"))
        externalMessageTimer?.invalidate()
        externalMessageTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.statusBar.clearMessage()
            self?.activeViewer?.reEmitState()
        }
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
    func openDiff(title: String,
                  notReadableMessage: String? = nil,
                  makeSources: @escaping () -> (DiffSource, DiffSource)?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let v = DiffViewer()
        install(v)
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)

        v.onCompared = { [weak self] in self?.reloadSidebar() }
        // マージ結果は、保存したら開いて見せる（書きっぱなしにしない）。
        v.onMergedSaved = { [weak self] url in self?.open(url: url) }
        v.beginCompare(title: title, makeSources: makeSources, notReadableMessage: notReadableMessage, onFailure: { [weak self, weak v] message in
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

    /// 入口 4: URL の内容と、いま開いているドキュメントを比べる。
    /// URL は入力を訊いてから開く（クリップボードが URL ならプリフィルする）。
    func compareWithURL() {
        promptForCompareURL { [weak self] url in
            guard let self, let url else { return }
            let name = CompareURL.displayName(for: url)
            // アクティブが無ければ、空ドキュメントと URL を並べる（クリップボードと同じ振る舞い）。
            guard let active = self.activeViewer, !(active is DiffViewer) else {
                self.openDiff(title: name, notReadableMessage: L("diff.urlFailed")) {
                    guard let r = downloadDiffSource(from: url, displayName: name) else { return nil }
                    return (TextDiffSource(text: "", displayName: L("doc.untitled")), r)
                }
                return
            }
            let recipe = self.diffRecipe(for: active)
            let title = "\(self.displayName(of: active)) ↔ \(name)"
            self.openDiff(title: title, notReadableMessage: L("diff.urlFailed")) {
                guard let l = recipe.makeSource(),
                      let r = downloadDiffSource(from: url, displayName: name) else { return nil }
                return (l, r)
            }
        }
    }

    /// 比較する URL を訊くシート。有効な https のみ `completion` に渡す（それ以外は nil）。
    private func promptForCompareURL(completion: @escaping (URL?) -> Void) {
        guard let win = window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = L("diff.url.prompt")
        alert.informativeText = L("diff.url.message")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://…"
        // クリップボードが URL なら入れておく（コピーしてきて比べる、が一番多い動線）。
        if let clip = NSPasteboard.general.string(forType: .string),
           let u = CompareURL.normalize(clip) {
            field.stringValue = u.absoluteString
        }
        alert.accessoryView = field
        alert.addButton(withTitle: L("diff.compare"))   // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))  // .alertSecondButtonReturn
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn else { completion(nil); return }
            guard let url = CompareURL.normalize(field.stringValue) else {
                NSSound.beep(); completion(nil); return
            }
            completion(url)
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
    /// 一致行だけ表示ができるドキュメントが開いているか（前後 N 行の増減もこれに従う）。
    var canFilter: Bool { (activeViewer?.supportsSearch ?? false) && (activeViewer?.supportsSearchFilter ?? false) }
    /// 何かドキュメントが開いているか。
    var hasActiveDocument: Bool { activeIndex >= 0 }
    /// アクティブなドキュメントが末尾追従中か。
    var isFollowingActive: Bool { activeViewer?.isFollowing ?? false }
    /// 構造化表示できるか（View メニューの有効化）。
    var canStructured: Bool { activeViewer?.supportsStructured ?? false }
    /// JSON 整形（単一ドキュメント字下げ）が現在のペインで使えるか。大ファイルは不可。
    var canStructuredJson: Bool { activeViewer?.supportsJsonReformat ?? false }
    /// JSON その場クエリが現在のペインで使えるか。大ファイルは不可。
    var canJsonQuery: Bool { activeViewer?.supportsJsonQuery ?? false }
    var jsonQueryIsActive: Bool { activeViewer?.jsonQueryIsActive ?? false }

    func toggleActiveJsonQuery() {
        guard let v = activeViewer, v.supportsJsonQuery else { NSSound.beep(); return }
        v.toggleJsonQuery()
    }

    // MARK: - 桁ルーラー（固定長データを数える）

    /// 桁ルーラーを出せるか（両ビューアが対応・diff は非対応）。
    var canColumnRuler: Bool { activeViewer?.supportsColumnRuler ?? false }
    var columnRulerIsVisible: Bool { activeViewer?.columnRulerVisible ?? false }
    /// 桁ガイドが 1 本でもあるか（「桁ガイドを消す」の有効化）。
    var hasColumnGuides: Bool { activeViewer?.hasColumnGuides ?? false }

    func toggleActiveColumnRuler() {
        guard let v = activeViewer, v.supportsColumnRuler else { NSSound.beep(); return }
        v.setColumnRulerVisible(!v.columnRulerVisible)
    }

    func clearActiveColumnGuides() {
        activeViewer?.clearColumnGuides()
    }

    /// 固定長の項目定義を数値で打つ（`1-8,9-14,15-40`）。
    ///
    /// **クリックで置くだけでは足りない。** 固定長を扱う人はたいてい仕様書を持っていて、
    /// 32 項目を目視で置かせるのは苦行。逆に仕様書が無いときは境界を探すことが本体なので、
    /// クリックとドラッグも要る。どちらも同じ 1 つの状態（桁ガイド）を書き換える。
    func editActiveColumnFields(completion: ((Bool) -> Void)? = nil) {
        guard let v = activeViewer, v.supportsColumnRuler else { NSSound.beep(); completion?(false); return }
        let current = ColumnFieldSpec.text(for: ColumnGuides(v.columnGuideColumns))
        promptForColumnFields(initial: current) { [weak self] columns in
            guard let columns else { completion?(false); return }        // キャンセル
            v.setColumnGuides(columns)
            // 打ったのに何も見えない、を作らない（線とルーラーは同時に出す）。
            if !columns.isEmpty, !v.columnRulerVisible { v.setColumnRulerVisible(true) }
            _ = self
            completion?(!columns.isEmpty)
        }
    }

    /// 項目定義を訊くシート。OK なら境界の桁（空＝定義なし）、キャンセルなら nil。
    /// 読めない書き方は**黙って一部だけ通さない**（直してもらうまで同じシートに戻る）。
    private func promptForColumnFields(initial: String, completion: @escaping ([Int]?) -> Void) {
        guard let win = window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = L("columnFields.prompt")
        alert.informativeText = L("columnFields.message")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "1-8,9-14,15-40"
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { completion(nil); return }
            let text = field.stringValue
            guard let columns = ColumnFieldSpec.parse(text) else {
                let bad = NSAlert()
                bad.alertStyle = .warning
                bad.messageText = L("columnFields.invalid")
                bad.informativeText = L("columnFields.message")
                bad.beginSheetModal(for: win) { _ in
                    self?.promptForColumnFields(initial: text, completion: completion)
                }
                return
            }
            completion(columns)
        }
    }
    /// アクティブなドキュメントが編集可能か（編集ツールボックスのメニュー有効化に使う）。
    var canTransformText: Bool { activeViewer?.canEdit ?? false }
    /// 桁ガイドに揃えられるか（編集できて、切れ目が引いてあること）。
    /// 切れ目が無くても中身から作れるので、**編集できれば押せる**。
    var canAlignToColumnGuides: Bool {
        guard let v = activeViewer as? EditableViewer else { return false }
        return v.canEdit
    }

    /// 桁ガイドの割り付けに、選択範囲（無ければ全文）を揃える。
    func alignActiveToColumnGuides() {
        guard let v = activeViewer as? EditableViewer, canAlignToColumnGuides else { NSSound.beep(); return }
        v.alignToColumnGuides()
    }

    /// アクティブなドキュメントの選択に編集ツールボックスの変換を適用する。
    func applyActiveTextTransform(_ transform: TextTransform) {
        guard let v = activeViewer, v.canEdit else { NSSound.beep(); return }
        v.applyTextTransform(transform)
    }

    // MARK: - AI（BYOK・単発解析。選択範囲＝コンテキストに収まる分だけを扱う）

    /// AI パネルを開けるか（ドキュメントがあれば常に。選択の有無はパネル内で案内する）。
    var canAIDiagnose: Bool { hasActiveDocument }

    /// AI パネルを表示（常駐）し、いま選択している本文の原因を推測させて結果を出す。
    /// パネルの「解析」ボタン・⌘⌥E・メニューの共通の入口。選択が無ければ淡いヒントを出す。
    /// 答えは書かれる端から流し込む（ストリーミング）＝待ち時間が「進んでいる」に変わる。
    func diagnoseSelectionWithAI() {
        showAIPanel()
        aiStream?.cancel()                      // 解析し直し・連打では前の流れを捨てる
        aiStream = nil
        guard let selection = activeViewer?.selectedText, !selection.isEmpty else {
            aiResultPanel.showHint(L("ai.error.noSelection"))
            return
        }
        aiResultPanel.beginStreaming()
        aiStream = AIClient.stream(
            AIPrompts.errorCause(selection, language: L("ai.replyLanguage")),
            onDelta: { [weak self] chunk in
                guard let self, self.aiPanelWindow?.isVisible == true else { return }
                self.aiResultPanel.appendStreamDelta(chunk)
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.aiStream = nil
                guard self.aiPanelWindow?.isVisible == true else { return }
                switch result {
                case .success:          self.aiResultPanel.finishStreaming()
                case .failure(let err): self.aiResultPanel.showError(err.errorDescription ?? "\(err)")
                }
            })
    }

    /// AI パネルのフローティングウィンドウを（無ければ作って）前面に出す。アプリに追従する子ウィンドウ。
    private func showAIPanel() {
        let panel: AIPanelWindow
        if let existing = aiPanelWindow {
            panel = existing
        } else {
            panel = AIPanelWindow(contentRect: NSRect(x: 0, y: 0, width: AIResultPanel.width, height: AIResultPanel.height),
                                  styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false
            panel.minSize = NSSize(width: 360, height: 200)
            panel.contentView = aiResultPanel
            aiPanelWindow = panel
        }
        guard !panel.isVisible else { return }
        positionAIPanel(panel)
        window?.addChildWindow(panel, ordered: .above)   // アプリに追従しつつ前面。外へも動かせる。
        panel.makeKeyAndOrderFront(nil)
    }

    /// 初回表示位置＝メインウィンドウの右上あたり。
    private func positionAIPanel(_ panel: NSWindow) {
        guard let main = window else { return }
        let f = main.frame
        panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 24,
                                     y: f.maxY - panel.frame.height - 24))
    }

    func hideAIResult() {
        aiStream?.cancel()                      // 閉じたら受信も止める（通信を残さない）
        aiStream = nil
        if let panel = aiPanelWindow {
            window?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        activeViewer?.focusContent()
    }

    // MARK: - 行の分割（区切り文字はダイアログで受け取る）

    private static let lastSplitDelimiterKey = "toolbox.lastSplitDelimiter"

    /// 選択した各行を区切り文字で分割する（`行を連結` の逆操作）。
    func splitActiveSelectionIntoLines() {
        guard let pane = activeViewer, pane.canEdit,
              let selection = pane.selectedText, !selection.isEmpty else { NSSound.beep(); return }
        promptForSplitOptions { [weak self] options in
            guard let self, let options else { return }
            UserDefaults.standard.set(options.delimiter, forKey: Self.lastSplitDelimiterKey)
            // シートを閉じている間に選択が変わっていないか確かめてから置換する。
            guard self.activeViewer === pane, pane.selectedText == selection else { return }
            guard let result = LineSplitter.split(selection, options: options) else { NSSound.beep(); return }
            guard result != selection else { return }   // 変化なしはアンドゥを積まない
            pane.replaceSelection(with: result)
        }
    }

    /// 区切り文字と扱いを訊くシート（前回の区切り文字を初期値に）。
    private func promptForSplitOptions(completion: @escaping (LineSplitter.Options?) -> Void) {
        guard let win = window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = L("split.prompt")
        alert.informativeText = L("split.message")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = ","
        field.stringValue = UserDefaults.standard.string(forKey: Self.lastSplitDelimiterKey) ?? ","
        let label = NSTextField(labelWithString: L("split.delimiter"))
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 8
        let trimCheck = NSButton(checkboxWithTitle: L("split.trim"), target: nil, action: nil)
        let dropCheck = NSButton(checkboxWithTitle: L("split.dropEmpty"), target: nil, action: nil)
        let stack = NSStackView(views: [row, trimCheck, dropCheck])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 84)
        alert.accessoryView = stack

        alert.addButton(withTitle: L("split.run"))      // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))  // .alertSecondButtonReturn
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn else { completion(nil); return }
            completion(LineSplitter.Options(delimiter: field.stringValue,
                                            trimEach: trimCheck.state == .on,
                                            dropEmpty: dropCheck.state == .on))
        }
    }

    // MARK: - 連番（開始・増分・桁埋め・区切りはダイアログで受け取る）

    private static let lastNumberOptionsKey = "toolbox.lastNumberOptions"

    /// 選択した各行の先頭に連番を振る（パラメータ付き＝`TextTransform.numberLines` の一般形）。
    func numberActiveSelectionLines() {
        guard let pane = activeViewer, pane.canEdit,
              let selection = pane.selectedText, !selection.isEmpty else { NSSound.beep(); return }
        promptForNumberOptions { [weak self] options in
            guard let self, let options else { return }
            self.saveNumberOptions(options)
            // シートを閉じている間に選択が変わっていないか確かめてから置換する。
            guard self.activeViewer === pane, pane.selectedText == selection else { return }
            let result = LineNumberer.number(selection, options: options)
            guard result != selection else { return }   // 変化なしはアンドゥを積まない
            pane.replaceSelection(with: result)
        }
    }

    /// 前回の設定（開始・増分・桁埋め・区切り）を初期値にしたシート。
    private func promptForNumberOptions(completion: @escaping (LineNumberer.Options?) -> Void) {
        guard let win = window else { completion(nil); return }
        let saved = loadNumberOptions()
        let alert = NSAlert()
        alert.messageText = L("number.prompt")
        alert.informativeText = L("number.message")

        func numberField(_ value: Int) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 24))
            f.alignment = .right
            f.integerValue = value
            return f
        }
        let startField = numberField(saved.start)
        let stepField = numberField(saved.step)
        let padField = numberField(saved.padWidth)
        let sepField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        sepField.stringValue = saved.separator
        sepField.placeholderString = "\\t"

        func row(_ key: String, _ field: NSTextField) -> NSStackView {
            let label = NSTextField(labelWithString: L(key))
            label.setContentHuggingPriority(.required, for: .horizontal)
            let r = NSStackView(views: [label, field])
            r.orientation = .horizontal
            r.spacing = 8
            return r
        }
        let stack = NSStackView(views: [row("number.start", startField), row("number.step", stepField),
                                        row("number.pad", padField), row("number.separator", sepField)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 124)
        alert.accessoryView = stack

        alert.addButton(withTitle: L("number.run"))     // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))  // .alertSecondButtonReturn
        alert.window.initialFirstResponder = startField
        alert.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn else { completion(nil); return }
            completion(LineNumberer.Options(start: startField.integerValue,
                                            step: stepField.integerValue,
                                            padWidth: max(0, padField.integerValue),
                                            separator: sepField.stringValue))
        }
    }

    /// 連番の設定は 4 項目あるので 1 つの配列にまとめて覚える（区切りは文字列のまま）。
    private func saveNumberOptions(_ o: LineNumberer.Options) {
        UserDefaults.standard.set(["\(o.start)", "\(o.step)", "\(o.padWidth)", o.separator],
                                  forKey: Self.lastNumberOptionsKey)
    }

    private func loadNumberOptions() -> LineNumberer.Options {
        guard let saved = UserDefaults.standard.stringArray(forKey: Self.lastNumberOptionsKey), saved.count == 4
        else { return LineNumberer.Options() }
        return LineNumberer.Options(start: Int(saved[0]) ?? 1, step: Int(saved[1]) ?? 1,
                                    padWidth: Int(saved[2]) ?? 0, separator: saved[3])
    }

    // MARK: - マルチカーソル（小ファイルの編集ペインのみ）

    /// マルチカーソルのメニューを有効にしてよいか。
    var canMultiCursor: Bool { activeViewer?.supportsMultiCursor ?? false }

    /// 上／下の行の同じ桁にキャレットを足す（⌥⌘↑ / ⌥⌘↓）。
    func addCaretToActive(above: Bool) {
        guard let v = activeViewer, v.supportsMultiCursor else { NSSound.beep(); return }
        v.addCaret(above: above)
    }

    /// 選択中の語と同じ次の語を選択に足す（⌘D）。
    func selectNextOccurrenceInActive() {
        guard let v = activeViewer, v.supportsMultiCursor else { NSSound.beep(); return }
        v.selectNextOccurrence()
    }

    // MARK: - 外部コマンド・フィルタ（選択を /bin/sh に通して置換）

    private static let lastFilterCommandKey = "toolbox.lastFilterCommand"

    /// アクティブなドキュメントの選択を外部コマンドに通して置換する（vim の `!` 相当）。
    func filterActiveSelectionThroughCommand() {
        guard let pane = activeViewer, pane.canEdit,
              let selection = pane.selectedText, !selection.isEmpty else { NSSound.beep(); return }
        promptForFilterCommand { [weak self] command in
            guard let self, let command, !command.isEmpty else { return }
            UserDefaults.standard.set(command, forKey: Self.lastFilterCommandKey)
            // 実行は背景（遅い/固まるコマンドで UI を止めない）。結果はメインで適用。
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try ShellFilter.run(command: command, input: selection) }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let output):
                        // 実行中に選択が変わっていたら適用しない（古い入力で新しい選択を潰さない）。
                        guard self.activeViewer === pane, pane.selectedText == selection else {
                            self.presentFilterError(L("filter.selectionChanged")); return
                        }
                        pane.replaceSelection(with: output)
                    case .failure(let error):
                        self.presentFilterError(self.describeFilterError(error))
                    }
                }
            }
        }
    }

    /// 通すコマンドを訊くシート（前回のコマンドを初期値に）。
    private func promptForFilterCommand(completion: @escaping (String?) -> Void) {
        guard let win = window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = L("filter.prompt")
        alert.informativeText = L("filter.message")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "sort | uniq"
        field.stringValue = UserDefaults.standard.string(forKey: Self.lastFilterCommandKey) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("filter.run"))     // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))  // .alertSecondButtonReturn
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn else { completion(nil); return }
            completion(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func describeFilterError(_ error: Error) -> String {
        guard let f = error as? ShellFilter.Failure else { return error.localizedDescription }
        switch f {
        case .launchFailed(let m): return L("filter.launchFailed", m)
        case .timedOut:            return L("filter.timedOut")
        case .nonZeroExit(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L("filter.exitCode", code)
                                   : L("filter.exitCodeStderr", code, trimmed)
        }
    }

    private func presentFilterError(_ message: String) {
        guard let win = window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("filter.failed")
        alert.informativeText = message
        alert.beginSheetModal(for: win)   // ボタン未指定＝システムの OK
    }
    /// アクティブなドキュメントの構造化表示モード（メニューのチェック用）。
    var activeStructuredMode: StructuredMode? { activeViewer?.structuredMode }
    /// アクティブなドキュメントの構造化表示モードを設定する。
    ///
    /// 固定長だけは中身から列を割り出せない（区切り文字が無い）。**定義が無いまま選んだら
    /// その場で訊く**——「構造化モードだが列が未定義」という説明のつかない状態を作らない。
    func setActiveStructuredMode(_ mode: StructuredMode?) {
        guard let v = activeViewer, v.supportsStructured else { NSSound.beep(); return }
        if mode == .fixedWidth, !ColumnGuides(v.columnGuideColumns).hasFieldBoundaries {
            editActiveColumnFields { [weak self] defined in
                guard defined else { return }        // 定義しなかった＝切り替えない
                self?.applyStructuredMode(.fixedWidth, to: v)
            }
            return
        }
        applyStructuredMode(mode, to: v)
    }

    private func applyStructuredMode(_ mode: StructuredMode?, to v: DocumentPane) {
        v.setStructuredMode(mode)
        // 巨大ファイル側は構造化中でも検索・フィルタが効く（桁を揃えたまま grep する）ので閉じない。
        // 小ファイル側は本文が整形後に差し替わり検索できないので、そちらだけ閉じる。
        if !searchBar.isHidden {
            if v.supportsSearch { refreshSearchBarCapabilities() } else { hideSearch() }
        }
        updateStructuredBanner()
        updateReadOnlyBanner()
    }

    /// 構造化表示バナーの表示可否を更新する（構造化中だけ出す）。
    /// バナーと検索バーは同じ右上に浮くので、出したぶんだけ検索バーを下げる。
    private func updateStructuredBanner() {
        if let mode = activeStructuredMode {
            structuredBanner.configure(mode: mode)
            structuredBanner.isHidden = false
        } else {
            structuredBanner.isHidden = true
        }
        // 既定位置だけを下げる（掴んで動かしたぶんは保つ）。制約の定数を直接書くと、
        // 動かした位置が構造化の切り替えのたびに消える。
        searchOverlay?.setBaseY(structuredBanner.isHidden ? 10 : 10 + StructuredBanner.height + 8)
    }

    /// 各ビューアにステータス/検索/ドロップのハンドラを繋ぐ（アクティブな時だけ反映）。
    private func wire(_ v: DocumentPane) {
        v.onStateChange = { [weak self, weak v] state in
            guard let self, self.activeViewer === v else { return }
            self.statusBar.update(state)
        }
        v.onSearchState = { [weak self, weak v] cur, tot, searching, prog, invalid, capped in
            guard let self, self.activeViewer === v else { return }
            self.searchBar.setCount(current: cur, total: tot, searching: searching,
                                    progress: prog, invalid: invalid, capped: capped)
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
        // AI パネルは常駐（切替でも消さない）。別ドキュメントの選択をそのまま解析できる。
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
        updateExternalBanner()
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
        externallyChangedPanes.remove(ObjectIdentifier(pane))
        externalWatcher.forget(key: ObjectIdentifier(pane))
        let v = viewers.remove(at: idx)
        v.removeFromSuperview()
        if viewers.isEmpty {
            activeIndex = -1
            reloadSidebar()
            window?.title = AppInfo.name
            statusBar.setPlaceholder()
            updateEditedState()
            updateReadOnlyBanner()
            updateExternalBanner()
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
            self.externalWatcher.note(key: ObjectIdentifier(pane), url: url)
            self.externallyChangedPanes.remove(ObjectIdentifier(pane))
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
            if let url = pane.fileURL {
                self.externalWatcher.note(key: ObjectIdentifier(pane), url: url)
                self.externallyChangedPanes.remove(ObjectIdentifier(pane))
            }
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
        if let url = v.fileURL {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            // 自分で書いた版を「知っている版」にする。これを忘れると、保存するたびに
            // 監視が「外部で変わった」と誤認して読み込み直す（＝アンドゥ履歴が飛ぶ）。
            externalWatcher.note(key: ObjectIdentifier(v), url: url)
            externallyChangedPanes.remove(ObjectIdentifier(v))
            updateExternalBanner()
        }
        reloadSidebar()
        if activeViewer === v {
            window?.title = displayName(of: v) + " — " + AppInfo.name
        }
        updateEditedState()
        persistSession()   // 保存で URL が確定/変更されうるため一覧を更新
    }

    // MARK: - 浮きパネル（掴んで動かす）

    /// 小窓を掴めるようにして、覚えてある位置を当てる。
    /// 本文領域の大きさが決まった／変わったときに、覚えてある位置を当て直す。
    /// **起動直後はまだ大きさが 0** なので、init で当てただけでは位置が復元されない
    /// （実機で発覚：横は動いたのに縦が戻らなかった）。
    @objc private func viewerContainerResized() {
        draggableOverlays.forEach { $0.reclamp() }
    }

    @discardableResult
    private func addDraggable(_ name: String, _ view: NSView,
                              horizontal: NSLayoutConstraint, _ h: OverlayPlacement.Anchor,
                              vertical: NSLayoutConstraint, _ v: OverlayPlacement.Anchor) -> DraggableOverlay {
        let o = DraggableOverlay(name: name, view: view, container: viewerContainer,
                                 horizontal: horizontal, horizontalAnchor: h,
                                 vertical: vertical, verticalAnchor: v)
        draggableOverlays.append(o)
        return o
    }

    /// 動かした小窓を全部、既定位置へ戻す（覚えている位置も忘れる）。
    public func resetOverlayPositions() {
        draggableOverlays.forEach { $0.reset() }
    }

    /// 覚えている位置のどれかが既定位置から動いているか（メニューの有効化）。
    var hasMovedOverlays: Bool { draggableOverlays.contains { $0.offset != .zero } }

    // MARK: - NSWindowDelegate

    /// 窓の大きさが変わったら、小窓を内側へ寄せ直す。
    /// **縮めたときに画面の外へ残ると、掴めなくなって戻せない。**
    public func windowDidResize(_ notification: Notification) {
        draggableOverlays.forEach { $0.reclamp() }
    }


    /// 他のアプリで直してから戻ってきた、が一番多い動線なので、切り替わった瞬間に見に行く
    /// （タイマー待ちの 1 秒を挟まない）。
    public func windowDidBecomeKey(_ notification: Notification) {
        externalWatcher.tick()
    }

    /// ウィンドウを閉じる前に未保存のドキュメントを確認する。
    /// 未保存の新規（URL 未確定）はセッション復元で残るため確認せず、保存済みファイルの
    /// 未保存編集だけを確認する。閉じる直前に最新の本文をセッションへ書き出す。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
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
        refreshSearchBarCapabilities()
        searchBar.isHidden = false
        // 前に自分で漏斗を入れていたなら、その状態で開く。構造化されたものを読むとき
        // 主目的は「絞る」ほうで、そこへ毎回 1 手かけ直すのが B2 の詰まりだった。
        applyRememberedFilter(to: v)
        searchBar.focusField()
    }

    /// 覚えている「絞る意図」を、いまのペインに当てられる範囲で当てる。
    /// 当てられないペイン（構造化・JSON）では何もしない ── 意図は覚えたまま。
    private func applyRememberedFilter(to v: DocumentPane) {
        guard AppSettings.searchFilterOn, v.supportsSearchFilter else { return }
        searchBar.setFilterOn(true)
        v.setFilterMode(true)
    }

    /// 検索バーの出し分けを、いまのペインの状態に合わせ直す。
    /// 構造化表示や一致行だけ表示に入ると「探せるが書けない」状態になるので、
    /// 漏斗と置換の可否はその都度引き直す（開いた時の値を持ち回らない）。
    private func refreshSearchBarCapabilities() {
        guard let v = activeViewer else { return }
        searchBar.setFilterAvailable(v.supportsSearchFilter)
        searchBar.setReplaceAvailable(v.supportsReplace)
        searchBar.setContextLines(v.filterContextLines)
        // 漏斗が使えるペインへ戻ってきたら、覚えている意図をもう一度当てる。
        // 検索バーが出ている間だけ ── 閉じているのに本文が絞られるのは事故に見える。
        if !searchBar.isHidden { applyRememberedFilter(to: v) }
    }

    /// 一致行の前後に出す行数を変える（検索バーの「±」欄・メニューの増減）。
    /// 見えていない検索バーの表示も合わせておく（次に開いたとき値が食い違わない）。
    func setFilterContextLines(_ n: Int) {
        guard let v = activeViewer else { NSSound.beep(); return }
        v.setFilterContextLines(n)
        searchBar.setContextLines(v.filterContextLines)
    }

    /// いまのペインの前後行数（メニューの表示・増減の起点）。
    var filterContextLines: Int { activeViewer?.filterContextLines ?? AppSettings.filterContextLines }

    // MARK: - しおり（メニューからの口）

    /// いまのペインにしおりがあるか（メニューの有効・無効に使う）。
    var hasBookmarks: Bool { !(activeViewer?.bookmarkedLines.isEmpty ?? true) }
    var hasDocument: Bool { activeViewer != nil }

    func toggleBookmark() { activeViewer?.toggleBookmark() }
    func goToBookmark(forward: Bool) { activeViewer?.goToBookmark(forward: forward) }

    // MARK: - 分析（Pro）の口
    //
    // ここに並ぶのは **Pro が core を読む/呼ぶための最小限**。Pro のロジックは 1 行も無い。
    // 無料ビルドでもコンパイルされるが、呼ぶ者がいないので何も起きない。

    /// いま見えているドキュメントの写し（分析の対象）。開いていなければ nil。
    public var activeDocument: ActiveDocument? {
        guard let v = activeViewer else { return nil }
        return ActiveDocument(fileURL: v.fileURL,
                              encoding: v.currentEncoding,
                              structuredMode: v.structuredMode,
                              columnNames: v.structuredColumnNames,
                              text: v.restorableText,
                              filterMatchLines: v.filterMatchLines)
    }

    /// 分析ペインを本文の下に差す（nil で外す）。**core は中身を知らない。**
    public func setAnalysisAccessory(_ view: NSView?, height: CGFloat = 220) {
        guard let content = window?.contentView else { return }
        analysisAccessory?.removeFromSuperview()
        analysisAccessory = nil
        analysisHeightConstraint = nil
        viewerBottomConstraint?.isActive = false

        guard let view else {
            let c = viewerContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
            viewerBottomConstraint = c
            c.isActive = true
            return
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        let h = view.heightAnchor.constraint(equalToConstant: height)
        let bottom = viewerContainer.bottomAnchor.constraint(equalTo: view.topAnchor)
        analysisHeightConstraint = h
        viewerBottomConstraint = bottom
        NSLayoutConstraint.activate([
            bottom, h,
            view.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
        analysisAccessory = view
    }

    /// 分析ペインの高さ（上端ドラッグで変える）。本文が潰れないよう上下に丸める。
    public var analysisAccessoryHeight: CGFloat {
        get { analysisHeightConstraint?.constant ?? 0 }
        set {
            let available = window?.contentView?.bounds.height ?? 800
            analysisHeightConstraint?.constant = max(120, min(newValue, available - 200))
        }
    }

    /// 値をひとつ受け取って「一致行だけ表示」に切り替える（分析の表からの往復）。
    /// 正規表現ではなく**リテラル**として渡す（値に `.` や `[` が入っていても壊れない）。
    public func applyLiteralFilter(_ value: String) {
        guard let v = activeViewer, v.supportsSearchFilter else { NSSound.beep(); return }
        showSearch()
        searchBar.setQuery(value, regex: false, caseSensitive: true, filter: true)
        v.setRegexMode(false)
        v.setCaseSensitive(true)
        v.setSearchQuery(value)
        v.setFilterMode(true)
    }

    /// 時間帯で選んだ行だけを表示する（時間分布のドラッグ選択）。行は **0 始まり・昇順**。
    /// 空配列で解除。**検索ではない**ので検索バーには何も入れない。
    public func showOnlyLines(_ lines: [Int]) {
        guard let v = activeViewer else { NSSound.beep(); return }
        v.showOnlyLines(lines)
    }

    /// ファイルを開いてその行へ飛ぶ（横断検索の結果クリック）。行は **1 始まり**。
    public func open(url: URL, line: Int) {
        open(url: url)
        // 開いた直後はまだ索引が走っているので、次のループで飛ぶ。
        DispatchQueue.main.async { [weak self] in self?.activeViewer?.goToLine(line) }
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

    // MARK: - 時系列でまとめて開く

    /// 複数のログを選び、時刻で1本に束ねて開く。
    ///
    /// 束ねた結果は一時ファイルに書いて**通常の「開く」経路**へ渡す。専用ビューアを
    /// 作らないので、検索・フィルタ・構造化表示・別名保存が全部そのまま効く。
    @objc func openMergedByTime(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = L("merge.open.message")
        panel.prompt = L("merge.open.prompt")
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.mergeByTime(urls: panel.urls)
        }
    }

    /// 実際に束ねて開く。読み込みと並べ替えは背景で行い、UI は結果だけ受け取る。
    func mergeByTime(urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let builder = MergedLogBuilder()
            do {
                let result = try builder.build(urls: urls)
                DispatchQueue.main.async { [weak self] in
                    self?.open(url: result.url)
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = L("merge.failedTitle")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - ツールバー
//
// 既定に並ぶ 6 つが「このアプリが何者か」の宣言になっている（顔）。
// 選定と並び順の理由は `MainToolbar.swift` の先頭に書いた。
// 動作は全てここに集約し、ツールバー側は組み立てだけを持つ。

extension MainWindowController: NSToolbarItemValidation, NSMenuDelegate {

    fileprivate func setupToolbar() {
        let delegate = MainToolbarDelegate(controller: self)
        toolbarDelegate = delegate
        let toolbar = NSToolbar(identifier: "MrEditorMainToolbar")
        toolbar.delegate = delegate
        toolbar.allowsUserCustomization = true      // 「ツールバーをカスタマイズ…」が標準で付く
        toolbar.autosavesConfiguration = true       // 並べ替えた結果はユーザーごとに残る
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    // MARK: 活性制御
    //
    // メニュー側（`AppDelegate.validateMenuItem`）と同じ `can*` を見る。
    // 判定を二重に書くと必ずズレるので、条件は `MainWindowController` の
    // プロパティ 1 箇所に置いたまま両方から引く。

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .mrSidebar:    return true
        case .mrStructured: return canStructured
        case .mrFilter:
            // 「一致行だけ表示」と名乗る以上、絞れないペインでは落とす。
            // 開いてみたら漏斗が無い、では約束を破ることになる。
            return (activeViewer?.supportsSearch ?? false) && (activeViewer?.supportsSearchFilter ?? false)
        case .mrCompare:    return true            // 4 つの入口それぞれで面倒を見る
        case .mrFollow:
            // 追従中かどうかはボタン自体で見せる（NSToolbarItem に on/off の口が無いのでアイコンで表す）。
            let symbol = isFollowingActive ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line"
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
            return canFollow
        case .mrAIDiagnose: return canAIDiagnose
        default:            return true
        }
    }

    /// 構造化表示メニューが開く直前にチェックを付け直す。
    /// JSON 整形は全文を持つ小ファイルのペインだけなので、そこだけ個別に落とす。
    public func menuNeedsUpdate(_ menu: NSMenu) {
        let modes = StructuredMode.allCases
        let current = activeStructuredMode
        for item in menu.items where item.action == #selector(toolbarSetStructuredMode(_:)) {
            if item.tag < 0 {
                item.state = (current == nil) ? .on : .off
                item.isEnabled = canStructured
            } else if item.tag < modes.count {
                let mode = modes[item.tag]
                item.state = (current == mode) ? .on : .off
                item.isEnabled = (mode == .json) ? canStructuredJson : canStructured
            }
        }
    }

    // MARK: 動作

    /// サイドバーを畳む／戻す。幅を 0 にして畳む（`isHidden` だと本文側の制約が浮く）。
    @objc func toolbarToggleSidebar(_ sender: Any?) {
        guard let c = sidebarWidthConstraint else { return }
        let collapsed = c.constant == 0
        c.constant = collapsed ? sidebarWidth : 0
        sidebar.isHidden = !collapsed
    }

    /// 「フィルタ」＝検索バーを開いて一致行フィルタを ON にした状態から始める。
    /// 検索して絞る、という 2 手を 1 手にするのがこのボタンの役目。
    @objc func toolbarShowFilter(_ sender: Any?) {
        guard let v = activeViewer, v.supportsSearch, v.supportsSearchFilter else { NSSound.beep(); return }
        showSearch()
        searchBar.setFilterOn(true)
        refreshSearchBarCapabilities()
        v.setFilterMode(true)
    }

    @objc func toolbarSetStructuredMode(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let modes = StructuredMode.allCases
        setActiveStructuredMode(item.tag < 0 || item.tag >= modes.count ? nil : modes[item.tag])
    }

    @objc func toolbarToggleFollow(_ sender: Any?) { _ = toggleFollow() }
    @objc func toolbarDiagnoseWithAI(_ sender: Any?) { diagnoseSelectionWithAI() }

    @objc func toolbarCompareFiles(_ sender: Any?)          { compareFiles() }
    @objc func toolbarCompareOpenDocuments(_ sender: Any?)   { compareOpenDocuments() }
    @objc func toolbarCompareWithClipboard(_ sender: Any?)   { compareWithClipboard() }
    @objc func toolbarCompareWithURL(_ sender: Any?)         { compareWithURL() }
}
