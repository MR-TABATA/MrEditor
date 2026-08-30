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
public final class RemoteWindowController: NSWindowController, NSWindowDelegate {

    private let addressField = NSTextField()
    private let searchField = NSSearchField()
    private lazy var searchButton = NSButton(title: L("remote.filter"), target: self, action: #selector(runSearch))
    private lazy var followButton = NSButton(title: L("remote.follow"), target: self, action: #selector(toggleFollow))
    private let contextField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = RemoteTableView()
    private let scroll = NSScrollView()
    private let spinner = NSProgressIndicator()

    private var session: RemoteSession?
    private var totalLines: Int?
    private var lines: [RemoteLine] = []
    private var follower: RemoteFollower?

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

    // MARK: - 組み立て

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        addressField.placeholderString = L("remote.addressPlaceholder")
        addressField.target = self
        addressField.action = #selector(connectAndShowTail)

        let openButton = NSButton(title: L("remote.open"), target: self, action: #selector(connectAndShowTail))
        openButton.keyEquivalent = "\r"

        searchField.placeholderString = L("remote.searchPlaceholder")
        searchField.target = self
        searchField.action = #selector(runSearch)
        searchField.isEnabled = false

        contextField.placeholderString = "±"
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
        let searchRow = NSStackView(views: [searchField, contextField, searchButton, followButton, spinner])
        searchRow.orientation = .horizontal
        searchRow.spacing = 8
        contextField.widthAnchor.constraint(equalToConstant: 52).isActive = true

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
        let text = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        guard case .remote(let target) = Intake.resolve(text) else {
            status(L("remote.notRemote"))
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
                    self.searchButton.isEnabled = s.capabilities.canFilter
                    self.followButton.isEnabled = s.capabilities.canFollow
                    self.busy(false)
                    self.window?.title = "\(target.host):\(target.path)"
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
        busy(true)
        status(L("remote.searching"))
        work.async { [weak self] in
            guard let self else { return }
            let found = s.searchLines(pattern: pattern, context: context)
            DispatchQueue.main.async {
                self.busy(false)
                guard let found else { return self.status(L("remote.searchFailed")) }
                self.lines = found
                self.table.reloadData()
                if !found.isEmpty { self.table.scrollRowToVisible(0) }
                self.focusList()
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
        let picked = table.selectedRowIndexes.isEmpty
            ? lines
            : table.selectedRowIndexes.map { lines[$0] }
        guard !picked.isEmpty else { return }
        let text = RemoteLines.plainText(picked)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status(L("remote.copied", picked.count))
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
            field.stringValue = line.text
            // 当たりだけを立てる。前後（`grep -C`）は落として、目が当たりへ行くように。
            field.textColor = line.isMatch ? .labelColor : .secondaryLabelColor
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
