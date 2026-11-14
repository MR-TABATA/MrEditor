import AppKit

/// C5「フォルダを横断して検索」の画面。
///
/// **結果をクリックしたらそのファイルのその行が開く**——rg の出力を目で追ってエディタで
/// 開き直す往復を消すのが、この機能の値打ち。結果は 2 段のツリー（ファイル → 行）で、
/// 走査中も**見つかった順に**出す（全部終わるまで待たせない）。
final class CrossFileSearchView: NSView, AnalysisFeatureView {

    var onStateChange: ((String, Bool, Double) -> Void)?
    /// 走らせ直しは枠に頼む（手元の写しで走ると、絞り込みを変えた後にズレる）。
    var onRequestRun: (() -> Void)?
    /// そのファイルのその行を開く（行は **1 始まり**）。
    var onOpenLine: ((URL, Int) -> Void)?
    /// 結果の右クリック →「この一致を集計」。(ファイル, 取り出し式, 大小を区別するか)。
    /// 検索した式をそのまま C1 の「正規表現」に渡す。
    var onAggregateHit: ((URL, String, Bool) -> Void)?
    /// 直近の検索の式。**入力欄は検索後に書き換えられる**ので、集計へは検索したときの式を渡す。
    private var lastQuery: (pattern: String, regex: Bool, caseSensitive: Bool)?

    private(set) var summary = ""
    private var didSearch = false
    /// **横断検索は自動では走らせない**（フォルダも語も要るので、タブを開いただけでは
    /// 走らせようがない）。まだ探していない間は「結果なし」として、開かれるたびに
    /// `run(document:)` を通す——対象フォルダの初期値をそこで入れるため。
    var hasResult: Bool { didSearch }

    private let folderButton = NSButton(title: S.chooseFolders, target: nil, action: nil)
    private let folderLabel = NSTextField(labelWithString: S.noFolders)
    private let queryField = NSSearchField()
    private let caseToggle = NSButton(checkboxWithTitle: S.caseSensitive, target: nil, action: nil)
    private let regexToggle = NSButton(checkboxWithTitle: S.modeRegex, target: nil, action: nil)
    private let gitignoreToggle = NSButton(checkboxWithTitle: S.respectGitignore, target: nil, action: nil)
    private let contextField = NSTextField()
    private let contextLabel = NSTextField(labelWithString: S.contextLines)
    private let searchButton = NSButton(title: S.searchAcross, target: nil, action: nil)
    private let noticeLabel = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()

    private let runner = CrossFileSearchRunner()
    private var folders: [URL] = []
    private var files: [CrossFileSearchRunner.FileHit] = []
    private var expanded = Set<String>()

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    // MARK: - 組み立て

    private func setup() {
        registerForDraggedTypes([.fileURL])

        folderButton.target = self
        folderButton.action = #selector(chooseFolders)
        folderButton.controlSize = .small
        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingHead

        queryField.placeholderString = S.queryPlaceholder
        queryField.target = self
        queryField.action = #selector(searchTapped)
        queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        for toggle in [caseToggle, regexToggle, gitignoreToggle] {
            toggle.controlSize = .small
            toggle.font = .systemFont(ofSize: 11)
        }
        contextLabel.font = .systemFont(ofSize: 11)
        contextLabel.textColor = .secondaryLabelColor
        contextField.integerValue = 0
        contextField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        contextField.alignment = .right
        contextField.widthAnchor.constraint(equalToConstant: 34).isActive = true

        searchButton.target = self
        searchButton.action = #selector(searchTapped)
        searchButton.controlSize = .small
        searchButton.keyEquivalent = "\r"

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byTruncatingTail

        setupOutline()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let top = NSStackView(views: [folderButton, folderLabel])
        top.orientation = .horizontal
        top.spacing = 8
        top.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 0, right: 10)

        let controls = NSStackView(views: [queryField, caseToggle, regexToggle, gitignoreToggle,
                                           contextLabel, contextField, searchButton, NSView()])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

        for v in [top, controls, noticeLabel, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),

            controls.topAnchor.constraint(equalTo: top.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),

            noticeLabel.topAnchor.constraint(equalTo: controls.bottomAnchor),
            noticeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            noticeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: noticeLabel.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupOutline() {
        outline.dataSource = self
        outline.delegate = self
        outline.rowSizeStyle = .small
        outline.headerView = nil
        outline.usesAlternatingRowBackgroundColors = true
        outline.indentationPerLevel = 14
        outline.target = self
        outline.action = #selector(rowClicked)
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: S.aggregateThisMatch, action: #selector(aggregateClicked), keyEquivalent: ""))
        outline.menu = menu

        let column = NSTableColumn(identifier: .init("result"))
        column.title = ""
        column.width = 800
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
    }

    // MARK: - AnalysisFeatureView

    /// タブを開いた時点では**探さない**。対象フォルダの初期値を入れるだけ。
    /// 一度探した後に呼ばれたとき（＝ペインの ⟳）は、同じ条件で探し直す。
    func run(document: ActiveDocument?) {
        if folders.isEmpty, let url = document?.fileURL {
            folders = [url.deletingLastPathComponent()]
            updateFolderLabel()
        }
        if didSearch { searchTapped() }
    }

    func cancel() { runner.cancel() }

    func copySelection() {
        let text = files.flatMap { file in
            file.lines.filter { !$0.isContext }.map { "\(file.url.path):\($0.line + 1)\t\($0.text)" }
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "matches.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            var out = "file,line,text\n"
            for file in self.files {
                for hit in file.lines where !hit.isContext {
                    let text = hit.text.replacingOccurrences(of: "\"", with: "\"\"")
                    out += "\"\(file.url.path)\",\(hit.line + 1),\"\(text)\"\n"
                }
            }
            try? out.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - フォルダ

    @objc private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.folders = panel.urls
            self.updateFolderLabel()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else { return false }
        folders = urls
        updateFolderLabel()
        return true
    }

    private func updateFolderLabel() {
        folderLabel.stringValue = folders.isEmpty
            ? S.noFolders
            : folders.map { $0.lastPathComponent }.joined(separator: " / ")
        folderLabel.toolTip = folders.map(\.path).joined(separator: "\n")
    }

    // MARK: - 検索

    @objc private func searchTapped() {
        let query = queryField.stringValue
        guard !folders.isEmpty else { noticeLabel.stringValue = S.needFolders; return }
        guard !query.isEmpty else {
            noticeLabel.stringValue = S.needQuery
            return
        }
        var options = CrossFileSearchRunner.Options()
        options.caseSensitive = caseToggle.state == .on
        options.regex = regexToggle.state == .on
        options.respectGitignore = gitignoreToggle.state == .on
        options.context = max(0, min(20, contextField.integerValue))

        if options.regex, (try? NSRegularExpression(pattern: query)) == nil {
            noticeLabel.stringValue = S.invalidRegex
            return
        }

        lastQuery = (query, options.regex, options.caseSensitive)
        didSearch = true
        files = []
        expanded = []
        outline.reloadData()
        noticeLabel.stringValue = ""
        summary = ""
        onStateChange?(summary, true, 0)

        runner.run(folders: folders, query: query, options: options,
                   onFile: { [weak self] hit in
                       guard let self else { return }
                       // **見つかった順に**出す（全部終わるまで待たせない）。
                       self.files.append(hit)
                       self.outline.reloadData()
                       self.summary = S.crossSearchProgress(files: self.files.count,
                                                            lines: self.files.reduce(0) { $0 + $1.matchCount })
                       self.onStateChange?(self.summary, true, 0)
                   },
                   progress: { [weak self] p in
                       guard let self else { return }
                       self.onStateChange?(self.summary, true, p)
                   },
                   completion: { [weak self] result in self?.apply(result) })
    }

    private func apply(_ result: CrossFileSearchRunner.Summary) {
        files.sort { $0.url.path < $1.url.path }
        outline.reloadData()
        summary = S.crossSearchSummary(files: result.matchedFiles,
                                       lines: result.matchedLines,
                                       scanned: result.files,
                                       seconds: result.elapsed,
                                       capped: result.capped)
        var notes: [String] = []
        if result.skippedBinary > 0 { notes.append(S.skippedBinary(result.skippedBinary)) }
        if result.capped { notes.append(S.crossSearchCapped(CrossFileSearchRunner.defaultCap)) }
        if result.matchedFiles == 0 { notes.append(S.noMatches) }
        else if lastQuery?.regex == true { notes.append(S.aggregateHitHint) }
        noticeLabel.stringValue = notes.joined(separator: "　")
        onStateChange?(summary, false, 1)
    }

    /// 行をクリック → そのファイルのその行を開く（**開いていればそのタブへ**）。
    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if let file = item as? FileNode {
            outline.isItemExpanded(file) ? outline.collapseItem(file) : outline.expandItem(file)
            return
        }
        guard let hit = item as? LineNode else { return }
        onOpenLine?(hit.file, hit.hit.line + 1)
    }

    /// 右クリックした行のファイルを開き、検索した式で値の集計を走らせる。
    /// 取り出し式は**括弧（キャプチャ）が要る**ので、無ければ式全体を括る
    /// （`status=\d+` → `(status=\d+)`）。
    @objc private func aggregateClicked() {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row), let q = lastQuery, q.regex else { return }
        let url: URL
        if let file = item as? FileNode { url = file.hit.url }
        else if let line = item as? LineNode { url = line.file }
        else { return }
        let groups = (try? NSRegularExpression(pattern: q.pattern))?.numberOfCaptureGroups ?? 0
        onAggregateHit?(url, groups >= 1 ? q.pattern : "(\(q.pattern))", q.caseSensitive)
    }

    // MARK: - ツリーの節

    /// `NSOutlineView` は item を参照で識別するので、値型のままでは使えない。
    private final class FileNode {
        let index: Int
        let hit: CrossFileSearchRunner.FileHit
        init(index: Int, hit: CrossFileSearchRunner.FileHit) {
            self.index = index
            self.hit = hit
        }
    }

    private final class LineNode {
        let file: URL
        let hit: CrossFileSearchRunner.LineHit
        init(file: URL, hit: CrossFileSearchRunner.LineHit) {
            self.file = file
            self.hit = hit
        }
    }

    private var nodes: [FileNode] {
        files.enumerated().map { FileNode(index: $0.offset, hit: $0.element) }
    }
}

// MARK: - ツリー

extension CrossFileSearchView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return files.count }
        if let file = item as? FileNode { return file.hit.lines.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return FileNode(index: index, hit: files[index]) }
        let file = item as! FileNode
        return LineNode(file: file.hit.url, hit: file.hit.lines[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode) != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let file = item as? FileNode {
            let label = NSTextField(labelWithString:
                S.fileRow(file.hit.url.lastPathComponent,
                          matches: file.hit.matchCount,
                          encoding: file.hit.encoding.displayName))
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.toolTip = file.hit.url.path
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }
        guard let node = item as? LineNode else { return nil }
        let number = NSTextField(labelWithString: "\(node.hit.line + 1)")
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        number.alignment = .right
        number.textColor = .tertiaryLabelColor
        number.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let text = NSTextField(labelWithString: String(node.hit.text.prefix(500)))
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.lineBreakMode = .byTruncatingTail
        // 前後 N 行は一致行ではない。**色で区別する**（どれが当たった行か分からなくなるので）。
        text.textColor = node.hit.isContext ? .tertiaryLabelColor : .labelColor

        let row = NSStackView(views: [number, text])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }
}
extension CrossFileSearchView: NSMenuDelegate {
    /// 検索が正規表現のときだけ使える（リテラルの一致は、数えても 1 種類にしかならない）。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first?.isEnabled = (lastQuery?.regex == true) && outline.clickedRow >= 0
    }
}
