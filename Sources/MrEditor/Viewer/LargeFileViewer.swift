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
final class LargeFileViewer: NSView {
    private let documentView = DocumentView()
    private let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))

    private var fileBuffer: FileBuffer?
    private var lineIndex: LineIndex?
    private var encoding: DetectedEncoding = .utf8

    /// 表示中の先頭行。
    private var topLine: Int = 0
    /// トラックパッドの端数スクロールを溜める。
    private var scrollAccumulator: CGFloat = 0
    /// 1 行の最大読み取りバイト数（極端に長い行の保険）。
    private let maxLineBytes = 64 * 1024

    private let scrollerWidth: CGFloat = 16

    /// 状態変化の通知（ステータスバー更新用）。
    var onStateChange: ((ViewerState) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let font = Self.editorFont()
        documentView.configure(font: font)
        documentView.onScrollWheel = { [weak self] in self?.handleScrollWheel($0) }
        documentView.onKeyDown = { [weak self] in self?.handleKeyDown($0) }
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

    static func editorFont() -> NSFont {
        if let f = NSFont(name: "SF Mono", size: 12) { return f }
        if let f = NSFont(name: "Menlo", size: 12) { return f }
        return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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

    private var maxTopLine: Int {
        guard let idx = lineIndex else { return 0 }
        return max(0, idx.displayLineCount - visibleLineCount)
    }

    // MARK: - ファイルを開く

    @discardableResult
    func open(url: URL) -> Bool {
        guard let buffer = FileBuffer(url: url) else {
            NSSound.beep()
            return false
        }
        self.fileBuffer = buffer

        // 文字コード判定（先頭 64KB）
        let prefix = buffer.data(in: 0..<min(buffer.count, 64 * 1024))
        self.encoding = EncodingDetector.detect(prefix)

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

        window?.makeFirstResponder(documentView)
        window?.title = url.lastPathComponent + " — MrEditor"
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
        let ranges = idx.lineRanges(from: topLine, count: needed)
        var attributed: [NSAttributedString] = []
        attributed.reserveCapacity(ranges.count)
        for r in ranges {
            attributed.append(decodeLine(r, buffer: buffer))
        }

        documentView.firstLineNumber = topLine
        documentView.lines = attributed
        documentView.needsDisplay = true

        updateScroller()
        emitState()
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
        return NSAttributedString(string: str, attributes: documentView.textAttributes)
    }

    private func updateScroller() {
        guard let idx = lineIndex else {
            scroller.isEnabled = false
            return
        }
        let total = idx.displayLineCount
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first else {
            return false
        }
        return open(url: url)
    }
}
