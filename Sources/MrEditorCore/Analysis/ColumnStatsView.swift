import AppKit

/// C2「列の統計」の画面。**1 行 = 1 列**で全列を出す。
///
/// 実務でいちばん多いのは「空っぽの列」「全部ユニークな列（＝ID）」を見つけることなので、
/// ヘッダをクリックしてユニーク数順・空欄数順に並べ替えられる。**行をダブルクリックすると
/// その列で C1（集計）へ渡る** —— C2 で当たりを付け、C1 で中身を見る、が想定の道順。
final class ColumnStatsView: NSView, AnalysisFeatureView {

    var onStateChange: ((String, Bool, Double) -> Void)?
    /// 走らせ直しは**枠に頼む**（手元の写しで走ると、絞り込みを変えた後にズレる）。
    var onRequestRun: (() -> Void)?
    /// その列を集計する（C1 のタブへ渡す）。引数は列番号（0 始まり）。
    /// (列の番号, 型)。型で行き先を出し分けるため（日時の列は時間分布へ）。
    var onInspectColumn: ((Int, ColumnStatsRunner.Kind) -> Void)?
    /// 異常行をクリックしたときのジャンプ先（ファイルURL、行番号）。
    var onOpenLine: ((URL, Int) -> Void)?
    /// 指定行（1 始まり）の本文を取得するコールバック。
    var onGetLineText: ((Int) -> String?)?
    /// 指定行（1 始まり）の本文を置換するコールバック。
    var onReplaceLine: ((Int, String) -> Bool)?
    /// エラー検知時に本文エディタ側を構造化表示へ自動切替するための要求。
    var onRequestStructuredMode: ((StructuredMode) -> Void)?

    private(set) var summary = ""

    private let runButton = NSButton(title: S.rerun, target: nil, action: nil)
    private let modeSegment = NSSegmentedControl(labels: [S.tabStats, S.tabSanity],
                                                 trackingMode: .selectOne,
                                                 target: nil,
                                                 action: nil)
    private let hintLabel = NSTextField(labelWithString: S.inspectColumnHint)
    private let noticeLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private let sanityTable = NSTableView()
    private let sanityScroll = NSScrollView()

    private let runner = ColumnStatsRunner()
    private var rows: [ColumnStatsRunner.ColumnStat] = []
    private var sanityIssues: [SanityIssue] = []
    private var scannedLines = 0
    private var document: ActiveDocument?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    // MARK: - 組み立て

    private func setup() {
        runButton.target = self
        runButton.action = #selector(runTapped)
        runButton.controlSize = .small

        modeSegment.target = self
        modeSegment.action = #selector(modeChanged)
        modeSegment.controlSize = .small
        modeSegment.selectedSegment = 0

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.isHidden = true

        let controls = NSStackView(views: [runButton, modeSegment, hintLabel])
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 4, right: 10)

        setupTable()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        setupSanityTable()
        sanityScroll.documentView = sanityTable
        sanityScroll.hasVerticalScroller = true
        sanityScroll.hasHorizontalScroller = true
        sanityScroll.autohidesScrollers = true
        sanityScroll.isHidden = true

        for v in [controls, noticeLabel, scroll, sanityScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),

            noticeLabel.topAnchor.constraint(equalTo: controls.bottomAnchor),
            noticeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            noticeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: noticeLabel.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            sanityScroll.topAnchor.constraint(equalTo: noticeLabel.bottomAnchor, constant: 4),
            sanityScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            sanityScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            sanityScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func modeChanged() {
        let isSanity = modeSegment.selectedSegment == 1
        scroll.isHidden = isSanity
        sanityScroll.isHidden = !isSanity
        hintLabel.stringValue = isSanity
            ? (sanityIssues.isEmpty ? S.sanityNoIssues : S.sanityIssueCount(sanityIssues.count))
            : S.inspectColumnHint
    }

    /// 表の列（＝統計の項目）。並べ替えられるものだけ `sortDescriptorPrototype` を持たせる。
    private enum Field: String, CaseIterable {
        case name, kind, present, blank, distinct, min, max, sum, average, top

        var title: String {
            switch self {
            case .name:     return S.colName
            case .kind:     return S.colKind
            case .present:  return S.colPresent
            case .blank:    return S.colBlank
            case .distinct: return S.colDistinct
            case .min:      return S.colMin
            case .max:      return S.colMax
            case .sum:      return S.colSum
            case .average:  return S.colAverage
            case .top:      return S.colTop
            }
        }

        var width: CGFloat {
            switch self {
            case .name:     return 150
            case .kind:     return 130
            case .present, .blank, .distinct: return 90
            case .min, .max: return 130
            case .sum, .average: return 110
            case .top:      return 320
            }
        }

        /// 並べ替えられる項目（「空っぽの列」「全部ユニークな列」を探すのが実務の第一手）。
        var sortable: Bool {
            switch self {
            case .name, .kind, .present, .blank, .distinct: return true
            default: return false
            }
        }
    }

    private func setupTable() {
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .small
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)

        for field in Field.allCases {
            let column = NSTableColumn(identifier: .init(field.rawValue))
            column.title = field.title
            column.width = field.width
            if field.sortable {
                column.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: true)
            }
            table.addTableColumn(column)
        }
    }

    // MARK: - データの嘘発見器（整合性チェック表）

    private enum SanityField: String, CaseIterable {
        case line, kind, action, column, expected, actual, preview

        var title: String {
            switch self {
            case .line:     return S.colSanityLine
            case .kind:     return S.colSanityKind
            case .action:   return "操作"
            case .column:   return S.colSanityColumn
            case .expected: return S.colSanityExpected
            case .actual:   return S.colSanityActual
            case .preview:  return S.colSanityPreview
            }
        }

        var width: CGFloat {
            switch self {
            case .line:     return 55
            case .kind:     return 90
            case .action:   return 60
            case .column:   return 80
            case .expected: return 65
            case .actual:   return 75
            case .preview:  return 280
            }
        }
    }

    private func setupSanityTable() {
        sanityTable.dataSource = self
        sanityTable.delegate = self
        sanityTable.usesAlternatingRowBackgroundColors = true
        sanityTable.rowSizeStyle = .small
        sanityTable.allowsMultipleSelection = false
        sanityTable.columnAutoresizingStyle = .noColumnAutoresizing
        sanityTable.target = self
        sanityTable.doubleAction = #selector(sanityRowDoubleClicked)

        for field in SanityField.allCases {
            let column = NSTableColumn(identifier: .init(field.rawValue))
            column.title = field.title
            column.width = field.width
            sanityTable.addTableColumn(column)
        }
    }

    // MARK: - AnalysisFeatureView

    private static func resolveDocument(_ document: ActiveDocument) -> ActiveDocument {
        guard document.structuredMode == nil,
              let ext = document.fileURL?.pathExtension.lowercased(),
              ext == "csv" || ext == "tsv" else { return document }
        let mode: StructuredMode = (ext == "tsv") ? .tsv : .csv

        var sample: String?
        if let text = document.text {
            sample = String(text.prefix(8192))
        } else if let url = document.fileURL,
                  let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 8192) {
                sample = String(data: data, encoding: document.encoding.stringEncoding)
                    ?? String(decoding: data, as: UTF8.self)
            }
        }
        guard let sample, let firstLine = sample.components(separatedBy: "\n").first, !firstLine.isEmpty else {
            return document
        }
        let sep: Character = (mode == .tsv) ? "\t" : ","
        let cols = TabularFormatter.splitDelimited(firstLine, sep: sep, csvQuotes: mode == .csv)
        guard !cols.isEmpty else { return document }
        return ActiveDocument(fileURL: document.fileURL,
                              encoding: document.encoding,
                              structuredMode: mode,
                              columnNames: cols,
                              columnWidths: [:],
                              columnOriginalIndices: Array(cols.indices),
                              text: document.text,
                              filterMatchLines: document.filterMatchLines)
    }

    func run(document: ActiveDocument?) {
        guard let rawDoc = document else { return }
        let document = Self.resolveDocument(rawDoc)
        self.document = document

        // 構造化していないファイルには列が無い。**列を発明せずに、そう言う。**
        //
        // 固定長だけは別の理由で出せない ── 列名（`1-8` のような桁）は出るので
        // ここを通ってしまうが、桁の定義が分析まで来ていないので全列が「空」になる。
        // **「数えた結果ゼロ」と「数えられない」が区別できなくなる**ので、走らせない。
        let blocked: String?
        if document.columnNames.isEmpty || document.structuredMode == nil {
            blocked = S.needsStructured
        } else if document.structuredMode == .fixedWidth {
            blocked = S.fixedWidthUnsupported
        } else {
            blocked = nil
        }
        if let blocked {
            rows = []
            scannedLines = 0
            summary = ""
            setNotice(blocked)
            table.reloadData()
            onStateChange?(summary, false, 0)
            return
        }

        setNotice(nil)
        onStateChange?(summary, true, 0)
        runner.run(document: document,
                   progress: { [weak self] p in
                       guard let self else { return }
                       self.onStateChange?(self.summary, true, p)
                   },
                   completion: { [weak self] result in
                       self?.apply(result)
                   })
    }

    func cancel() { runner.cancel() }

    func copySelection() {
        let selected = table.selectedRowIndexes.isEmpty
            ? IndexSet(integersIn: 0..<rows.count)
            : table.selectedRowIndexes
        let text = selected.map { i in
            Field.allCases.map { cellText($0, rows[i]) }.joined(separator: "\t")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "columns.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            var out = Field.allCases.map(\.rawValue).joined(separator: ",") + "\n"
            for row in self.rows {
                out += Field.allCases.map { field in
                    let v = self.cellText(field, row).replacingOccurrences(of: "\"", with: "\"\"")
                    return "\"\(v)\""
                }.joined(separator: ",") + "\n"
            }
            try? out.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 実行と結果

    @objc private func runTapped() { onRequestRun?() }

    /// 行をダブルクリック → 日時の列は C3（時間分布）、それ以外はその列で C1（集計）。
    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        onInspectColumn?(rows[row].index, rows[row].kind)
    }

    private var activePopover: NSPopover?

    /// 異常行をダブルクリック → その場で修正ポップオーバーを表示（案A）。
    @objc private func sanityRowDoubleClicked() {
        let row = sanityTable.clickedRow
        guard row >= 0, row < sanityIssues.count else { return }
        showEditPopover(for: row)
    }

    @objc private func editButtonTapped(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < sanityIssues.count else { return }
        showEditPopover(for: row)
    }

    private func showEditPopover(for row: Int) {
        guard row >= 0, row < sanityIssues.count else { return }
        let issue = sanityIssues[row]

        // 本文テキストの取得: onGetLineText から取得できなければ安全に中断（切り詰められたプレビューで上書きしない）
        guard let lineText = onGetLineText?(issue.line) else {
            NSSound.beep()
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        let vc = SanityIssueEditPopover(
            issue: issue,
            initialText: lineText,
            onSave: { [weak self, weak popover] newText in
                guard let self else { return }
                popover?.close()
                if let replace = self.onReplaceLine, replace(issue.line, newText) {
                    // 置換に成功したら自動で再走査
                    self.onRequestRun?()
                }
            },
            onJump: { [weak self, weak popover] in
                guard let self, let url = self.document?.fileURL else { return }
                popover?.close()
                self.onOpenLine?(url, issue.line)
            }
        )
        popover.contentViewController = vc
        activePopover = popover

        let rowRect = sanityTable.rect(ofRow: row)
        popover.show(relativeTo: rowRect, of: sanityTable, preferredEdge: .maxY)
    }

    private func apply(_ result: ColumnStatsRunner.Result) {
        rows = result.columns
        sanityIssues = result.sanityIssues
        scannedLines = result.scannedLines
        summary = S.columnStatsSummary(lines: result.scannedLines,
                                       seconds: result.elapsed,
                                       columns: result.columns.count)
        if !sanityIssues.isEmpty {
            modeSegment.setLabel("\(S.tabSanity) (\(sanityIssues.count))", forSegment: 1)
            modeSegment.selectedSegment = 1
            // エラーがある場合に限定して、テキスト側も自動で構造化表示へ切り替える
            if let mode = document?.structuredMode {
                onRequestStructuredMode?(mode)
            } else if let ext = document?.fileURL?.pathExtension.lowercased(), ext == "csv" || ext == "tsv" {
                onRequestStructuredMode?(ext == "tsv" ? .tsv : .csv)
            }
        } else {
            modeSegment.setLabel(S.tabSanity, forSegment: 1)
            modeSegment.selectedSegment = 0
        }
        applySort()
        table.reloadData()
        sanityTable.reloadData()
        modeChanged()
        onStateChange?(summary, false, 1)
    }

    private func setNotice(_ text: String?) {
        noticeLabel.stringValue = text ?? ""
        noticeLabel.isHidden = (text == nil)
    }

    /// 並べ替え。**既定は元の列順**（画面の並びと同じでないと、どの列の話か分からなくなる）。
    private func applySort() {
        guard let descriptor = table.sortDescriptors.first,
              let field = Field(rawValue: descriptor.key ?? "") else {
            rows.sort { $0.index < $1.index }
            return
        }
        rows.sort { a, b in
            let order = compare(field, a, b)
            // 同じ値のときは元の列順で安定させる（並べ替えるたびに入れ替わらないように）。
            if order == 0 { return a.index < b.index }
            return descriptor.ascending ? order < 0 : order > 0
        }
    }

    private func compare(_ field: Field,
                         _ a: ColumnStatsRunner.ColumnStat,
                         _ b: ColumnStatsRunner.ColumnStat) -> Int {
        switch field {
        case .name:     return compare(a.name, b.name)
        case .kind:     return compare(kindOrder(a.kind), kindOrder(b.kind))
        case .present:  return compare(a.present, b.present)
        case .blank:    return compare(a.blank, b.blank)
        case .distinct: return compare(a.distinct, b.distinct)
        default:        return 0
        }
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> Int {
        a == b ? 0 : (a < b ? -1 : 1)
    }

    private func kindOrder(_ kind: ColumnStatsRunner.Kind) -> Int {
        switch kind {
        case .number:   return 0
        case .datetime: return 1
        case .text:     return 2
        case .mixed:    return 3
        case .empty:    return 4
        }
    }

    // MARK: - 1 マスの文字

    private func cellText(_ field: Field, _ row: ColumnStatsRunner.ColumnStat) -> String {
        switch field {
        case .name:
            return row.name.isEmpty ? S.columnNumber(row.index + 1) : row.name
        case .kind:
            switch row.kind {
            case .number:   return S.kindNumber
            case .datetime: return S.kindDatetime
            case .text:     return S.kindText
            case .empty:    return S.kindEmpty
            case .mixed:    return S.mixedBreakdown(numeric: row.numeric, other: row.nonNumeric)
            }
        case .present:
            return number(row.present)
        case .blank:
            return number(row.blank)
        case .distinct:
            return row.distinctTruncated ? S.distinctAtLeast(row.distinct) : number(row.distinct)
        case .min:
            return row.minText ?? ""
        case .max:
            return row.maxText ?? ""
        case .sum:
            guard let sum = row.sum else { return "" }
            switch sum {
            case .integer(let v): return number(v)
            case .real(let d):    return String(format: "%g", d)
            case .overflow:       return S.sumOverflow
            }
        case .average:
            guard let average = row.average else { return "" }
            return String(format: "%.2f", average)
        case .top:
            guard scannedLines > 0 else { return "" }
            return row.top.map { entry in
                let share = Double(entry.count) * 100 / Double(scannedLines)
                return String(format: "%@ %.1f%%", entry.value, share)
            }.joined(separator: " / ")
        }
    }

    private func number(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
}

// MARK: - 表

extension ColumnStatsView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === sanityTable { return sanityIssues.count }
        return rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sanityTable {
            guard row < sanityIssues.count,
                  let field = SanityField(rawValue: tableColumn?.identifier.rawValue ?? "") else { return nil }
            let issue = sanityIssues[row]
            if field == .action {
                let btn = NSButton(title: "編集…", target: self, action: #selector(editButtonTapped(_:)))
                btn.bezelStyle = .inline
                btn.font = .systemFont(ofSize: 10)
                btn.tag = row
                return btn
            }

            let text: String
            switch field {
            case .line:     text = "\(issue.line)"
            case .kind:
                switch issue.kind {
                case .columnMismatch:   text = S.kindColumnMismatch
                case .typeContamination: text = S.kindTypeContam
                case .extremeLength:    text = "異常長"
                }
            case .column:   text = issue.columnName ?? "-"
            case .expected: text = issue.expected
            case .actual:   text = issue.actual
            case .preview:  text = issue.preview
            case .action:   text = ""
            }

            let label = NSTextField(labelWithString: text)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = text.isEmpty ? nil : text
            switch field {
            case .line:
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                label.alignment = .right
            case .kind:
                label.font = .systemFont(ofSize: 11, weight: .medium)
                label.textColor = .systemRed
            case .expected, .actual:
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            default:
                label.font = .systemFont(ofSize: 11)
            }
            return label
        }

        guard row < rows.count,
              let field = Field(rawValue: tableColumn?.identifier.rawValue ?? "") else { return nil }
        let entry = rows[row]
        let text = cellText(field, entry)

        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text.isEmpty ? nil : text
        switch field {
        case .present, .blank, .distinct, .sum, .average:
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.alignment = .right
        case .min, .max, .top:
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        default:
            label.font = .systemFont(ofSize: 11)
        }
        // 空の列と、全部ユニークな列（＝ID）は、探している当人に見つけてほしいので色を落とす。
        if field == .kind && entry.kind == .empty { label.textColor = .tertiaryLabelColor }
        return label
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if tableView === table {
            applySort()
            table.reloadData()
        }
    }
}