import AppKit

/// C3「時間分布」の画面。**棒をドラッグするとその時間帯だけに本文が絞り込まれる。**
///
/// グラフだけにしない——ピークの時刻と件数は必ず文字でも出す（棒を見比べて読み取らせない）。
/// 時刻を持たない行も「時刻なし N 行」として出す（黙って捨てない）。
final class TimeHistogramView: NSView, AnalysisFeatureView {

    var onStateChange: ((String, Bool, Double) -> Void)?
    /// 走らせ直しは**枠に頼む**（手元の写しで走ると、絞り込みを変えた後にズレる）。
    var onRequestRun: (() -> Void)?
    /// 時間帯で絞り込む（epoch 秒の範囲）。解除は nil。
    var onSelectRange: ((Range<Int>?) -> Void)?
    /// 選んだ時間帯を、そのまま C1（値の集計）へ渡してほしい。
    var onAggregateRange: (() -> Void)?

    private(set) var summary = ""

    private let runButton = NSButton(title: S.rerun, target: nil, action: nil)
    private let logToggle = NSButton(checkboxWithTitle: S.logScale, target: nil, action: nil)
    private let yearField = NSTextField()
    private let offsetPopup = NSPopUpButton()
    private let supplyLabel = NSTextField(labelWithString: S.suppliedLabel)
    private let infoLabel = NSTextField(labelWithString: "")
    private let selectionLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: S.clearRange, target: nil, action: nil)
    private let aggregateButton = NSButton(title: S.aggregateRange, target: nil, action: nil)
    private let chart = HistogramChart()
    private let axisLeft = NSTextField(labelWithString: "")
    private let axisMid = NSTextField(labelWithString: "")
    private let axisRight = NSTextField(labelWithString: "")

    private let runner = TimeHistogramRunner()
    private var result = TimeHistogramRunner.Result()
    private var document: ActiveDocument?
    private var options = TimeHistogramRunner.Options()

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    // MARK: - 組み立て

    private func setup() {
        runButton.target = self
        runButton.action = #selector(runTapped)
        runButton.controlSize = .small

        logToggle.target = self
        logToggle.action = #selector(logChanged)
        logToggle.controlSize = .small
        logToggle.font = .systemFont(ofSize: 11)

        // 年やオフセットを持たない形式のために、**補い方を見せて切り替えられるようにする。**
        supplyLabel.font = .systemFont(ofSize: 11)
        supplyLabel.textColor = .secondaryLabelColor
        yearField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        yearField.integerValue = options.assumedYear
        yearField.target = self
        yearField.action = #selector(runTapped)
        yearField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        for hours in stride(from: -12, through: 14, by: 1) {
            offsetPopup.addItem(withTitle: String(format: "%+03d:00", hours))
        }
        offsetPopup.selectItem(withTitle: String(format: "%+03d:00", options.timeZoneOffset / 3600))
        offsetPopup.target = self
        offsetPopup.action = #selector(runTapped)
        offsetPopup.controlSize = .small

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.controlSize = .small
        clearButton.isHidden = true
        aggregateButton.target = self
        aggregateButton.action = #selector(aggregateTapped)
        aggregateButton.controlSize = .small
        aggregateButton.isHidden = true

        chart.onSelect = { [weak self] range in self?.selected(range) }
        chart.onPreview = { [weak self] range in self?.showPreview(range) }

        for label in [axisLeft, axisMid, axisRight] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .tertiaryLabelColor
        }
        axisMid.alignment = .center
        axisRight.alignment = .right

        let controls = NSStackView(views: [runButton, logToggle, supplyLabel, yearField,
                                           offsetPopup, selectionLabel, aggregateButton, clearButton, NSView()])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 2, right: 10)

        let axis = NSStackView(views: [axisLeft, axisMid, axisRight])
        axis.orientation = .horizontal
        axis.distribution = .fillEqually
        axis.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 4, right: 10)

        for v in [controls, infoLabel, chart, axis] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),

            infoLabel.topAnchor.constraint(equalTo: controls.bottomAnchor),
            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            infoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            chart.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 6),
            chart.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            axis.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 2),
            axis.leadingAnchor.constraint(equalTo: leadingAnchor),
            axis.trailingAnchor.constraint(equalTo: trailingAnchor),
            axis.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        updateSupplyControls()
    }

    // MARK: - AnalysisFeatureView

    func run(document: ActiveDocument?) {
        guard let document else { return }
        self.document = document
        options.assumedYear = yearField.integerValue > 0 ? yearField.integerValue : options.assumedYear
        options.timeZoneOffset = selectedOffset()
        options.displayOffset = selectedOffset()

        onStateChange?(summary, true, 0)
        runner.run(document: document, options: options,
                   progress: { [weak self] p in
                       guard let self else { return }
                       self.onStateChange?(self.summary, true, p)
                   },
                   completion: { [weak self] result in self?.apply(result) })
    }

    func cancel() { runner.cancel() }

    /// いま使っている補い方（範囲選択の走査も同じ条件で読む必要がある）。
    var currentOptions: TimeHistogramRunner.Options { options }

    func copySelection() {
        let text = result.buckets.map { bucket in
            "\(S.timeLabel(bucket.start, width: result.bucketSeconds, offset: options.displayOffset))\t\(bucket.count)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "histogram.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            var out = "bucket_start,count\n"
            for bucket in self.result.buckets {
                let label = S.timeLabel(bucket.start, width: self.result.bucketSeconds,
                                        offset: self.options.displayOffset)
                out += "\"\(label)\",\(bucket.count)\n"
            }
            try? out.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 結果

    private func apply(_ result: TimeHistogramRunner.Result) {
        self.result = result
        chart.buckets = result.buckets
        chart.logScale = logToggle.state == .on

        if result.buckets.isEmpty {
            summary = ""
            infoLabel.stringValue = S.noTimestamps
            infoLabel.textColor = .systemRed
            axisLeft.stringValue = ""; axisMid.stringValue = ""; axisRight.stringValue = ""
            onStateChange?(summary, false, 1)
            return
        }
        infoLabel.textColor = .secondaryLabelColor
        summary = S.histogramSummary(lines: result.scannedLines,
                                     seconds: result.elapsed,
                                     bars: result.buckets.count,
                                     width: result.bucketSeconds)
        // ピークと「時刻なし」は**文字でも**出す（グラフだけにしない）。
        var parts: [String] = []
        if let peak = result.peak {
            parts.append(S.peakLabel(S.timeLabel(peak.start, width: result.bucketSeconds,
                                                 offset: options.displayOffset),
                                     count: peak.count))
        }
        if result.untimedLines > 0 { parts.append(S.untimedLines(result.untimedLines)) }
        if let format = result.format { parts.append(S.formatLabel(format)) }
        infoLabel.stringValue = parts.joined(separator: "　")

        axisLeft.stringValue = S.timeLabel(result.buckets.first!.start,
                                           width: result.bucketSeconds, offset: options.displayOffset)
        axisMid.stringValue = S.timeLabel(result.buckets[result.buckets.count / 2].start,
                                          width: result.bucketSeconds, offset: options.displayOffset)
        axisRight.stringValue = S.timeLabel(result.buckets.last!.start,
                                            width: result.bucketSeconds, offset: options.displayOffset)
        updateSupplyControls()
        clearButton.isHidden = true
        aggregateButton.isHidden = true
        showIdleHint()
        onStateChange?(summary, false, 1)
    }

    /// ドラッグ中に「いま何を選んでいるか」を出す（離す前に分かるように）。
    private func showPreview(_ range: ClosedRange<Int>?) {
        guard let range, !result.buckets.isEmpty else {
            showIdleHint()
            return
        }
        let count = range.clamped(to: 0...(result.buckets.count - 1))
            .reduce(0) { $0 + result.buckets[$1].count }
        selectionLabel.textColor = .labelColor
        selectionLabel.stringValue = S.rangeLabel(
            from: S.timeLabel(result.buckets[range.lowerBound].start,
                              width: result.bucketSeconds, offset: options.displayOffset),
            to: S.timeLabel(result.buckets[range.upperBound].start + result.bucketSeconds,
                            width: result.bucketSeconds, offset: options.displayOffset),
            count: count)
    }

    /// 何も選んでいないときは、何ができるかを薄く出す（選ぶと範囲の表示に替わる）。
    private func showIdleHint() {
        selectionLabel.stringValue = S.rangeHint
        selectionLabel.textColor = .tertiaryLabelColor
    }

    private func selected(_ range: ClosedRange<Int>?) {
        guard let range, !result.buckets.isEmpty else { return }
        let from = result.buckets[range.lowerBound].start
        let to = result.buckets[range.upperBound].start + result.bucketSeconds
        showPreview(range)
        clearButton.isHidden = false
        aggregateButton.isHidden = false
        onSelectRange?(from..<to)
    }

    @objc private func clearTapped() {
        chart.clearSelection()
        showIdleHint()
        clearButton.isHidden = true
        aggregateButton.isHidden = true
        onSelectRange?(nil)
    }

    @objc private func aggregateTapped() { onAggregateRange?() }

    @objc private func runTapped() { onRequestRun?() }

    @objc private func logChanged() {
        chart.logScale = logToggle.state == .on
    }

    private func selectedOffset() -> Int {
        let title = offsetPopup.titleOfSelectedItem ?? "+09:00"
        let hours = Int(title.prefix(3)) ?? 9
        return hours * 3600
    }

    /// 年やオフセットを補ったときだけ、補い方の操作を出す。
    private func updateSupplyControls() {
        let needsYear = result.format == .syslog
        let needsOffset = result.format == .syslog || result.format == .apache
            || result.format == .iso8601 || result.format == nil
        supplyLabel.isHidden = !(needsYear || needsOffset)
        yearField.isHidden = !needsYear
        offsetPopup.isHidden = !needsOffset
    }
}

/// 棒グラフ。**`draw(_:)` を持たない**（同一ウィンドウ内に custom draw のビューが複数あると
/// macOS の合成が壊れる。1.11 で踏んだ）。棒も選択の帯もレイヤ付きのサブビューで作る。
private final class HistogramChart: NSView {

    var onSelect: ((ClosedRange<Int>?) -> Void)?
    var onPreview: ((ClosedRange<Int>?) -> Void)?

    var buckets: [TimeHistogramRunner.Bucket] = [] {
        didSet { rebuild() }
    }
    var logScale = false {
        didSet { needsLayout = true }
    }

    private var bars: [NSView] = []
    private let selectionBand = NSView()
    private var dragStart: Int?
    private var selection: ClosedRange<Int>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        selectionBand.wantsLayer = true
        selectionBand.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        selectionBand.isHidden = true
        addSubview(selectionBand)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 110) }

    private func rebuild() {
        for bar in bars { bar.removeFromSuperview() }
        bars = buckets.map { _ in
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
            addSubview(bar, positioned: .below, relativeTo: selectionBand)
            return bar
        }
        selection = nil
        selectionBand.isHidden = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !bars.isEmpty else { return }
        let maxCount = buckets.map(\.count).max() ?? 1
        let width = bounds.width / CGFloat(bars.count)
        let gap: CGFloat = width > 4 ? 1 : 0
        for (i, bar) in bars.enumerated() {
            let value = Double(buckets[i].count)
            let ratio: Double
            if maxCount <= 0 {
                ratio = 0
            } else if logScale {
                ratio = value <= 0 ? 0 : log(value + 1) / log(Double(maxCount) + 1)
            } else {
                ratio = value / Double(maxCount)
            }
            // 0 件でない棒は必ず 1px 以上出す（「無い」と「ほとんど無い」を見分けるため）。
            let height = value <= 0 ? 0 : max(1, CGFloat(ratio) * bounds.height)
            bar.frame = NSRect(x: CGFloat(i) * width, y: 0,
                               width: max(1, width - gap), height: height)
        }
        layoutSelectionBand()
    }

    private func layoutSelectionBand() {
        guard let selection, !bars.isEmpty else {
            selectionBand.isHidden = true
            return
        }
        let width = bounds.width / CGFloat(bars.count)
        selectionBand.isHidden = false
        selectionBand.frame = NSRect(x: CGFloat(selection.lowerBound) * width, y: 0,
                                     width: CGFloat(selection.count) * width, height: bounds.height)
    }

    func clearSelection() {
        selection = nil
        layoutSelectionBand()
    }

    // MARK: - ドラッグで範囲を選ぶ

    private func index(at point: NSPoint) -> Int? {
        guard !bars.isEmpty, bounds.width > 0 else { return nil }
        let i = Int(point.x / (bounds.width / CGFloat(bars.count)))
        return min(max(0, i), bars.count - 1)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let i = index(at: point) else { return }
        dragStart = i
        selection = i...i
        layoutSelectionBand()
        onPreview?(selection)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let start = dragStart, let i = index(at: point) else { return }
        selection = min(start, i)...max(start, i)
        layoutSelectionBand()
        onPreview?(selection)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onSelect?(selection)
    }
}