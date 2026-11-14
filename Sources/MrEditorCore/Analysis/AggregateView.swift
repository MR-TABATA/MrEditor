import AppKit

/// C1「値の集計」の画面。**表の行をダブルクリックするとその値で本文が絞り込まれる**
/// —— 数える → 見る の往復がこの機能の心臓。
final class AggregateView: NSView, AnalysisFeatureView {

    var onStateChange: ((String, Bool, Double) -> Void)?
    /// 走らせ直しは**枠に頼む**（手元の写しで走ると、絞り込みを変えた後にズレる）。
    var onRequestRun: (() -> Void)?
    /// その値で本文を絞り込む（`MainWindowController.applyLiteralFilter` へ繋ぐ）。
    var onFilterValue: ((String) -> Void)?

    private(set) var summary = ""

    private let modePopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private let targetField = NSTextField()
    private let caseToggle = NSButton(checkboxWithTitle: S.caseSensitive, target: nil, action: nil)
    private let runButton = NSButton(title: S.count, target: nil, action: nil)
    private let noticeLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private let runner = AggregateRunner()
    private var rows: [(value: String, count: Int)] = []
    private var total = 0
    private var document: ActiveDocument?
    /// `key=` の候補（先頭のほうを読んで拾う）。
    private var keyCandidates: [String] = []

    /// 抽出モードの並び（ポップアップの順）。
    private enum ModeChoice: Int, CaseIterable {
        case column, keyValue, regex, wholeLine
        var title: String {
            switch self {
            case .column:    return S.modeColumn
            case .keyValue:  return S.modeKeyValue
            case .regex:     return S.modeRegex
            case .wholeLine: return S.modeWholeLine
            }
        }
    }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    // MARK: - 組み立て

    private func setup() {
        for choice in ModeChoice.allCases { modePopup.addItem(withTitle: choice.title) }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)

        targetPopup.target = self
        targetPopup.action = #selector(runTapped)
        targetField.placeholderString = S.keyPlaceholderAggregate
        targetField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        targetField.target = self
        targetField.action = #selector(runTapped)

        caseToggle.controlSize = .small
        caseToggle.font = .systemFont(ofSize: 11)
        runButton.target = self
        runButton.action = #selector(runTapped)
        runButton.keyEquivalent = "\r"
        runButton.controlSize = .small

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .systemRed
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.isHidden = true

        let controls = NSStackView(views: [modePopup, targetPopup, targetField, caseToggle, runButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 4, right: 10)
        targetField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        setupTable()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        for v in [controls, noticeLabel, scroll] {
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
        ])
        updateControlVisibility()
    }

    private func setupTable() {
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .small
        table.allowsMultipleSelection = true
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)

        let value = NSTableColumn(identifier: .init("value"))
        value.title = S.columnValue
        value.width = 320
        let count = NSTableColumn(identifier: .init("count"))
        count.title = S.columnCount
        count.width = 110
        let share = NSTableColumn(identifier: .init("share"))
        share.title = S.columnShare
        share.width = 180
        for c in [value, count, share] { table.addTableColumn(c) }
    }

    // MARK: - AnalysisFeatureView

    func run(document: ActiveDocument?) {
        guard let document else { return }
        self.document = document
        refreshTargets(for: document)
        // 固定長の「列」は桁の定義を受け取れない＝全行が (該当なし) になる。
        // **件数 0 の表ではなく、出せないと言う。**
        if ModeChoice(rawValue: modePopup.indexOfSelectedItem) == .column,
           document.structuredMode == .fixedWidth {
            setNotice(S.fixedWidthUnsupported)
            return
        }
        guard let mode = currentMode(for: document) else {
            setNotice(S.regexNeedsGroup)
            return
        }
        setNotice(nil)
        onStateChange?(summary, true, 0)

        var options = ValueExtractor.Options()
        options.caseSensitive = caseToggle.state == .on
        runner.run(document: document, mode: mode, options: options,
                   progress: { [weak self] p in
                       guard let self else { return }
                       self.onStateChange?(self.summary, true, p)
                   },
                   completion: { [weak self] result in
                       self?.apply(result)
                   })
    }

    /// C2（列の統計）の行から渡ってくる入口。**その列を選んだ状態にしてから**数える。
    /// 画面の選択も動かすので、「いま何を数えているか」が表と一致する。
    func inspectColumn(_ index: Int, document: ActiveDocument?) {
        guard let document else { return }
        self.document = document
        refreshTargets(for: document)
        guard index >= 0, index < targetPopup.numberOfItems else { NSSound.beep(); return }
        modePopup.selectItem(at: ModeChoice.column.rawValue)
        updateControlVisibility()
        targetPopup.selectItem(at: index)
        run(document: document)
    }

    /// C5（横断検索）の結果から渡ってくる入口。**検索した正規表現を、そのまま取り出し式にする。**
    /// 画面の選択も動かすので、「いま何を数えているか」が入力欄と一致する。
    func aggregateByRegex(_ pattern: String, caseSensitive: Bool, document: ActiveDocument?) {
        guard let document else { return }
        self.document = document
        refreshTargets(for: document)
        modePopup.selectItem(at: ModeChoice.regex.rawValue)
        updateControlVisibility()
        targetField.stringValue = pattern
        caseToggle.state = caseSensitive ? .on : .off
        run(document: document)
    }

    func cancel() { runner.cancel() }

    func copySelection() {
        let selected = table.selectedRowIndexes.isEmpty
            ? IndexSet(integersIn: 0..<rows.count)
            : table.selectedRowIndexes
        let text = selected.map { i in
            "\(rows[i].value)\t\(rows[i].count)\t\(shareText(rows[i].count))"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "aggregate.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            var out = "value,count,share\n"
            for r in self.rows {
                let escaped = r.value.replacingOccurrences(of: "\"", with: "\"\"")
                out += "\"\(escaped)\",\(r.count),\(self.shareText(r.count))\n"
            }
            try? out.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 実行と結果

    @objc private func modeChanged() {
        updateControlVisibility()
        if let document { refreshTargets(for: document) }
    }

    @objc private func runTapped() { onRequestRun?() }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        let value = rows[row].value
        // 「(空欄)」「(該当なし)」「(打ち切り…)」は本文に無い作り物なので絞り込めない。
        guard value != ValueExtractor.blank, value != ValueExtractor.missing else { NSSound.beep(); return }
        onFilterValue?(value)
    }

    private func apply(_ result: AggregateRunner.Result) {
        rows = result.rows
        total = result.scannedLines
        summary = S.aggregateSummary(lines: result.scannedLines,
                                     seconds: result.elapsed,
                                     distinct: result.distinctCount)
        if result.truncatedRows > 0 {
            setNotice(S.truncationNotice(distinct: result.distinctCount, rows: result.truncatedRows))
        } else {
            setNotice(nil)
        }
        table.reloadData()
        onStateChange?(summary, false, 1)
    }

    private func currentMode(for document: ActiveDocument) -> ValueExtractor.Mode? {
        switch ModeChoice(rawValue: modePopup.indexOfSelectedItem) ?? .wholeLine {
        case .wholeLine:
            return .wholeLine
        case .keyValue:
            let key = targetField.stringValue.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : .keyValue(key: key)
        case .regex:
            let pattern = targetField.stringValue
            guard !pattern.isEmpty,
                  let rx = try? NSRegularExpression(pattern: pattern),
                  rx.numberOfCaptureGroups >= 1 else { return nil }
            return .regex(rx)
        case .column:
            let index = targetPopup.indexOfSelectedItem
            guard index >= 0 else { return nil }
            if document.structuredMode == .ndjson {
                guard index < document.columnNames.count else { return nil }
                return .jsonKey(document.columnNames[index])
            }
            // ポップアップの index は**表示順**（並べ替え・B19で変わりうる）。csv/tsv は
            // 生セルを位置で切るので、`columnOriginalIndices` で生の列位置へ引き直す
            // ── これをせず index をそのまま渡すと、並べ替え後は列名と値がズレる
            // （実機で踏んだ・2026-09-25）。
            guard index < document.columnOriginalIndices.count else { return nil }
            return .column(index: document.columnOriginalIndices[index], mode: document.structuredMode ?? .csv)
        }
    }

    private func updateControlVisibility() {
        let choice = ModeChoice(rawValue: modePopup.indexOfSelectedItem) ?? .wholeLine
        targetPopup.isHidden = choice != .column
        targetField.isHidden = !(choice == .keyValue || choice == .regex)
        targetField.placeholderString = choice == .regex ? "status=(\\d+)" : S.keyPlaceholderAggregate
    }

    /// 列の一覧と `key=` の候補を、いまのドキュメントから引き直す。
    private func refreshTargets(for document: ActiveDocument) {
        let names = document.columnNames
        if targetPopup.itemTitles != displayNames(names) {
            targetPopup.removeAllItems()
            targetPopup.addItems(withTitles: displayNames(names))
        }
        // 構造化していないと列が無い＝列モードは選べない。
        modePopup.item(at: ModeChoice.column.rawValue)?.isEnabled = !names.isEmpty
        if names.isEmpty, ModeChoice(rawValue: modePopup.indexOfSelectedItem) == .column {
            modePopup.selectItem(at: ModeChoice.keyValue.rawValue)
            updateControlVisibility()
        }
        if keyCandidates.isEmpty { keyCandidates = KeySampler.keys(in: document) }
        if !keyCandidates.isEmpty, targetField.stringValue.isEmpty,
           ModeChoice(rawValue: modePopup.indexOfSelectedItem) == .keyValue {
            targetField.stringValue = keyCandidates[0]
        }
    }

    private func displayNames(_ names: [String]) -> [String] {
        names.enumerated().map { i, n in n.isEmpty ? S.columnNumber(i + 1) : n }
    }

    private func setNotice(_ text: String?) {
        noticeLabel.stringValue = text ?? ""
        noticeLabel.isHidden = (text == nil)
    }

    private func shareText(_ count: Int) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.1f%%", Double(count) * 100 / Double(total))
    }
}

// MARK: - 表

extension AggregateView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let entry = rows[row]
        switch id {
        case "value":
            return label(entry.value, mono: true, alignment: .left)
        case "count":
            let n = NumberFormatter.localizedString(from: NSNumber(value: entry.count), number: .decimal)
            return label(n, mono: true, alignment: .right)
        default:
            return shareCell(entry.count)
        }
    }

    private func label(_ text: String, mono: Bool, alignment: NSTextAlignment) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                          : .systemFont(ofSize: 11)
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// 割合の欄。**custom draw() は使わない**（同一ウィンドウ内の合成が壊れるため）。
    /// レイヤの幅で棒を出す。
    ///
    /// 幅は「掛け率だけ」で決める。掛け率に負の定数を足すと、割合が小さいときに幅が
    /// 負になって制約が壊れ、**列がまるごと空に見える**（最初の実装で実際にそうなった）。
    private func shareCell(_ count: Int) -> NSView {
        let container = NSView()
        let text = label(shareText(count), mono: true, alignment: .right)
        let track = NSView()
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        bar.layer?.cornerRadius = 2

        for v in [text, track] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(bar)

        let ratio = total > 0 ? CGFloat(count) / CGFloat(total) : 0
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            text.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            text.widthAnchor.constraint(equalToConstant: 46),

            track.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 6),
            track.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            track.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            track.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),

            bar.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            bar.topAnchor.constraint(equalTo: track.topAnchor),
            bar.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            // 0 件でも「そこに棒がある」ことは見せる（掛け率の下限）。
            bar.widthAnchor.constraint(equalTo: track.widthAnchor,
                                       multiplier: max(0.004, min(1, ratio))),
        ])
        return container
    }
}

/// `key=value` のキー候補を、ファイルの先頭のほうから拾う。
/// **全部は読まない**（候補を出すためだけに 10GB を読む理由がない）。
///
/// 並びは**サンプルの中で値の種類が少ない順**。先に見つけた順にすると、実機で最初に
/// 選ばれるのが `request_id` になり、開いた瞬間に「200 万種類で打ち切りました」の赤帯が
/// 出た。ID を数えたい人はいる（だから候補からは外さない）が、**既定は数えて意味のある
/// キー**にする。
enum KeySampler {
    static func keys(in document: ActiveDocument, limitBytes: Int = 256 << 10) -> [String] {
        let sample: String
        if let text = document.text {
            sample = String(text.prefix(limitBytes))
        } else if let url = document.fileURL,
                  let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: limitBytes)) ?? Data()
            sample = String(data: data, encoding: document.encoding.stringEncoding)
                ?? String(decoding: data, as: UTF8.self)
        } else {
            return []
        }

        var order: [String] = []
        var values: [String: Set<String>] = [:]
        var rows = 0
        for line in sample.split(separator: "\n").prefix(1000) {
            rows += 1
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }) {
                guard let eq = token.firstIndex(of: "="), eq > token.startIndex else { continue }
                let key = String(token[token.startIndex..<eq])
                guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else { continue }
                if values[key] == nil { values[key] = []; order.append(key) }
                values[key]?.insert(String(token[token.index(after: eq)...]))
            }
        }
        // 種類が少ない順。同数なら見つけた順（安定させる）。
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.sorted {
            let a = values[$0]?.count ?? 0, b = values[$1]?.count ?? 0
            return a != b ? a < b : (rank[$0] ?? 0) < (rank[$1] ?? 0)
        }
    }
}
