import AppKit

/// フォルダのツリー（展開式）と、名前で絞って開く欄。**手元の窓と遠隔の窓で同じ部品を使う。**
///
/// - 展開するたびに、その直下だけを読む（全体は舐めない）。遠隔では 1 回の ssh 往復。
/// - 上の欄に語を入れて Enter で、起点の下から**名前に語を含むファイル**を探して並べる
///   （本文は見ない。フォルダ全体の本文検索は Pro の線）。欄を空にして Enter で、ツリーへ戻る。
/// - ファイルはダブルクリック（または Return）で開く。フォルダは開閉。
final class FileTreeView: NSView {

    private let filterField = NSSearchField()
    private let outline = FileOutlineView()
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private var provider: DirectoryProvider
    private var root: FileNode?
    /// 名前検索の結果。`nil` のときはツリーを出す。
    private var results: [FileNode]?
    /// 古い応答を捨てるための世代（検索を打ち直したとき、前の結果が後から来て上書きしない）。
    private var searchGeneration = 0

    private let work = DispatchQueue(label: "mreditor.filetree", qos: .userInitiated)

    /// ファイルを開く。
    var onOpenFile: ((FileNode) -> Void)?
    /// 状態の文言（窓の下のラベルに出してもらう）。
    var onStatus: ((String) -> Void)?

    init(provider: DirectoryProvider) {
        self.provider = provider
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    // MARK: - 組み立て

    private func build() {
        filterField.placeholderString = L("tree.filterPlaceholder")
        filterField.toolTip = L("tree.filterHelp")
        filterField.target = self
        filterField.action = #selector(runFilter)
        filterField.sendsSearchStringImmediately = false

        let column = NSTableColumn(identifier: .init("name"))
        column.title = L("tree.column")
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = 20
        outline.style = .sourceList
        outline.allowsMultipleSelection = false
        outline.target = self
        outline.doubleAction = #selector(activateSelection)
        outline.onReturn = { [weak self] in self?.activateSelection() }

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        let bottom = NSStackView(views: [statusLabel, spinner])
        bottom.orientation = .horizontal
        bottom.spacing = 6

        let stack = NSStackView(views: [filterField, scroll, bottom])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        filterField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
    }

    // MARK: - 起点

    /// 起点のフォルダを置いて、直下を読む。
    func setRoot(path: String, displayName: String? = nil, provider newProvider: DirectoryProvider? = nil) {
        if let newProvider { provider = newProvider }
        searchGeneration += 1
        filterField.stringValue = ""
        results = nil
        let node = FileNode(name: displayName ?? path, path: path, isDirectory: true)
        root = node
        outline.reloadData()
        load(node, thenExpand: true)
    }

    /// 名前検索の入力欄へフォーカスを移す。
    func focusFilter() { window?.makeFirstResponder(filterField) }

    // MARK: - 読み込み

    /// 直下を裏で読んで、終わったら差し込む。**展開は読み終わってから。**
    private func load(_ node: FileNode, thenExpand: Bool = false) {
        guard !node.isLoading else { return }
        node.isLoading = true
        spin(true)
        let provider = self.provider
        work.async { [weak self] in
            let outcome = Result { try provider.list(node.path) }
            DispatchQueue.main.async {
                guard let self else { return }
                node.isLoading = false
                self.spin(false)
                switch outcome {
                case .success(let r):
                    node.children = r.nodes
                    node.truncated = r.truncated
                    // ルートは `outline` の最上位なので全体を、途中のフォルダはその子だけ作り直す
                    if node === self.root { self.outline.reloadData() } else { self.outline.reloadItem(node, reloadChildren: true) }
                    if thenExpand, node !== self.root { self.outline.expandItem(node) }
                    if r.truncated {
                        self.say(L("tree.truncated", r.nodes.count))
                    } else if r.nodes.isEmpty {
                        self.say(L("tree.empty"))
                    } else {
                        self.say(L("tree.count", r.nodes.count))
                    }
                case .failure(let error):
                    // 開けなかったフォルダは「空」ではなく、理由つきで失敗として見せる
                    node.children = nil
                    self.outline.reloadItem(node === self.root ? nil : node, reloadChildren: true)
                    self.say(provider.describe(error))
                }
            }
        }
    }

    // MARK: - 名前で絞る

    @objc private func runFilter() {
        let term = filterField.stringValue.trimmingCharacters(in: .whitespaces)
        searchGeneration += 1
        guard !term.isEmpty else {
            results = nil
            outline.reloadData()
            if let kids = root?.children { say(L("tree.count", kids.count)) }
            return
        }
        guard let root else { return }
        let generation = searchGeneration
        let provider = self.provider
        spin(true)
        say(L("tree.searching"))
        work.async { [weak self] in
            let outcome = Result { try provider.search(root: root.path, term: term) }
            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration else { return }   // 古い応答は捨てる
                self.spin(false)
                switch outcome {
                case .success(let r):
                    self.results = r.nodes
                    self.outline.reloadData()
                    if r.nodes.isEmpty {
                        self.say(L("tree.noMatch"))
                    } else if r.truncated {
                        self.say(L("tree.matchTruncated", r.nodes.count))
                    } else {
                        self.say(L("tree.matchCount", r.nodes.count))
                    }
                case .failure(let error):
                    self.say(provider.describe(error))
                }
            }
        }
    }

    // MARK: - 開く

    @objc private func activateSelection() {
        let row = outline.clickedRow >= 0 && outline.selectedRow < 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpenFile?(node)
        }
    }

    private func say(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        onStatus?(text)
    }

    private func spin(_ on: Bool) { on ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) }
}

// MARK: - データ

extension FileTreeView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    private func childrenOf(_ item: Any?) -> [FileNode] {
        if let results { return item == nil ? results : [] }       // 検索結果は平らな一覧
        if let node = item as? FileNode { return node.children ?? [] }
        return root?.children ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        childrenOf(item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        childrenOf(item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        results == nil && ((item as? FileNode)?.isDirectory ?? false)
    }

    /// 展開されたとき、まだ読んでいなければ読む。
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard results == nil, let node = notification.userInfo?["NSObject"] as? FileNode,
              node.children == nil else { return }
        load(node)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView()
        let symbol = node.isDirectory ? "folder" : "doc.text"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = node.isDirectory ? .systemBlue : .secondaryLabelColor
        let label = NSTextField(labelWithString: node.name)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = node.path
        for v in [icon, label] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// Return / Enter でも開けるようにするための `NSOutlineView`。
final class FileOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        super.keyDown(with: event)
    }
}
