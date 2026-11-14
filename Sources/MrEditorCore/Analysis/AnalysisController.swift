import AppKit

/// 分析ペインの持ち主。**core とのやり取りはここ 1 箇所に閉じる**
/// （core の公開面が変わったとき、直すのがこのファイルだけで済むように）。
@MainActor
final class AnalysisController {

    private weak var windowController: MainWindowController?
    private let pane = AnalysisPane()
    /// 時間帯の絞り込みで「実際に入る行」を集める走査（分布の走査とは別に持つ）。
    private let rangeRunner = TimeHistogramRunner()
    private var isOpen = false
    /// 時間帯の行を集めている最中か。終わる前に「この時間帯を集計」を押されたときは、
    /// 集め終わってから数える（絞り込む前の全行を数えてしまわないように）。
    private var rangeFilterInFlight = false
    private var aggregateWhenRangeReady = false
    /// 各機能が**最後に走った時点の「対象」**（開いている本文と絞り込みの印）。
    /// 結果の出ているタブでも、対象が変わっていれば開くときに走らせ直す
    /// （ERROR で絞ってから時間分布を開くと、絞る前の全行の数字が残っていた）。
    private var ranTarget: [AnalysisFeature: Int] = [:]

    /// 機能ごとの中身。**タブを切り替えても結果は保持する**（集計を見て列の統計へ戻り、
    /// また集計へ、ができないと使い物にならない）。
    private var contents: [AnalysisFeature: AnalysisFeatureView] = [:]

    /// ドキュメントごとの高さ。閉じても覚えている。
    private var heights: [String: CGFloat] = [:]
    private var currentKey = ""

    init() {
        pane.onSelect = { [weak self] feature in self?.showContent(for: feature) }
        pane.onClose = { [weak self] in self?.close() }
        pane.onRerun = { [weak self] in self?.run() }
        pane.onCancel = { [weak self] in self?.cancel() }
        pane.onCopy = { [weak self] in self?.currentContent?.copySelection() }
        pane.onExport = { [weak self] in self?.currentContent?.exportCSV() }
        pane.onResize = { [weak self] height in
            guard let self, let wc = self.windowController else { return }
            wc.analysisAccessoryHeight = height
            self.heights[self.currentKey] = wc.analysisAccessoryHeight
        }
    }

    // MARK: - 開閉

    /// メニューから呼ばれる入口。開いていなければ開き、そのタブを選ぶ。
    /// 対象のドキュメントが無ければ false（core がビープを鳴らす）。
    @discardableResult
    func show(_ feature: AnalysisFeature, in window: NSWindow?) -> Bool {
        guard let wc = (window?.windowController as? MainWindowController)
                ?? (NSApp.keyWindow?.windowController as? MainWindowController) else { return false }
        windowController = wc
        guard wc.activeDocument != nil else { return false }

        currentKey = wc.activeDocument?.fileURL?.path ?? ""
        if !isOpen {
            wc.setAnalysisAccessory(pane, height: heights[currentKey] ?? AnalysisPane.defaultHeight)
            isOpen = true
        }
        pane.select(feature)
        showContent(for: feature)
        refreshTarget()
        return true
    }

    func close() {
        cancel()
        windowController?.setAnalysisAccessory(nil)
        isOpen = false
    }

    // MARK: - 中身

    private var currentContent: AnalysisFeatureView? { contents[pane.selectedFeature] }

    private func showContent(for feature: AnalysisFeature, autoRun: Bool = true) {
        let view = contents[feature] ?? makeContent(for: feature)
        contents[feature] = view
        pane.setContent(view)
        pane.setSummary(view.summary)
        refreshTarget()
        // **まだ結果を出せていないタブは、開かれるたびに走らせる。**
        // 初回だけにすると、「構造化表示にしてから、もう一度メニューを選ぶ」が
        // 何も起きない（実機で踏んだ）。結果が出ているタブは勝手に走らせない
        // ——10GB では選び直すたびに数秒待たされることになるので。
        if autoRun && (!view.hasResult || ranTarget[feature] != targetSignature()) {
            ranTarget[feature] = targetSignature()
            view.run(document: windowController?.activeDocument)
        }
    }

    private func makeContent(for feature: AnalysisFeature) -> AnalysisFeatureView {
        var view: AnalysisFeatureView
        switch feature {
        case .aggregate:
            let aggregate = AggregateView()
            // 表の行をダブルクリック → その値で本文を絞り込む（数える → 見る の往復）。
            aggregate.onFilterValue = { [weak self] value in
                self?.windowController?.applyLiteralFilter(value)
                self?.markCurrent(.aggregate)
                self?.refreshTarget()
            }
            view = aggregate
        case .crossFileSearch:
            let search = CrossFileSearchView()
            // 結果の行をクリック → そのファイルのその行を開く（**開いていればそのタブへ**）。
            search.onOpenLine = { [weak self] url, line in
                self?.windowController?.open(url: url, line: line)
            }
            // 結果を右クリック → そのファイルを開いて、検索した式で値を数える。
            search.onAggregateHit = { [weak self] url, pattern, caseSensitive in
                self?.aggregateHit(url, pattern: pattern, caseSensitive: caseSensitive)
            }
            view = search
        case .timeHistogram:
            let histogram = TimeHistogramView()
            // 時間帯をドラッグ → その時間帯の行だけ本文に残す。
            // **棒から行番号を逆算しない**（時刻が前後するログでは嘘になる）。
            // もう一度読んで、実際にその時間帯に入る行を集めてから渡す。
            histogram.onSelectRange = { [weak self] range in self?.filterTimeRange(range) }
            histogram.onAggregateRange = { [weak self] in self?.aggregateSelectedRange() }
            view = histogram
        case .columnStats:
            let stats = ColumnStatsView()
            // 表の行をダブルクリック → その列で C1 を実行する（当たりを付ける → 中身を見る）。
            stats.onInspectColumn = { [weak self] index, kind in
                if kind == .datetime { self?.openTimeHistogram() } else { self?.inspectColumn(index) }
            }
            // 異常行をダブルクリック → その行へジャンプ（外科手術）
            stats.onOpenLine = { [weak self] url, line in
                self?.windowController?.open(url: url, line: line)
            }
            // 異常行の「その場修正」用の本文取得と置換
            stats.onGetLineText = { [weak self] line in
                self?.windowController?.lineText(line)
            }
            stats.onReplaceLine = { [weak self] line, newText in
                self?.windowController?.replaceLine(line, with: newText) ?? false
            }
            // エラー検知時のみテキスト側を自動で構造化表示へ切り替える
            stats.onRequestStructuredMode = { [weak self] mode in
                self?.windowController?.setActiveStructuredMode(mode)
            }
            view = stats
        default:
            // Slice D 以降でここに実物（時間分布・横断検索）を差す。
            view = PlaceholderFeatureView()
        }
        view.onRequestRun = { [weak self] in self?.run() }
        view.onStateChange = { [weak self] summary, running, progress in
            self?.pane.setSummary(summary)
            self?.pane.setRunning(running, progress: progress)
        }
        return view
    }

    /// C3 の時間帯から本文の絞り込みへ渡る。nil で解除。
    private func filterTimeRange(_ range: Range<Int>?) {
        guard let wc = windowController, let document = wc.activeDocument else { return }
        guard let range else {
            aggregateWhenRangeReady = false
            wc.showOnlyLines([])
            markCurrent(.timeHistogram)
            refreshTarget()
            return
        }
        let histogram = contents[.timeHistogram] as? TimeHistogramView
        pane.setRunning(true, progress: 0)
        rangeFilterInFlight = true
        rangeRunner.lines(in: range, document: document, options: histogram?.currentOptions ?? .init(),
                          progress: { [weak self] p in self?.pane.setRunning(true, progress: p) },
                          completion: { [weak self] lines, capped in
                              guard let self else { return }
                              self.rangeFilterInFlight = false
                              self.pane.setRunning(false)
                              guard !lines.isEmpty else { self.aggregateWhenRangeReady = false; NSSound.beep(); return }
                              self.windowController?.showOnlyLines(lines)
                              self.markCurrent(.timeHistogram)
                              self.refreshTarget()
                              if capped { NSSound.beep() }
                              if self.aggregateWhenRangeReady { self.aggregateWhenRangeReady = false; self.openAggregate() }
                          })
    }

    /// C3 で選んだ時間帯を、そのまま C1 で数える。絞り込みはドラッグで済んでいるので、
    /// ここは「集計タブへ移って走らせる」だけ（行の集め直しが終わっていなければ待つ）。
    private func aggregateSelectedRange() {
        if rangeFilterInFlight { aggregateWhenRangeReady = true } else { openAggregate() }
    }

    private func openAggregate() {
        pane.select(.aggregate)
        showContent(for: .aggregate, autoRun: false)
        run()
    }

    /// C5 の結果から C1 へ渡る。ファイルを開いてから（開いた直後は次のループで本文が揃う）、
    /// 集計タブへ移って、検索した式で数える。
    private func aggregateHit(_ url: URL, pattern: String, caseSensitive: Bool) {
        windowController?.open(url: url, line: 1)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pane.select(.aggregate)
            self.showContent(for: .aggregate, autoRun: false)
            (self.contents[.aggregate] as? AggregateView)?
                .aggregateByRegex(pattern, caseSensitive: caseSensitive,
                                  document: self.windowController?.activeDocument)
            self.markCurrent(.aggregate)
            self.refreshTarget()
        }
    }

    /// C2 の日時の列から C3 へ渡る。C3 は行の中の時刻を読むので、列の指定はしない
    /// （日時の列が複数ある表では、行の中で先に見つかった時刻が使われる）。
    /// 結果がまだ無ければ、開いたついでに走らせる。
    private func openTimeHistogram() {
        pane.select(.timeHistogram)
        showContent(for: .timeHistogram)
    }

    /// C2 の行から C1 へ渡る。**タブを切り替えてから同じ列で数え直す**ので、
    /// 「列の統計で見つけた列」と「集計で見ている列」が必ず一致する。
    private func inspectColumn(_ index: Int) {
        pane.select(.aggregate)
        // ここで自動実行させない（この直後に「その列で」走らせるので、既定の集計を
        // 1 回余計に走らせると 10GB では数秒まるまる無駄になる）。
        showContent(for: .aggregate, autoRun: false)
        (contents[.aggregate] as? AggregateView)?
            .inspectColumn(index, document: windowController?.activeDocument)
        markCurrent(.aggregate)
    }

    /// 「対象: 全体 / フィルタ中の N 行」。**何を数えたのかを常に見せる。**
    private func refreshTarget() {
        guard let doc = windowController?.activeDocument else {
            pane.setTarget(S.noDocument)
            return
        }
        if let filtered = doc.filterMatchLines {
            pane.setTarget(S.targetFiltered(filtered.count))
        } else {
            pane.setTarget(S.targetWhole)
        }
    }

    /// いまの「対象」の印。開いているファイルと、絞り込み（件数と両端の行）が同じなら同じ値。
    private func targetSignature() -> Int {
        guard let doc = windowController?.activeDocument else { return 0 }
        var hasher = Hasher()
        hasher.combine(doc.fileURL?.path)
        hasher.combine(doc.structuredMode != nil)
        if let lines = doc.filterMatchLines {
            hasher.combine(lines.count)
            hasher.combine(lines.first)
            hasher.combine(lines.last)
        } else {
            hasher.combine(-1)
        }
        return hasher.finalize()
    }

    /// 自分で絞り込んだ（時間帯・値の選択）あとは、その機能の結果を「最新」と見なす
    /// （戻ったときに、いま見ていた一覧を絞り込み後の数字で上書きしない）。
    private func markCurrent(_ feature: AnalysisFeature) { ranTarget[feature] = targetSignature() }

    private func run() {
        ranTarget[pane.selectedFeature] = targetSignature()
        refreshTarget()
        currentContent?.run(document: windowController?.activeDocument)
    }

    private func cancel() {
        currentContent?.cancel()
        pane.setRunning(false)
    }
}

/// 4 機能の中身が満たす口。**枠（AnalysisPane）は中身を知らない。**
protocol AnalysisFeatureView: NSView {
    /// ヘッダに出す 1 行（「8,642万行 / 3.32 秒 / 3 種類」）。
    var summary: String { get }
    /// **いま走らせ直してほしい**と枠へ頼む（ペインの中のボタンから呼ぶ）。
    ///
    /// 自分が持っている `ActiveDocument` で走り直してはいけない——あれは**値の写し**で、
    /// 撮った瞬間のフィルタしか知らない。実機で踏んだ: ERROR で絞ってから「もう一度実行」を
    /// 押すと、絞る前の全行で走っていた（対象の表示だけが正しく、数字が全体のものになる）。
    var onRequestRun: (() -> Void)? { get set }
    /// 結果を出せているか。**空のまま置かれているタブは開くたびに走らせる**ための印。
    var hasResult: Bool { get }
    /// (要約, 走査中か, 進捗) を枠へ伝える。
    var onStateChange: ((String, Bool, Double) -> Void)? { get set }
    func run(document: ActiveDocument?)
    func cancel()
    func copySelection()
    func exportCSV()
}

extension AnalysisFeatureView {
    var hasResult: Bool { !summary.isEmpty }
    func copySelection() {}
    func exportCSV() {}
}

/// 土台だけが入っている段階の中身。**空であることを隠さない。**
private final class PlaceholderFeatureView: NSView, AnalysisFeatureView {
    var summary: String { "" }
    var onRequestRun: (() -> Void)?
    var onStateChange: ((String, Bool, Double) -> Void)?

    private let label = NSTextField(labelWithString: S.notReady)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    func run(document: ActiveDocument?) {}
    func cancel() {}
}