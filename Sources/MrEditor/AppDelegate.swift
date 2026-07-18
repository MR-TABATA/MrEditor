import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowController: MainWindowController?
    private var followItem: NSMenuItem?
    private var recentMenu: NSMenu?
    private var preferencesController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 開発ビルド（バンドル無し）でも Dock・About でアプリアイコンを出す。
        // 配布 .app では CFBundleIconFile によりシステムが設定するため上書きは無害。
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        buildMenu()

        // Finder からの起動では open(_:) がここより先に届きうる。作り直すと
        // そのとき開いたドキュメントを取りこぼすため、既にあれば使い回す。
        let controller = ensureController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // カラーパネルを復元させない。
        //
        // NSColorPanel は macOS のウィンドウ復元の対象なので、環境設定で一度色を選ぶと、
        // **以後アプリを起動するたびに勝手に開く**。起動直後に色を選びたい人はいない。
        let colorPanel = NSColorPanel.shared
        colorPanel.isRestorable = false
        DispatchQueue.main.async { if colorPanel.isVisible { colorPanel.close() } }

        // コマンドライン引数で渡されたパスを全て開く。
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in args {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { controller.open(url: url) }
        }

        // 前回終了時のファイル一覧を復元する。**ファイルを開いて起動したときも必ず呼ぶ**：
        // 復元を飛ばすと、起動時のオープンが前回のセッション（未保存の新規の本文を含む）を
        // 書き潰してしまう。開いたファイルを優先する判断は restoreSession 側が持つ。
        // ウィンドウが表示され切ってから復元する（同期実行だと復元直後のペインが
        // 初回描画されず、操作するまで本文が空に見える問題を避ける）。
        DispatchQueue.main.async { controller.restoreSession() }

        // App Store 配布ではないので、新版の存在は自分で知らせる必要がある。
        // 1 日 1 回まで・新版があるときだけ喋る（失敗は黙って捨てる）。
        UpdateChecker.check(manual: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// 他のアプリへ切り替えた時点で未保存の本文をディスクへ書き出す。
    /// 打鍵のデバウンス待ちのまま落ちても（クラッシュ・強制終了）失わないため。
    func applicationDidResignActive(_ notification: Notification) {
        windowController?.flushDrafts()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = windowController else { return .terminateNow }
        return c.confirmTerminate() ? .terminateNow : .terminateCancel
    }

    // Finder からの「で開く」/ ファイルドロップ（複数可）
    func application(_ application: NSApplication, open urls: [URL]) {
        let c = ensureController()
        urls.forEach { c.open(url: $0) }
    }

    private func ensureController() -> MainWindowController {
        if let c = windowController { return c }
        let c = MainWindowController()
        windowController = c
        return c
    }

    @objc private func showAbout(_ sender: Any?) {
        // バンドル未使用（開発ビルド）でも名前・バージョンが正しく出るよう明示指定する。
        // `.version`（括弧内のビルド番号）は空にして重複表示を抑える。
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: "",
            .credits: aboutCredits(),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// About パネル下部の説明文。タグライン（本文色）＋著作権表示（副次色・小さめ）を
    /// 中央寄せで積む。文言はローカライズ（ja/en）から引く。
    private func aboutCredits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2

        let credits = NSMutableAttributedString(
            string: L("about.credits"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
        credits.append(NSAttributedString(
            string: "\n\n" + L("about.copyright"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        return credits
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        UpdateChecker.check(manual: true)   // 明示的な呼び出しは結果を必ず知らせる
    }

    @objc private func newDocument(_ sender: Any?) {
        ensureController().newDocument()
    }

    @objc private func openDocument(_ sender: Any?) {
        ensureController().openDocument(sender)
    }

    @objc private func performFind(_ sender: Any?) {
        windowController?.showSearch()
    }

    @objc private func performFindNext(_ sender: Any?) { windowController?.findNext() }
    @objc private func performFindPrev(_ sender: Any?) { windowController?.findPrev() }

    @objc private func performCloseDocument(_ sender: Any?) {
        if let c = windowController { c.closeActiveDocument() } else { NSApp.keyWindow?.performClose(nil) }
    }

    @objc private func performSave(_ sender: Any?) { windowController?.saveActiveDocument() }
    @objc private func performSaveAs(_ sender: Any?) { windowController?.saveActiveDocumentAs() }
    @objc private func performRevert(_ sender: Any?) { windowController?.revertActiveDocument() }
    @objc private func performPrint(_ sender: Any?) { windowController?.printActiveDocument() }

    @objc private func reopenWithEncoding(_ sender: NSMenuItem) {
        let list = DetectedEncoding.selectable
        guard sender.tag >= 0, sender.tag < list.count else { return }
        windowController?.reopenActiveDocument(withEncoding: list[sender.tag])
    }

    @objc private func setSaveEncoding(_ sender: NSMenuItem) {
        let list = DetectedEncoding.selectable
        guard sender.tag >= 0, sender.tag < list.count else { return }
        windowController?.setActiveSaveEncoding(to: list[sender.tag])
    }

    @objc private func performGoToLine(_ sender: Any?) { windowController?.promptGoToLine() }

    @objc private func performZoomIn(_ sender: Any?) { windowController?.zoomIn() }
    @objc private func performZoomOut(_ sender: Any?) { windowController?.zoomOut() }
    @objc private func performZoomReset(_ sender: Any?) { windowController?.zoomReset() }

    // 比較（diff）。4 つの入口とも windowController が同じ DiffViewer へ流す。
    @objc private func compareFiles(_ sender: Any?)         { windowController?.compareFiles() }
    @objc private func compareOpenDocuments(_ sender: Any?) { windowController?.compareOpenDocuments() }
    @objc private func compareWithClipboard(_ sender: Any?) { windowController?.compareWithClipboard() }
    @objc private func compareWithURL(_ sender: Any?)       { windowController?.compareWithURL() }
    @objc private func nextDifference(_ sender: Any?)       { windowController?.activeDiffViewer?.nextHunk() }
    @objc private func adoptHunk(_ sender: Any?)            { windowController?.activeDiffViewer?.adoptCurrentHunk() }
    @objc private func revertHunk(_ sender: Any?)           { windowController?.activeDiffViewer?.revertCurrentHunk() }
    @objc private func saveMergedResult(_ sender: Any?)     { windowController?.activeDiffViewer?.saveMerged() }
    @objc private func previousDifference(_ sender: Any?)   { windowController?.activeDiffViewer?.previousHunk() }

    @objc private func setStructuredMode(_ sender: NSMenuItem) {
        let modes = StructuredMode.allCases
        let mode: StructuredMode? = (sender.tag >= 0 && sender.tag < modes.count) ? modes[sender.tag] : nil
        windowController?.setActiveStructuredMode(mode)
    }

    @objc private func toggleJsonQuery(_ sender: NSMenuItem) {
        windowController?.toggleActiveJsonQuery()
    }

    @objc private func applyTextTransform(_ sender: NSMenuItem) {
        guard let t = TextTransform(rawValue: sender.tag) else { return }
        windowController?.applyActiveTextTransform(t)
    }

    @objc private func filterThroughCommand(_ sender: Any?) {
        windowController?.filterActiveSelectionThroughCommand()
    }

    // MARK: - 最近使った項目

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        ensureController().open(url: url)
    }

    @objc private func clearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    /// File ＞ 最近使った項目 サブメニューを開くたびに再構築する。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let empty = NSMenuItem(title: L("menu.recentEmpty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L("menu.clearRecent"),
                               action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func performFollow(_ sender: Any?) {
        let on = windowController?.toggleFollow() ?? false
        followItem?.state = on ? .on : .off
    }

    // MARK: - メニュー有効/無効

    /// アクティブなドキュメントの能力に応じてメニュー項目を有効/無効にする。
    /// （target nil の編集系＝Undo/Cut 等は NSTextView が自動で検証する。）
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let c = windowController else { return true }
        switch item.action {
        case #selector(performSave(_:)), #selector(performSaveAs(_:)):
            return c.canSave
        case #selector(performRevert(_:)):
            return c.canRevert
        case #selector(performPrint(_:)):
            return c.canPrint   // 巨大ファイルは印刷不可（数百万ページになる）
        case #selector(reopenWithEncoding(_:)):
            let list = DetectedEncoding.selectable
            if item.tag >= 0, item.tag < list.count {
                item.state = (c.activeEncoding == list[item.tag]) ? .on : .off
            }
            return c.canReopenWithEncoding
        case #selector(setSaveEncoding(_:)):
            // 現在の保存エンコードにチェックを付ける（選び直しは自由なので有効のまま）。
            let list = DetectedEncoding.selectable
            if item.tag >= 0, item.tag < list.count {
                item.state = (c.activeSaveEncoding == list[item.tag]) ? .on : .off
            }
            return c.canSave
        case #selector(performFind(_:)), #selector(performFindNext(_:)), #selector(performFindPrev(_:)):
            return c.canSearch
        case #selector(performFollow(_:)):
            item.state = c.isFollowingActive ? .on : .off
            return c.canFollow
        case #selector(performGoToLine(_:)), #selector(performCloseDocument(_:)):
            return c.hasActiveDocument
        case #selector(nextDifference(_:)), #selector(previousDifference(_:)):
            return c.activeDiffViewer != nil
        case #selector(adoptHunk(_:)), #selector(revertHunk(_:)):
            return c.activeDiffViewer?.hasCurrentHunk ?? false
        case #selector(saveMergedResult(_:)):
            return c.activeDiffViewer != nil
        case #selector(setStructuredMode(_:)):
            let modes = StructuredMode.allCases
            let current = c.activeStructuredMode
            if item.tag < 0 { item.state = (current == nil) ? .on : .off }
            else if item.tag < modes.count { item.state = (current == modes[item.tag]) ? .on : .off }
            // JSON 整形は全文を保持する小ファイルペインのみ（大ファイルは項目を無効化）。
            if item.tag >= 0, item.tag < modes.count, modes[item.tag] == .json { return c.canStructuredJson }
            return c.canStructured
        case #selector(toggleJsonQuery(_:)):
            item.state = c.jsonQueryIsActive ? .on : .off
            return c.canJsonQuery
        case #selector(applyTextTransform(_:)), #selector(filterThroughCommand(_:)):
            return c.canTransformText   // 編集可能なペインでのみ有効

        default:
            return true
        }
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
        let aboutItem = NSMenuItem(title: L("menu.about", appName),
                                   action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        let updateItem = NSMenuItem(title: L("menu.checkForUpdates"),
                                    action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())
        let prefsItem = NSMenuItem(title: L("menu.preferences"),
                                   action: #selector(openPreferences(_:)), keyEquivalent: ",")
        prefsItem.target = self
        appMenu.addItem(prefsItem)
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
        let newItem = NSMenuItem(title: L("menu.new"),
                                 action: #selector(newDocument(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        let openItem = NSMenuItem(title: L("menu.open"),
                                  action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        // 最近使った項目（サブメニューは開くたびに menuNeedsUpdate で再構築）
        let recentItem = NSMenuItem(title: L("menu.openRecent"), action: nil, keyEquivalent: "")
        let recent = NSMenu(title: L("menu.openRecent"))
        recent.delegate = self
        recentItem.submenu = recent
        fileMenu.addItem(recentItem)
        self.recentMenu = recent
        fileMenu.addItem(.separator())
        let saveItem = NSMenuItem(title: L("menu.save"),
                                  action: #selector(performSave(_:)), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)
        let saveAsItem = NSMenuItem(title: L("menu.saveAs"),
                                    action: #selector(performSaveAs(_:)), keyEquivalent: "S")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = self
        fileMenu.addItem(saveAsItem)
        let revertItem = NSMenuItem(title: L("menu.revert"),
                                    action: #selector(performRevert(_:)), keyEquivalent: "")
        revertItem.target = self
        fileMenu.addItem(revertItem)
        // エンコーディングを指定して開き直す（自動判定ミスの文字化けを直す）
        let reopenItem = NSMenuItem(title: L("menu.reopenWithEncoding"), action: nil, keyEquivalent: "")
        let reopenMenu = NSMenu(title: L("menu.reopenWithEncoding"))
        for (i, enc) in DetectedEncoding.selectable.enumerated() {
            let it = NSMenuItem(title: enc.displayName,
                                action: #selector(reopenWithEncoding(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            reopenMenu.addItem(it)
        }
        reopenItem.submenu = reopenMenu
        fileMenu.addItem(reopenItem)
        // テキストエンコーディング（保存時に書き出すエンコードを設定。反映は次の保存で）
        let encItem = NSMenuItem(title: L("menu.textEncoding"), action: nil, keyEquivalent: "")
        let encMenu = NSMenu(title: L("menu.textEncoding"))
        for (i, enc) in DetectedEncoding.selectable.enumerated() {
            let it = NSMenuItem(title: enc.displayName,
                                action: #selector(setSaveEncoding(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            encMenu.addItem(it)
        }
        encItem.submenu = encMenu
        fileMenu.addItem(encItem)
        fileMenu.addItem(.separator())
        // プリント（ダイアログの「PDF ▸ PDF として保存」で PDF 出力も兼ねる）。
        let printItem = NSMenuItem(title: L("menu.print"),
                                   action: #selector(performPrint(_:)), keyEquivalent: "p")
        printItem.target = self
        fileMenu.addItem(printItem)
        fileMenu.addItem(.separator())
        let closeItem = NSMenuItem(title: L("menu.close"),
                                   action: #selector(performCloseDocument(_:)), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)

        // 編集メニュー（検索）
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        // アンドゥ／リドゥ（⌘Z / ⌘⇧Z）: target nil でレスポンダチェーン（NSTextView）へ。
        let undoItem = NSMenuItem(title: L("menu.undo"),
                                  action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: L("menu.redo"),
                                  action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        // 切り取り／コピー／貼り付け／全選択: target nil でレスポンダチェーンへ
        // （編集ペインは NSTextView、ビューアはコピーのみ DocumentView が処理）。
        let cutItem = NSMenuItem(title: L("menu.cut"),
                                 action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(cutItem)
        let copyItem = NSMenuItem(title: L("menu.copy"),
                                  action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: L("menu.paste"),
                                   action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(pasteItem)
        let selectAllItem = NSMenuItem(title: L("menu.selectAll"),
                                       action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(selectAllItem)
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: L("menu.find"),
                                  action: #selector(performFind(_:)), keyEquivalent: "f")
        findItem.target = self
        editMenu.addItem(findItem)
        let findNextItem = NSMenuItem(title: L("menu.findNext"),
                                      action: #selector(performFindNext(_:)), keyEquivalent: "g")
        findNextItem.target = self
        editMenu.addItem(findNextItem)
        let findPrevItem = NSMenuItem(title: L("menu.findPrev"),
                                      action: #selector(performFindPrev(_:)), keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findPrevItem.target = self
        editMenu.addItem(findPrevItem)

        // 書式メニュー（編集ツールボックス：選択テキストの変換）
        let formatMenuItem = NSMenuItem()
        mainMenu.addItem(formatMenuItem)
        let formatMenu = NSMenu(title: L("menu.format"))
        formatMenuItem.submenu = formatMenu
        for t in TextTransform.allCases {
            let it = NSMenuItem(title: L(t.localizationKey),
                                action: #selector(applyTextTransform(_:)), keyEquivalent: "")
            it.tag = t.rawValue
            it.target = self
            formatMenu.addItem(it)
        }
        formatMenu.addItem(.separator())
        // 選択を外部コマンドに通して置換（sort / jq / sed … その場フィルタ）。
        let filterItem = NSMenuItem(title: L("menu.format.filter"),
                                    action: #selector(filterThroughCommand(_:)), keyEquivalent: "r")
        filterItem.keyEquivalentModifierMask = [.command, .option]
        filterItem.target = self
        formatMenu.addItem(filterItem)

        // 表示メニュー（末尾追従）
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        let gotoItem = NSMenuItem(title: L("menu.gotoLine"),
                                  action: #selector(performGoToLine(_:)), keyEquivalent: "l")
        gotoItem.target = self
        viewMenu.addItem(gotoItem)
        viewMenu.addItem(.separator())
        // フォント拡大縮小
        let zoomIn = NSMenuItem(title: L("menu.zoomIn"),
                                action: #selector(performZoomIn(_:)), keyEquivalent: "+")
        zoomIn.target = self
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: L("menu.zoomOut"),
                                 action: #selector(performZoomOut(_:)), keyEquivalent: "-")
        zoomOut.target = self
        viewMenu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: L("menu.zoomReset"),
                                   action: #selector(performZoomReset(_:)), keyEquivalent: "0")
        zoomReset.target = self
        viewMenu.addItem(zoomReset)
        viewMenu.addItem(.separator())
        let follow = NSMenuItem(title: L("menu.follow"),
                                action: #selector(performFollow(_:)), keyEquivalent: "f")
        follow.keyEquivalentModifierMask = [.command, .option]
        follow.target = self
        viewMenu.addItem(follow)
        self.followItem = follow

        // 構造化表示（CSV/TSV/NDJSON の読み取り専用整形）
        viewMenu.addItem(.separator())
        let structMenu = NSMenu(title: L("menu.structured"))
        let offItem = NSMenuItem(title: L("menu.structured.off"),
                                 action: #selector(setStructuredMode(_:)), keyEquivalent: "")
        offItem.tag = -1; offItem.target = self
        structMenu.addItem(offItem)
        structMenu.addItem(.separator())
        for (i, m) in StructuredMode.allCases.enumerated() {
            let it = NSMenuItem(title: L("menu.structured.\(m.rawValue)"),
                                action: #selector(setStructuredMode(_:)), keyEquivalent: "")
            it.tag = i; it.target = self
            structMenu.addItem(it)
        }
        let structItem = NSMenuItem(title: L("menu.structured"), action: nil, keyEquivalent: "")
        structItem.submenu = structMenu
        viewMenu.addItem(structItem)

        // JSON その場クエリ（jmespath 相当・結果は揮発）。
        let queryItem = NSMenuItem(title: L("menu.jsonquery"),
                                   action: #selector(toggleJsonQuery(_:)), keyEquivalent: "j")
        queryItem.keyEquivalentModifierMask = [.command, .option]
        queryItem.target = self
        viewMenu.addItem(queryItem)

        // 比較（diff）。入口は 4 つあるが、行き先は同じ DiffViewer。
        viewMenu.addItem(.separator())
        let diffMenu = NSMenu(title: L("menu.compare"))
        let cmpFiles = NSMenuItem(title: L("menu.compare.files"),
                                  action: #selector(compareFiles(_:)), keyEquivalent: "d")
        cmpFiles.keyEquivalentModifierMask = [.command, .shift]
        cmpFiles.target = self
        diffMenu.addItem(cmpFiles)
        let cmpOpen = NSMenuItem(title: L("menu.compare.openDocs"),
                                 action: #selector(compareOpenDocuments(_:)), keyEquivalent: "")
        cmpOpen.target = self
        diffMenu.addItem(cmpOpen)
        let cmpClip = NSMenuItem(title: L("menu.compare.clipboard"),
                                 action: #selector(compareWithClipboard(_:)), keyEquivalent: "")
        cmpClip.target = self
        diffMenu.addItem(cmpClip)
        let cmpURL = NSMenuItem(title: L("menu.compare.url"),
                                action: #selector(compareWithURL(_:)), keyEquivalent: "")
        cmpURL.target = self
        diffMenu.addItem(cmpURL)
        diffMenu.addItem(.separator())
        let nextHunk = NSMenuItem(title: L("menu.compare.next"),
                                  action: #selector(nextDifference(_:)), keyEquivalent: "]")
        nextHunk.keyEquivalentModifierMask = [.command, .shift]
        nextHunk.target = self
        diffMenu.addItem(nextHunk)
        let prevHunk = NSMenuItem(title: L("menu.compare.previous"),
                                  action: #selector(previousDifference(_:)), keyEquivalent: "[")
        prevHunk.keyEquivalentModifierMask = [.command, .shift]
        prevHunk.target = self
        diffMenu.addItem(prevHunk)
        diffMenu.addItem(.separator())
        let adopt = NSMenuItem(title: L("menu.compare.adopt"),
                               action: #selector(adoptHunk(_:)), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        adopt.keyEquivalentModifierMask = [.option]
        adopt.target = self
        diffMenu.addItem(adopt)
        let revert = NSMenuItem(title: L("menu.compare.revert"),
                                action: #selector(revertHunk(_:)), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        revert.keyEquivalentModifierMask = [.option]
        revert.target = self
        diffMenu.addItem(revert)
        let saveMerged = NSMenuItem(title: L("menu.compare.saveMerged"),
                                    action: #selector(saveMergedResult(_:)), keyEquivalent: "")
        saveMerged.target = self
        diffMenu.addItem(saveMerged)

        let diffItem = NSMenuItem(title: L("menu.compare"), action: nil, keyEquivalent: "")
        diffItem.submenu = diffMenu
        viewMenu.addItem(diffItem)

        // ウインドウメニュー（Minimize / Zoom ＋ 開いているウィンドウ一覧を AppKit が自動追記）
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: L("menu.window"))
        windowMenuItem.submenu = windowMenu
        // target nil でレスポンダチェーン（キーウィンドウ）へ委譲。
        let minimize = NSMenuItem(title: L("menu.minimize"),
                                  action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(minimize)
        let zoomWindow = NSMenuItem(title: L("menu.zoomWindow"),
                                    action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(zoomWindow)
        windowMenu.addItem(.separator())
        let bringAllToFront = NSMenuItem(title: L("menu.bringAllToFront"),
                                         action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenu.addItem(bringAllToFront)
        NSApp.windowsMenu = windowMenu   // 以降、開いているウィンドウがここに自動で並ぶ。

        // ヘルプメニュー
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: L("menu.help"))
        helpMenuItem.submenu = helpMenu
        let appHelp = NSMenuItem(title: L("menu.appHelp", AppInfo.name),
                                 action: #selector(openHelp(_:)), keyEquivalent: "?")
        appHelp.target = self
        helpMenu.addItem(appHelp)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.helpURL)
    }

    @objc private func openPreferences(_ sender: Any?) {
        if preferencesController == nil { preferencesController = PreferencesWindowController() }
        preferencesController?.show()
    }
}
