import AppKit

/// 遠隔の 1 本を見る面（B5）。**手元のビューアとは別の面。**
///
/// 手元のビューアは行インデックスの上に建っていて、それは全体を舐めないと作れない。
/// 遠隔で舐めたら「落とさない」が意味を失う。一方、遠隔で見たいのは
/// **末尾と、絞り込みの結果**だけで、どちらも行番号と本文が既に揃っている
/// （`RemoteLines`）。だから索引の要らない面を別に建てた。
///
/// 用途は**調べ始め**。パターンが決まっているなら `ssh host grep` が 1 行で勝つ。
/// ここが効くのは、grep で当てたあと前後を見て、別の語で絞り直して、また戻る
/// ―― その行き来がコマンドの打ち直しになる場面。
///
/// **手元との継ぎ目はクリップボード。** ⌘C で本文だけを取り出せるので、
/// 手元の文書へ貼るのも、⇧⌘D のクリップボード比較へ渡すのもそのまま通る。
///
/// **その場で直せる（B12）。** 行の本文をダブルクリックして直し、⌘S で向こうへ書く。
/// 転送するのは直した行だけで、書き換えは向こうの `sed` / `head` / `tail` / `dd` が行う
/// （`RemoteFile.replaceLineCommand`）。開いたときと向こうの本文が違っていたら**書かずに止める**。
public final class RemoteWindowController: NSWindowController, NSWindowDelegate {

    private let addressField = NSComboBox()
    private let searchField = NSSearchField()
    private lazy var searchButton = NSButton(title: L("remote.filter"), target: self, action: #selector(runSearch))
    private lazy var followButton = NSButton(title: L("remote.follow"), target: self, action: #selector(toggleFollow))
    private lazy var saveButton = NSButton(title: L("remote.save"), target: self, action: #selector(saveEdits))
    private let contextField = NSTextField()
    private lazy var regexCheck = NSButton(checkboxWithTitle: L("remote.regex"), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = RemoteTableView()
    private let scroll = NSScrollView()
    private let spinner = NSProgressIndicator()

    private var session: RemoteSession?
    private var totalLines: Int?
    private var lines: [RemoteLine] = []
    private var follower: RemoteFollower?
    /// 直したがまだ書いていない行。
    private var edits = RemoteEdits()
    private var saving = false

    /// ssh は遅い。**UI スレッドでは絶対に呼ばない** ―― 1 回の往復で画面が固まると、
    /// 遅さが全部このアプリのせいに見える（M6 の「リモート画面では速度を売らない」）。
    private let work = DispatchQueue(label: "mreditor.remote", qos: .userInitiated)

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("remote.title")
        window.center()
        super.init(window: window)
        window.delegate = self
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    /// **窓を閉じたら追従を止める。** 放っておくと向こうの `tail -f` が生き続ける。
    public func windowWillClose(_ notification: Notification) { stopFollowing() }

    /// 書いていない編集があるまま閉じない。**黙って捨てると、直したことが消える。**
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !edits.isEmpty, !saving else { return !saving }
        let alert = NSAlert()
        alert.messageText = L("remote.unsaved.title", edits.count)
        alert.informativeText = L("remote.unsaved.body")
        alert.addButton(withTitle: L("remote.unsaved.cancel"))
        alert.addButton(withTitle: L("remote.unsaved.discard"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            self.edits.removeAll()
            sender.close()
        }
        return false
    }

    // MARK: - 組み立て

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        addressField.placeholderString = L("remote.addressPlaceholder")
        addressField.target = self
        addressField.action = #selector(connectAndShowTail)
        addressField.completes = true
        addressField.numberOfVisibleItems = RemoteHistory.limit
        addressField.addItems(withObjectValues: RemoteHistory.load())

        let openButton = NSButton(title: L("remote.open"), target: self, action: #selector(connectAndShowTail))
        openButton.keyEquivalent = "\r"

        searchField.placeholderString = L("remote.searchPlaceholder")
        searchField.target = self
        searchField.action = #selector(runSearch)
        searchField.isEnabled = false

        contextField.stringValue = "2"
        contextField.alignment = .right
        contextField.toolTip = L("remote.contextHelp")
        contextField.isEnabled = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        // 行番号と本文の 2 列。等幅で、ログがそのまま読める形に。
        let gutter = NSTableColumn(identifier: .init("line"))
        gutter.title = L("remote.column.line")
        gutter.width = 78
        let bodyColumn = NSTableColumn(identifier: .init("text"))
        bodyColumn.title = L("remote.column.text")
        bodyColumn.width = 760
        table.addTableColumn(gutter)
        table.addTableColumn(bodyColumn)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 16
        table.style = .plain
        // **⌘C はテーブルが受ける。** 第一応答者はテーブルなので、ここに copy: が
        // 無いと応答連鎖が上まで届かず、編集メニューの「コピー」が灰色のままになる
        // （実機で気づいた。メニュー項目が disabled だと、キーを押しても何も起きない）。
        table.onCopy = { [weak self] in self?.copySelection() }
        table.target = self
        table.doubleAction = #selector(beginEditingClickedRow)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false

        let topRow = NSStackView(views: [addressField, openButton])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // **押せる場所を置く。** NSSearchField は Enter でしか走らず、それは画面に
        // 出ていない ＝ 初めて開いた人には「絞れる」ことが分からない。
        searchButton.isEnabled = false
        // トグル型（.pushOnPushOff）にはしない。**入切の状態はタイトルで見せる**
        // ―― 押し込まれているかどうかは、見て分かりにくい。
        followButton.isEnabled = false
        followButton.toolTip = L("remote.followHelp")
        saveButton.isEnabled = false
        saveButton.toolTip = L("remote.saveHelp")
        regexCheck.toolTip = L("remote.regexHelp")
        regexCheck.isEnabled = false
        // **「2」だけでは何の数か分からない**ので、前後に言葉を置く。絞るの一部だと分かるよう、
        // 絞るボタンの直前にまとめ、追う・保存は少し離す。
        let contextLabel = NSTextField(labelWithString: L("remote.context.before"))
        let contextUnit = NSTextField(labelWithString: L("remote.context.after"))
        for l in [contextLabel, contextUnit] { l.textColor = .secondaryLabelColor; l.font = .systemFont(ofSize: 11) }
        let filterGroup = NSStackView(views: [regexCheck, contextLabel, contextField, contextUnit, searchButton])
        filterGroup.orientation = .horizontal
        filterGroup.spacing = 6
        let searchRow = NSStackView(views: [searchField, filterGroup, followButton, saveButton, spinner])
        searchRow.setCustomSpacing(20, after: filterGroup)
        searchRow.orientation = .horizontal
        searchRow.spacing = 8
        contextField.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = NSStackView(views: [topRow, searchRow, scroll, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        topRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        // 開いた直後に打つ場所は住所欄。**どこにもフォーカスが無いと、
        // 応答連鎖が始まらず ⌘C も効かない**（実機で気づいた）。
        window?.initialFirstResponder = addressField
        status(L("remote.hint"))
    }

    // MARK: - 繋ぐ

    /// 繋いで、**まず末尾を出す。** 障害は末尾にある（`less +G` と同じ考え方）。
    @objc private func connectAndShowTail() {
        // 履歴から選んだときは、選んだ項目を読む（選択直後は入力欄の文字列が追いつかないことがある）
        let picked = addressField.indexOfSelectedItem >= 0
            ? addressField.itemObjectValue(at: addressField.indexOfSelectedItem) as? String : nil
        let text = (picked ?? addressField.stringValue).trimmingCharacters(in: .whitespaces)
        addressField.stringValue = text
        guard case .remote(let target) = Intake.resolve(text) else {
            status(L("remote.notRemote"))
            return
        }

        guard edits.isEmpty else {
            status(L("remote.unsavedBlocksOpen"))
            return
        }
        busy(true)
        status(L("remote.connecting", target.host))
        work.async { [weak self] in
            guard let self else { return }
            do {
                let s = try RemoteSession.connect(to: target)
                let tail = s.tailLines(bytes: 64 << 10)
                DispatchQueue.main.async {
                    self.session = s
                    self.lines = tail
                    self.totalLines = nil
                    self.table.reloadData()
                    self.scrollToBottom()
                    self.focusList()
                    self.searchField.isEnabled = s.capabilities.canFilter
                    self.contextField.isEnabled = s.capabilities.canFilter
                    self.regexCheck.isEnabled = s.capabilities.canFilter
                    self.searchButton.isEnabled = s.capabilities.canFilter
                    self.followButton.isEnabled = s.capabilities.canFollow
                    self.busy(false)
                    self.window?.title = "\(target.host):\(target.path)"
                    self.rememberAddress(text)
                    self.reportOpened(s)
                }
                // 行番号は後から埋める。10GB だと向こうで数秒かかるので、開くのは待たせない。
                self.fillLineNumbers(using: s)
            } catch {
                DispatchQueue.main.async {
                    self.busy(false)
                    self.status(Self.describe(error))
                }
            }
        }
    }

    /// 繋げた宛先を履歴の先頭へ。**繋げたものだけ**残す（打ち間違いを溜めない）。
    private func rememberAddress(_ text: String) {
        RemoteHistory.record(text)
        addressField.removeAllItems()
        addressField.addItems(withObjectValues: RemoteHistory.load())
        addressField.stringValue = text
    }

    /// **畳んだ機能は、畳んだ理由ごと出す。** 黙って消えると壊れたように見える。
    private func reportOpened(_ s: RemoteSession) {
        var parts: [String] = [L("remote.openedTail")]
        parts.append(contentsOf: s.capabilities.degraded)
        status(parts.joined(separator: " / "))
    }

    /// `wc -l` は向こうで走る ―― **転送はゼロ**なので、遠隔でも本物の行番号が出せる。
    private func fillLineNumbers(using s: RemoteSession) {
        guard let total = s.lineCount() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === s else { return }
            self.totalLines = total
            // 末尾を出したままなら、番号付きで取り直す（既に検索結果を出していれば触らない）
            if self.lines.allSatisfy({ !$0.isMatch }) {
                self.work.async {
                    let renumbered = s.tailLines(bytes: 64 << 10, totalLines: total)
                    DispatchQueue.main.async {
                        guard self.session === s else { return }
                        self.lines = renumbered
                        self.table.reloadData()
                        self.scrollToBottom()
                        self.status(L("remote.lineCount", total))
                    }
                }
            } else {
                self.status(L("remote.lineCount", total))
            }
        }
    }

    // MARK: - 絞る

    /// **向こうで grep。** 10GB を 1 バイトも転送せずに、一致行と行番号が返る。
    @objc private func runSearch() {
        guard let s = session else { return }
        let pattern = searchField.stringValue
        guard !pattern.isEmpty else {
            work.async { [weak self] in
                guard let self else { return }
                let tail = s.tailLines(bytes: 64 << 10, totalLines: self.totalLines)
                DispatchQueue.main.async {
                    self.lines = tail
                    self.table.reloadData()
                    self.scrollToBottom()
                    self.status(L("remote.openedTail"))
                }
            }
            return
        }

        let context = max(0, min(FilterContext.maxContext, Int(contextField.stringValue) ?? 0))
        let regex = regexCheck.state == .on
        busy(true)
        status(L("remote.searching"))
        work.async { [weak self] in
            guard let self else { return }
            let found = s.searchLines(pattern: pattern, context: context, regex: regex)
            DispatchQueue.main.async {
                self.busy(false)
                guard let found else {
                    return self.status(L(regex ? "remote.regexFailed" : "remote.searchFailed"))
                }
                self.lines = found
                self.table.reloadData()
                if !found.isEmpty { self.table.scrollRowToVisible(0) }
                // **検索欄にフォーカスを残す。** 一覧へ移すと、続けて語を直せない（絞り直しの往復が切れる）。
                let hits = found.filter(\.isMatch).count
                self.status(hits == 0 ? L("remote.noMatch") : L("remote.matchCount", hits))
            }
        }
    }

    // MARK: - 追う

    /// 末尾追従の入切。**向こうの `tail -f` を流し込む。**
    ///
    /// 追い始めたら絞り込みは解いて末尾へ戻す ―― 絞った一覧に新着を足すと、
    /// 一致していない行が混ざって、**絞り込みの意味が壊れる。**
    @objc private func toggleFollow() {
        if follower != nil { return stopFollowing() }
        guard let target = session?.target else { return }

        // 絞り込み中なら末尾へ戻してから追う
        if lines.contains(where: \.isMatch) {
            searchField.stringValue = ""
            runSearch()
        }

        let f = RemoteFollower(target: target)
        f.onLines = { [weak self] incoming in
            guard let self, self.follower === f else { return }
            self.appendFollowed(incoming)
        }
        f.onEnd = { [weak self] in
            guard let self, self.follower === f else { return }
            self.stopFollowing()
            self.status(L("remote.followEnded"))
        }
        follower = f
        followButton.title = L("remote.followStop")
        searchButton.isEnabled = false
        f.start(fromBytes: 0)   // いま出ている末尾に続けるので、新着だけでよい
        status(L("remote.following"))
    }

    private func stopFollowing() {
        follower?.stop()
        follower = nil
        followButton.title = L("remote.follow")
        searchButton.isEnabled = session?.capabilities.canFilter ?? false
    }

    /// 届いた行を末尾へ足す。**行番号は前の行から数える**（向こうへ訊き直さない）。
    private func appendFollowed(_ incoming: [String]) {
        guard !incoming.isEmpty else { return }
        var next = lines.last?.number.map { $0 + 1 }
        for text in incoming {
            lines.append(RemoteLine(number: next, isMatch: false, text: text))
            if let n = next { next = n + 1 }
        }
        if let last = lines.last?.number { totalLines = last }
        table.reloadData()
        scrollToBottom()
    }

    // MARK: - 手元へ持っていく

    /// 選んだ行の**本文だけ**をコピーする。行番号は付けない ――
    /// 付けると本文でなくなり、⇧⌘D のクリップボード比較で全行が差分になる。
    public func copySelection() {
        let source = table.selectedRowIndexes.isEmpty
            ? lines
            : table.selectedRowIndexes.map { lines[$0] }
        // 直してある行は、直したほうをコピーする（画面に見えているものと同じ）
        let picked = source.map { RemoteLine(number: $0.number, isMatch: $0.isMatch, text: edits.text(for: $0)) }
        guard !picked.isEmpty else { return }
        let text = RemoteLines.plainText(picked)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status(L("remote.copied", picked.count))
    }

    // MARK: - 直す・書く（B12）

    /// 本文の列（`buildLayout` で 2 番目に置いている）。
    private static let textColumn = 1

    @objc private func beginEditingClickedRow() {
        let row = table.clickedRow
        guard row >= 0, row < lines.count, canEdit(lines[row]) else { return }
        table.editColumn(Self.textColumn, row: row, with: nil, select: true)
    }

    /// **追っている間は直せない。** 新着のたびに一覧を作り直すので、入力中の欄が消える。
    private func canEdit(_ line: RemoteLine) -> Bool {
        RemoteEdits.isEditable(line) && !saving && follower == nil
    }

    /// 入力欄の確定。直したものは**手元に預かるだけ**で、向こうへは ⌘S まで書かない。
    fileprivate func commitEdit(row: Int, display: String) {
        guard row >= 0, row < lines.count, let number = lines[row].number else { return }
        let line = lines[row]
        let original = edits.edit(at: number)?.original ?? line.text
        guard let raw = RemoteEdits.raw(display: display, original: original) else {
            status(L("remote.editNoNewline"))
            reloadRow(row)
            return
        }
        edits.stage(line: number, original: original, edited: raw)
        reloadRow(row)
        refreshEditState()
        if !edits.isEmpty { status(L("remote.edited", edits.count)) }
    }

    private func reloadRow(_ row: Int) {
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<2))
    }

    /// 保存ボタンと窓の「未保存」印を、預かっている編集に合わせる。
    private func refreshEditState() {
        saveButton.isEnabled = !edits.isEmpty && !saving
        saveButton.title = edits.isEmpty ? L("remote.save") : L("remote.saveN", edits.count)
        window?.isDocumentEdited = !edits.isEmpty
    }

    /// メニューの「保存」を生かす条件。**入力中の欄はまだ預かりに入っていない**ので、
    /// 編集の有無ではなく、繋がっていて書いている最中でないことだけを見る。
    public var canSaveEdits: Bool { session != nil && !saving }

    /// 預かった編集を向こうへ書く（⌘S）。
    ///
    /// 長さの変わる編集（向こうでファイルを作り直す）が混ざるときだけ、書く前に確かめる。
    /// その場の上書きは、1 行だけが変わり、ほかのバイトに触れない。
    @objc public func saveEdits() {
        // 入力中の欄を確定させてから数える（確定前は預かりに入っていない）
        window?.makeFirstResponder(table)
        guard let s = session, !saving else { return }
        guard !edits.isEmpty else { return status(L("remote.nothingToSave")) }

        guard edits.rewriteCount > 0, let window else { return writeEdits(using: s) }
        let alert = NSAlert()
        alert.messageText = L("remote.rewrite.title", edits.rewriteCount)
        alert.informativeText = L("remote.rewrite.body", "\(s.target.host):\(s.target.path)")
        alert.addButton(withTitle: L("remote.rewrite.go"))
        alert.addButton(withTitle: L("remote.rewrite.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.writeEdits(using: s)
        }
    }

    private func writeEdits(using s: RemoteSession) {
        let pending = edits.all
        saving = true
        busy(true)
        refreshEditState()
        table.reloadData()
        status(L("remote.saving", pending.count))

        work.async { [weak self] in
            var done: [(RemoteEdits.Edit, RemoteFile.EditOutcome)] = []
            var failure: String?
            for e in pending {
                do {
                    done.append((e, try s.replaceLine(e.line, old: e.original, new: e.edited)))
                } catch {
                    failure = Self.describeSave(error, line: e.line)
                    break    // 1 件でも止まったら続けない。**途中で止まったことを隠さない。**
                }
            }
            DispatchQueue.main.async { self?.finishSave(done, failure: failure, total: pending.count) }
        }
    }

    private func finishSave(_ done: [(RemoteEdits.Edit, RemoteFile.EditOutcome)], failure: String?, total: Int) {
        saving = false
        busy(false)
        for (edit, _) in done {
            edits.commit(line: edit.line)
            // 書けたので、これが新しい「開いたときの本文」
            for i in lines.indices where lines[i].number == edit.line {
                lines[i] = RemoteLine(number: lines[i].number, isMatch: lines[i].isMatch, text: edit.edited)
            }
        }
        table.reloadData()
        refreshEditState()

        let rewrote = done.filter { $0.1 == .rewrote }.count
        if let failure {
            status(L("remote.saveStopped", done.count, total - done.count, failure))
        } else {
            status(L("remote.saved", done.count, done.count - rewrote, rewrote))
        }
    }

    /// 止まった理由。向こうの stderr は**言い換えず**添える。
    static func describeSave(_ error: Error, line: Int) -> String {
        guard let failure = error as? RemoteSession.EditFailure else { return describe(error) }
        let detail = failure.detail.isEmpty ? "" : "（\(failure.detail)）"
        switch failure.outcome {
        case .conflict:         return L("remote.err.conflict", line)
        case .notWritable:      return L("remote.err.notWritable")
        case .cannotCreateTemp: return L("remote.err.noTemp")
        case .noSuchLine:       return L("remote.err.noLine", line)
        case .missingTool:      return L("remote.err.missingTool") + detail
        case .writeFailed:      return L("remote.err.writeFailed") + detail
        case .overwrote, .rewrote: return detail
        }
    }

    // MARK: - 小物

    /// 一覧へフォーカスを移す。**矢印で辿れるようになり、⌘C も効くようになる。**
    /// 第一応答者が居ないと応答連鎖がテーブルまで降りず、編集メニューの
    /// 「コピー」が灰色のままになる。
    private func focusList() {
        guard !lines.isEmpty else { return }
        window?.makeFirstResponder(table)
        if table.selectedRowIndexes.isEmpty {
            table.selectRowIndexes(IndexSet(integer: max(0, lines.count - 1)), byExtendingSelection: false)
        }
    }

    private func scrollToBottom() {
        guard !lines.isEmpty else { return }
        table.scrollRowToVisible(lines.count - 1)
    }

    private func busy(_ on: Bool) {
        on ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    private func status(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    /// 失敗の理由は**言い換えない。** 「Permission denied」「No such file」は
    /// 人が読めば分かるし、こちらで丸めると原因が消える。
    static func describe(_ error: Error) -> String {
        switch error {
        case RemoteSession.Failure.timedOut:            return L("remote.timedOut")
        case RemoteSession.Failure.cannotRead:          return L("remote.cannotRead")
        case RemoteSession.Failure.launchFailed(let m): return m
        case RemoteSession.Failure.failed(_, let err):  return err.isEmpty ? L("remote.searchFailed") : err
        default:                                        return String(describing: error)
        }
    }
}

// MARK: - 入力欄

extension RemoteWindowController: NSTextFieldDelegate {
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        commitEdit(row: table.row(for: field), display: field.stringValue)
    }
}

// MARK: - 一覧

extension RemoteWindowController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let line = lines[row]
        let isGutter = column?.identifier.rawValue == "line"

        let field = NSTextField(labelWithString: "")
        field.font = .monospacedSystemFont(ofSize: 11, weight: line.isMatch ? .bold : .regular)
        field.lineBreakMode = .byTruncatingTail

        if isGutter {
            // 数えていなければ空にする。**0 とも 1 とも書かない。**
            field.stringValue = line.number.map(String.init) ?? ""
            field.alignment = .right
            field.textColor = .tertiaryLabelColor
        } else {
            let edited = line.number.flatMap { edits.edit(at: $0) } != nil
            field.stringValue = RemoteEdits.display(edits.text(for: line))
            // 当たりだけを立てる。前後（`grep -C`）は落として、目が当たりへ行くように。
            field.textColor = line.isMatch ? .labelColor : .secondaryLabelColor
            // 直してある行は色を変える。**まだ向こうには書いていない**と分かるように。
            if edited { field.textColor = .systemOrange }
            if canEdit(line) {
                field.isEditable = true
                field.isSelectable = true
                field.delegate = self
                field.lineBreakMode = .byClipping
            }
        }
        return field
    }
}

/// `⌘C` を受けるためだけの `NSTableView`。
///
/// 第一応答者はこのテーブルなので、**ここに `copy:` が無いと編集メニューの
/// 「コピー」が灰色のまま**になり、キーを押しても何も起きない。
/// ウィンドウコントローラに実装しても、応答連鎖がそこまで降りてこない。
final class RemoteTableView: NSTableView {
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }

    /// 選ぶものが無ければ灰色にする（押せるのに何も起きない、を作らない）。
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return numberOfRows > 0 }
        return super.validateUserInterfaceItem(item)
    }
}
