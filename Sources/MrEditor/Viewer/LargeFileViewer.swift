import AppKit

/// 表示状態をステータスバーへ伝えるための情報。
struct ViewerState {
    var encodingName: String
    var lineCount: Int
    var lineCountIsExact: Bool
    var fileSize: Int
    var indexProgress: Double // 0...1
}

/// 巨大ファイル表示の統括。
///
/// NSScrollView の巨大 documentView は使わず、固定サイズの `DocumentView` と
/// 自前の `NSScroller`（単位＝行）で任意サイズへスケールさせる。
final class LargeFileViewer: NSView, DocumentPane {
    private let documentView = DocumentView()
    private let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))

    private var fileBuffer: FileBuffer?
    private var lineIndex: LineIndex?
    private var encoding: DetectedEncoding = .utf8
    /// 開いているファイル（サイドバー表示用）。
    private(set) var fileURL: URL?

    /// 表示中の先頭行。
    private var topLine: Int = 0
    /// トラックパッドの端数スクロールを溜める。
    private var scrollAccumulator: CGFloat = 0
    /// 1 行の最大読み取りバイト数（極端に長い行の保険）。
    private let maxLineBytes = 64 * 1024

    private let scrollerWidth: CGFloat = 16

    /// 状態変化の通知（ステータスバー更新用）。
    var onStateChange: ((ViewerState) -> Void)?

    /// 検索クエリ（空なら強調なし）。大小は区別しない。
    private var searchQuery: String = ""
    /// クエリを空白で分割した語。全語を含む行が一致（AND）。各語を強調する。
    private var searchTerms: [String] = []
    /// 正規表現モードか。ON のときは searchQuery 全体を1つのパターンとして扱う。
    private var regexMode = false
    private var searchRegex: NSRegularExpression?
    /// 大小を区別するか（既定は区別しない）。
    private var caseSensitive = false
    /// フィルタ表示（live grep）。ON のとき一致行だけを表示する。
    private var filterMode = false
    private let matchHighlight = NSColor.systemYellow.withAlphaComponent(0.45)
    private var searchEngine: SearchEngine?
    private var searchResults = SearchEngine.Result()
    private var currentMatchIdx = -1          // searchResults.lines のインデックス（未選択=-1）
    private var currentMatchLine = -1         // アクティブ一致のファイル行（強調用・未選択=-1）
    private var searchDebounce: DispatchWorkItem?
    private var searchEpoch = 0               // 検索の世代（古い結果の取り込み防止）

    /// tail -f（末尾追従）。ON のとき定期的にファイル成長を検知して追う。
    private var followMode = false
    private var followTimer: Timer?

    /// 検索状態の通知（検索バーの件数表示用）: (現在, 総数, 検索中, 進捗%, 無効パターン).
    var onSearchState: ((Int, Int, Bool, Int, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        followTimer?.invalidate()
    }

    private func setup() {
        let font = Self.editorFont()
        documentView.configure(font: font)
        documentView.onScrollWheel = { [weak self] in self?.handleScrollWheel($0) }
        documentView.onKeyDown = { [weak self] in self?.handleKeyDown($0) }
        documentView.onCopy = { [weak self] in self?.copyVisible() }
        addSubview(documentView)

        scroller.scrollerStyle = .legacy
        scroller.knobStyle = .default
        scroller.target = self
        scroller.action = #selector(scrollerAction(_:))
        scroller.isEnabled = false
        addSubview(scroller)

        registerForDraggedTypes([.fileURL])
        layoutSubviewsManually()
    }

    // MARK: - フォントサイズ（全ドキュメント共通・永続化）

    static let defaultFontSize: CGFloat = 12
    static let minFontSize: CGFloat = 9
    static let maxFontSize: CGFloat = 28
    private static let fontSizeKey = "MrEditor.fontSize"

    /// 現在のエディタ用フォントサイズ。起動時は保存値（なければ既定）。
    private static var fontSize: CGFloat = {
        let v = UserDefaults.standard.double(forKey: fontSizeKey)
        return v > 0 ? CGFloat(v) : defaultFontSize
    }()

    static var currentFontSize: CGFloat { fontSize }

    /// グローバルなフォントサイズを設定（min/max にクランプし永続化）。クランプ後の値を返す。
    @discardableResult
    static func setFontSize(_ size: CGFloat) -> CGFloat {
        let clamped = min(max(minFontSize, size), maxFontSize)
        fontSize = clamped
        UserDefaults.standard.set(Double(clamped), forKey: fontSizeKey)
        return clamped
    }

    static func editorFont() -> NSFont {
        let size = fontSize
        if let f = NSFont(name: "SF Mono", size: size) { return f }
        if let f = NSFont(name: "Menlo", size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 現在のグローバルフォントサイズを自身の表示へ反映する。
    func applyCurrentFontSize() {
        documentView.configure(font: Self.editorFont())
        layoutSubviewsManually()
        refresh()
    }

    // MARK: - レイアウト

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutSubviewsManually()
        refresh()
    }

    private func layoutSubviewsManually() {
        let h = bounds.height
        let w = bounds.width
        documentView.frame = NSRect(x: 0, y: 0, width: max(0, w - scrollerWidth), height: h)
        scroller.frame = NSRect(x: max(0, w - scrollerWidth), y: 0, width: scrollerWidth, height: h)
    }

    private var visibleLineCount: Int {
        max(1, Int(ceil(documentView.bounds.height / documentView.lineHeight)))
    }

    /// 現在の表示空間の総行数（通常＝ファイル行数 / フィルタ＝一致行数）。
    private var displayCount: Int {
        filterMode ? searchResults.lines.count : (lineIndex?.displayLineCount ?? 0)
    }

    private var maxTopLine: Int {
        max(0, displayCount - visibleLineCount)
    }

    // MARK: - ファイルを開く

    @discardableResult
    func open(url: URL) -> Bool {
        guard let buffer = FileBuffer(url: url) else {
            NSSound.beep()
            return false
        }
        self.fileBuffer = buffer
        self.fileURL = url

        // 文字コード判定（先頭 64KB）
        let prefix = buffer.data(in: 0..<min(buffer.count, 64 * 1024))
        self.encoding = EncodingDetector.detect(prefix)
        self.searchEngine = SearchEngine(buffer: buffer, encoding: encoding)
        clearSearchState()

        // 即時表示用の行数推定 → すぐ描ける
        let idx = LineIndex(buffer: buffer)
        idx.estimatePrefix()
        self.lineIndex = idx

        topLine = 0
        scrollAccumulator = 0
        refresh()

        // バックグラウンドで全索引を構築
        partialProgress = 0
        idx.buildInBackground(progress: { [weak self] p in
            self?.partialProgress = p
            self?.emitState()
        }, completion: { [weak self] in
            self?.refresh()
        })
        return true
    }

    // MARK: - 再描画

    private func refresh() {
        guard let idx = lineIndex, let buffer = fileBuffer else {
            documentView.lines = []
            documentView.needsDisplay = true
            return
        }

        topLine = min(max(0, topLine), maxTopLine)

        let needed = visibleLineCount + 1
        var attributed: [NSAttributedString] = []
        if filterMode {
            // 一致行だけを表示（非連続）。各行のバイト範囲を個別に解決する。
            let matches = searchResults.lines
            var numbers: [Int] = []
            var k = 0
            while k < needed {
                let row = topLine + k
                guard row < matches.count else { break }
                let fl = matches[row]
                let range = idx.lineRanges(from: fl, count: 1).first ?? (0..<0)
                attributed.append(decodeLine(range, buffer: buffer))
                numbers.append(fl)
                k += 1
            }
            documentView.lineNumbers = numbers
            documentView.activeRow = nil
        } else {
            // 連続表示（通常）。1回の前方スキャンで可視行を取得。
            let ranges = idx.lineRanges(from: topLine, count: needed)
            attributed.reserveCapacity(ranges.count)
            for r in ranges {
                attributed.append(decodeLine(r, buffer: buffer))
            }
            documentView.lineNumbers = nil
            documentView.firstLineNumber = topLine
            // アクティブ一致が可視範囲にあれば帯で強調
            let visible = (currentMatchIdx >= 0 && currentMatchLine >= topLine
                           && currentMatchLine < topLine + attributed.count)
            documentView.activeRow = visible ? currentMatchLine - topLine : nil
        }

        documentView.lines = attributed
        documentView.needsDisplay = true

        updateScroller()
        emitState()
        if filterMode {
            emitSearchState(searching: !searchResults.isComplete,
                            progress: searchResults.isComplete ? 100 : 0, invalid: false)
        }
    }

    private func decodeLine(_ range: Range<Int>, buffer: FileBuffer) -> NSAttributedString {
        let capped = range.lowerBound..<min(range.upperBound, range.lowerBound + maxLineBytes)
        let data = buffer.data(in: capped)
        let str: String
        if let s = String(data: data, encoding: encoding.stringEncoding) {
            str = s
        } else {
            // 化けても落ちない: UTF-8 置換デコードへフォールバック
            str = String(decoding: data, as: UTF8.self)
        }
        // 制御文字でレイアウトが崩れないようタブは見やすさのため残す（描画側で処理）
        let attr = NSMutableAttributedString(string: str, attributes: documentView.textAttributes)
        if !searchTerms.isEmpty || searchRegex != nil {
            highlightMatches(in: attr, text: str)
        }
        return attr
    }

    /// 行内の一致箇所に背景色を付ける（可視行のみ・グローバル索引不要）。
    private func highlightMatches(in attr: NSMutableAttributedString, text: String) {
        if let rx = searchRegex {
            let full = NSRange(location: 0, length: (text as NSString).length)
            rx.enumerateMatches(in: text, range: full) { m, _, _ in
                if let r = m?.range, r.length > 0 {
                    attr.addAttribute(.backgroundColor, value: matchHighlight, range: r)
                }
            }
        } else {
            let opts: NSString.CompareOptions = caseSensitive ? [] : .caseInsensitive
            for term in searchTerms {
                var from = text.startIndex
                while let r = text.range(of: term, options: opts, range: from..<text.endIndex) {
                    attr.addAttribute(.backgroundColor, value: matchHighlight, range: NSRange(r, in: text))
                    if r.upperBound == from { break }       // 空マッチの保険
                    from = r.upperBound
                }
            }
        }
    }

    // MARK: - 検索

    /// 検索クエリを設定（リテラルは空白区切りで AND、正規表現は全体を1パターン）。
    func setSearchQuery(_ q: String) {
        guard q != searchQuery else { return }
        searchQuery = q
        rebuildSearch()
    }

    /// 正規表現モードの切替。
    func setRegexMode(_ on: Bool) {
        guard on != regexMode else { return }
        regexMode = on
        rebuildSearch()
    }

    /// 大小区別の切替。
    func setCaseSensitive(_ on: Bool) {
        guard on != caseSensitive else { return }
        caseSensitive = on
        rebuildSearch()
    }

    /// クエリ／モードからパターンを組み立て、可視強調を即更新し背景走査を起動する。
    private func rebuildSearch() {
        searchEpoch += 1
        let epoch = searchEpoch
        searchDebounce?.cancel()
        searchEngine?.cancel()
        currentMatchIdx = -1
        currentMatchLine = -1

        searchTerms = []
        searchRegex = nil
        var invalid = false
        if regexMode {
            if !searchQuery.isEmpty {
                let opts: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
                do {
                    searchRegex = try NSRegularExpression(pattern: searchQuery, options: opts)
                } catch { invalid = true }
            }
        } else {
            searchTerms = searchQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        refresh()                       // 可視行の強調を即反映

        if searchQuery.isEmpty {
            searchResults = .init(); emitSearchState(searching: false, progress: 0, invalid: false); return
        }
        if invalid {
            searchResults = .init(); emitSearchState(searching: false, progress: 0, invalid: true); return
        }
        let mode: SearchMode = regexMode ? .regex(searchRegex!) : .terms(searchTerms)
        emitSearchState(searching: true, progress: 0, invalid: false)   // "検索中…" を即出す
        let work = DispatchWorkItem { [weak self] in self?.runSearch(mode, epoch: epoch) }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func runSearch(_ mode: SearchMode, epoch: Int) {
        searchEngine?.search(mode, caseSensitive: caseSensitive, progress: { [weak self] res, p in
            guard let self, self.searchEpoch == epoch else { return }
            self.searchResults = res
            if self.filterMode { self.refresh() }   // フィルタ表示は一致行が増えるたび更新
            else { self.emitSearchState(searching: true, progress: Int(p * 100), invalid: false) }
        }, completion: { [weak self] res in
            guard let self, self.searchEpoch == epoch else { return }
            self.searchResults = res
            if self.filterMode { self.refresh() }
            else { self.emitSearchState(searching: false, progress: 100, invalid: false) }
        })
    }

    private func clearSearchState() {
        searchQuery = ""
        searchTerms = []
        searchRegex = nil
        filterMode = false
        searchResults = .init()
        currentMatchIdx = -1
        currentMatchLine = -1
        searchEpoch += 1
        searchDebounce?.cancel()
        searchEngine?.cancel()
    }

    /// フィルタ表示（live grep）の切替。
    func setFilterMode(_ on: Bool) {
        guard on != filterMode else { return }
        let matches = searchResults.lines
        if on {
            filterMode = true
            topLine = max(0, currentMatchIdx)            // 現在の一致（なければ先頭）から
        } else {
            let fileLine = (topLine >= 0 && topLine < matches.count) ? matches[topLine] : topLine
            filterMode = false
            topLine = fileLine                            // 見ていた一致行のファイル行へ戻す
        }
        scrollAccumulator = 0
        refresh()
    }

    private func emitSearchState(searching: Bool, progress: Int, invalid: Bool) {
        let total = searchResults.lineCount
        let current: Int
        if filterMode {
            current = searchResults.lines.isEmpty ? 0 : min(topLine + 1, total)
        } else {
            current = currentMatchIdx >= 0 ? currentMatchIdx + 1 : 0
        }
        onSearchState?(current, total, searching, progress, invalid)
    }

    /// 一致行の最初の「topLine より後ろ」の位置を返す（二分探索）。
    private func firstMatchIndex(after line: Int) -> Int {
        let lines = searchResults.lines
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid] > line { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    func findNext() {
        // フィルタ表示中は全行が一致＝1行ぶんスクロール。
        if filterMode {
            guard !searchResults.lines.isEmpty else { NSSound.beep(); return }
            setTopLine(topLine + 1); return
        }
        let lines = searchResults.lines
        guard !lines.isEmpty else { NSSound.beep(); return }
        let idx: Int
        if currentMatchIdx >= 0 {
            idx = (currentMatchIdx + 1) % lines.count
        } else {
            let f = firstMatchIndex(after: topLine - 1)   // topLine 以上の最初の一致
            idx = f < lines.count ? f : 0
        }
        jumpToMatch(idx)
    }

    func findPrev() {
        if filterMode {
            guard !searchResults.lines.isEmpty else { NSSound.beep(); return }
            setTopLine(topLine - 1); return
        }
        let lines = searchResults.lines
        guard !lines.isEmpty else { NSSound.beep(); return }
        let idx: Int
        if currentMatchIdx >= 0 {
            idx = (currentMatchIdx - 1 + lines.count) % lines.count
        } else {
            let f = firstMatchIndex(after: topLine - 1)
            idx = (f - 1 + lines.count) % lines.count
        }
        jumpToMatch(idx)
    }

    private func jumpToMatch(_ idx: Int) {
        currentMatchIdx = idx
        currentMatchLine = searchResults.lines[idx]
        setTopLine(searchResults.lines[idx])
        emitSearchState(searching: !searchResults.isComplete,
                        progress: searchResults.isComplete ? 100 : 0, invalid: false)
    }

    /// 本文へフォーカスを戻す（検索バーを閉じた時など）。
    func focusContent() {
        window?.makeFirstResponder(documentView)
    }

    /// 指定行（1 始まり）へ移動する。
    func goToLine(_ line1Based: Int) {
        if filterMode { setFilterMode(false) }
        setTopLine(max(0, line1Based - 1))
        focusContent()
    }

    /// 現在の状態を onStateChange に再送信する（ドキュメント切替時のステータスバー更新用）。
    func reEmitState() { emitState() }

    /// 可視範囲（いま表示している行）をプレーンテキストでクリップボードへコピーする。
    private func copyVisible() {
        let text = documentView.lines.map { $0.string }.joined(separator: "\n")
        guard !text.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - tail -f（末尾追従）

    var isFollowing: Bool { followMode }

    /// 末尾追従の切替。ON で即末尾へ飛び、0.5s ごとに成長を追う。
    func setFollowMode(_ on: Bool) {
        guard on != followMode else { return }
        followMode = on
        if on {
            topLine = maxTopLine
            refresh()
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.followTick() }
            RunLoop.main.add(t, forMode: .common)
            followTimer = t
        } else {
            followTimer?.invalidate()
            followTimer = nil
        }
    }

    private func followTick() {
        guard followMode, let buffer = fileBuffer, let idx = lineIndex else { return }
        let wasAtBottom = (topLine >= maxTopLine)
        guard let newSize = buffer.remapIfGrownTry() else { return }  // 成長＆排他取得できたとき
        idx.extend(toByte: newSize)
        if wasAtBottom { topLine = maxTopLine }   // 末尾にいたら追従、上を見ていたら止める
        refresh()
    }

    private func updateScroller() {
        guard lineIndex != nil else {
            scroller.isEnabled = false
            return
        }
        let total = displayCount
        let visible = visibleLineCount
        if total > visible {
            scroller.isEnabled = true
            scroller.knobProportion = CGFloat(visible) / CGFloat(total)
            let denom = maxTopLine
            scroller.doubleValue = denom > 0 ? Double(topLine) / Double(denom) : 0
        } else {
            scroller.isEnabled = false
            scroller.knobProportion = 1
            scroller.doubleValue = 0
        }
    }

    private func emitState() {
        guard let idx = lineIndex, let buffer = fileBuffer else { return }
        let state = ViewerState(
            encodingName: encoding.displayName,
            lineCount: idx.displayLineCount,
            lineCountIsExact: idx.isComplete,
            fileSize: buffer.count,
            indexProgress: idx.isComplete ? 1.0 : partialProgress
        )
        onStateChange?(state)
    }

    /// 全索引途中の進捗（buildInBackground から更新）。
    private var partialProgress: Double = 0

    // MARK: - スクロール / キー入力

    private func handleScrollWheel(_ event: NSEvent) {
        guard lineIndex != nil else { return }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            delta *= documentView.lineHeight // 行ホイールは行単位に換算
        }
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator / documentView.lineHeight)
        if lines != 0 {
            scrollAccumulator -= CGFloat(lines) * documentView.lineHeight
            setTopLine(topLine - lines) // 下方向スクロールで topLine 増
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let page = max(1, visibleLineCount - 1)
        switch event.keyCode {
        case 125: setTopLine(topLine + 1)            // ↓
        case 126: setTopLine(topLine - 1)            // ↑
        case 121: setTopLine(topLine + page)         // Page Down
        case 116: setTopLine(topLine - page)         // Page Up
        case 115: setTopLine(0)                       // Home
        case 119: setTopLine(maxTopLine)             // End
        case 49:  setTopLine(topLine + page)         // Space
        default: break
        }
    }

    private func setTopLine(_ value: Int) {
        let clamped = min(max(0, value), maxTopLine)
        guard clamped != topLine else { return }
        topLine = clamped
        refresh()
    }

    @objc private func scrollerAction(_ sender: NSScroller) {
        let page = max(1, visibleLineCount - 1)
        switch sender.hitPart {
        case .knob, .knobSlot:
            topLine = Int(Double(maxTopLine) * sender.doubleValue)
        case .decrementPage:
            topLine -= page
        case .incrementPage:
            topLine += page
        case .decrementLine:
            topLine -= 1
        case .incrementLine:
            topLine += 1
        default:
            break
        }
        topLine = min(max(0, topLine), maxTopLine)
        refresh()
    }

    // MARK: - ドラッグ & ドロップ

    /// ファイルがドロップされたとき（複数ドキュメントとして開くのはコントローラ側）。
    var onDropFiles: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            return false
        }
        onDropFiles?(urls)
        return true
    }
}
