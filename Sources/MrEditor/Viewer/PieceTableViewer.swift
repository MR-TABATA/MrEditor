import AppKit

/// 巨大ファイルを piece table バックで表示する自前ビューア（B1＝描画フェーズ）。
///
/// `LargeFileViewer` と同じ「固定サイズ `DocumentView` ＋自前 `NSScroller`（行単位）」で
/// 任意サイズへスケールさせる。原本は `FileBuffer`（mmap）→ `FileBufferSource` 経由で
/// `PieceTable` に被せ、可視行のバイトだけをその場でデコードして描く。
///
/// B1 は **読み取り専用**：キャレット／選択の「モデル＋描画」とマウス操作（クリックで
/// 位置決め・ドラッグで選択・⌘C コピー）までを担い、テキスト入力・編集は持たない。
/// キー入力はスクロールのみ（矢印でのキャレット移動・編集は B2）。検索／追従は B4 で
/// piece table 上に再実装するまで非対応（`supportsSearch/Follow = false`）。
final class PieceTableViewer: NSView, DocumentPane {
    private let documentView = DocumentView()
    private let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))

    private var fileBuffer: FileBuffer?
    private var lineIndex: LineIndex?
    /// 原本に被せた piece table（B2 以降の編集の土台。完成索引から改行数を渡して生成）。
    private var pieceTable: PieceTable?
    private var encoding: DetectedEncoding = .utf8
    private(set) var fileURL: URL?

    /// 表示中の先頭行。
    private var topLine = 0
    /// トラックパッドの端数スクロールを溜める。
    private var scrollAccumulator: CGFloat = 0
    /// 1 行の最大読み取りバイト数（極端に長い行の保険）。
    private let maxLineBytes = 64 * 1024
    private let scrollerWidth: CGFloat = 16

    /// 現在表示している各行のバイト範囲（CRLF 除去済み・キャレット↔バイト変換に使う）。
    private var visibleRanges: [Range<Int>] = []

    // MARK: - キャレット / 選択（バイトドメイン）

    /// キャレット位置（ドキュメント先頭からのバイトオフセット）。
    private var caretByte = 0
    /// ドラッグ選択のアンカー（バイト）。クリックで caret と同値＝選択なし。
    private var selectionAnchor = 0
    /// 現在の選択範囲（空なら nil）。
    private var selectionRange: Range<Int>? {
        let lo = min(caretByte, selectionAnchor)
        let hi = max(caretByte, selectionAnchor)
        return lo < hi ? lo..<hi : nil
    }
    private var blinkTimer: Timer?
    /// 上下移動で保持する目標カラム（行内 UTF-16 オフセット）。横移動・編集で無効化。
    private var caretGoalColumn: Int?

    var onStateChange: ((ViewerState) -> Void)?
    var onSearchState: ((Int, Int, Bool, Int, Bool) -> Void)?   // B1 では未使用
    var onDropFiles: (([URL]) -> Void)?

    // 検索・追従は B4 まで非対応。
    var supportsSearch: Bool { false }
    var supportsFollow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        blinkTimer?.invalidate()
    }

    private func setup() {
        documentView.configure(font: LargeFileViewer.editorFont())
        documentView.onScrollWheel = { [weak self] in self?.handleScrollWheel($0) }
        documentView.onKeyDown = { [weak self] in self?.handleKeyDown($0) }
        documentView.onCopy = { [weak self] in self?.copySelectionOrVisible() }
        documentView.onMouseDown = { [weak self] in self?.handleMouseDown($0) }
        documentView.onMouseDragged = { [weak self] in self?.handleMouseDragged($0) }
        addSubview(documentView)

        scroller.scrollerStyle = .legacy
        scroller.knobStyle = .default
        scroller.target = self
        scroller.action = #selector(scrollerAction(_:))
        scroller.isEnabled = false
        addSubview(scroller)

        // キャレット点滅。
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.documentView.caretOn.toggle()
            self.documentView.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t

        registerForDraggedTypes([.fileURL])
        layoutSubviewsManually()
    }

    // MARK: - レイアウト

    override var isFlipped: Bool { true }

    func applyCurrentFontSize() {
        documentView.configure(font: LargeFileViewer.editorFont())
        layoutSubviewsManually()
        refresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutSubviewsManually()
        refresh()
    }

    private func layoutSubviewsManually() {
        let h = bounds.height, w = bounds.width
        documentView.frame = NSRect(x: 0, y: 0, width: max(0, w - scrollerWidth), height: h)
        scroller.frame = NSRect(x: max(0, w - scrollerWidth), y: 0, width: scrollerWidth, height: h)
    }

    private var visibleLineCount: Int {
        max(1, Int(ceil(documentView.bounds.height / documentView.lineHeight)))
    }

    /// 論理行数。piece table 完成後はそちらを真とする（編集で LineIndex が陳腐化するため）。
    private var displayCount: Int { pieceTable?.lineCount ?? lineIndex?.displayLineCount ?? 0 }
    private var maxTopLine: Int { max(0, displayCount - visibleLineCount) }

    // MARK: - ファイルを開く

    @discardableResult
    func open(url: URL) -> Bool {
        guard let buffer = FileBuffer(url: url) else { NSSound.beep(); return false }
        self.fileBuffer = buffer
        self.fileURL = url
        self.pieceTable = nil

        let prefix = buffer.data(in: 0..<min(buffer.count, 64 * 1024))
        self.encoding = EncodingDetector.detect(prefix)

        let idx = LineIndex(buffer: buffer)
        idx.estimatePrefix()
        self.lineIndex = idx

        caretByte = 0
        selectionAnchor = 0
        topLine = 0
        scrollAccumulator = 0
        refresh()

        idx.buildInBackground(progress: { [weak self] _ in
            self?.emitState()
        }, completion: { [weak self] in
            guard let self, let buffer = self.fileBuffer, self.lineIndex === idx else { return }
            // 完成索引から原本の改行数を渡し、init の原本全スキャンを省いて piece table を作る。
            self.pieceTable = PieceTable(original: FileBufferSource(buffer),
                                         originalNewlines: idx.originalNewlines)
            // piece table が揃ったら編集を有効化（それまでは読み取り専用でスクロールのみ）。
            self.documentView.inputHandler = self
            self.refresh()
        })
        return true
    }

    // MARK: - 再描画

    private func refresh() {
        guard lineIndex != nil, fileBuffer != nil else {
            documentView.lines = []
            documentView.needsDisplay = true
            return
        }
        topLine = min(max(0, topLine), maxTopLine)

        let needed = visibleLineCount + 1
        let ranges = lineRanges(from: topLine, count: needed)
        visibleRanges = ranges
        var attributed: [NSAttributedString] = []
        attributed.reserveCapacity(ranges.count)
        for r in ranges { attributed.append(decodeLine(r)) }

        documentView.lineNumbers = nil
        documentView.firstLineNumber = topLine
        documentView.activeRow = nil
        documentView.lines = attributed
        updateCaretAndSelectionViews()
        documentView.needsDisplay = true

        updateScroller()
        emitState()
    }

    /// 可視行のバイト範囲を求める。piece table 完成後はそちら（CR 込み）、未完成なら LineIndex。
    private func lineRanges(from start: Int, count: Int) -> [Range<Int>] {
        if let pt = pieceTable {
            let total = pt.lineCount
            guard start < total, count > 0 else { return [] }
            let end = min(start + count, total)
            var out: [Range<Int>] = []
            out.reserveCapacity(end - start)
            for line in start..<end { out.append(pt.byteRange(ofLine: line)) }
            return out
        }
        return lineIndex?.lineRanges(from: start, count: count) ?? []
    }

    private func decodeLine(_ range: Range<Int>) -> NSAttributedString {
        let capped = range.lowerBound..<min(range.upperBound, range.lowerBound + maxLineBytes)
        var bytes = rawBytes(in: capped)
        // PieceTable.byteRange は CRLF の CR を残すため、描画側で落とす（LineIndex 経路では既に無い）。
        if bytes.last == 0x0D { bytes.removeLast() }
        let str = decodeString(bytes)
        return NSAttributedString(string: str, attributes: documentView.textAttributes)
    }

    /// 文書のバイト範囲を取り出す（piece table 完成後はそちら経由・未完成なら原本直読み）。
    private func rawBytes(in range: Range<Int>) -> [UInt8] {
        guard range.lowerBound < range.upperBound else { return [] }
        if let pt = pieceTable { return pt.bytes(in: range) }
        guard let buffer = fileBuffer else { return [] }
        return [UInt8](buffer.data(in: range))
    }

    /// 検出エンコードでデコード（化けても落ちないよう UTF-8 置換へフォールバック）。
    private func decodeString(_ bytes: [UInt8]) -> String {
        let data = Data(bytes)
        if let s = String(data: data, encoding: encoding.stringEncoding) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - キャレット / 選択 ↔ ビュー

    /// バイトドメインのキャレット・選択を、可視行内の (row, UTF-16 オフセット) へ写像して描画系へ渡す。
    private func updateCaretAndSelectionViews() {
        var caretView: (row: Int, utf16Index: Int)?
        for (i, r) in visibleRanges.enumerated() where caretByte >= r.lowerBound && caretByte <= r.upperBound {
            caretView = (i, utf16Index(lineStart: r.lowerBound, byteOffset: caretByte))
            break
        }
        documentView.caret = caretView

        var rows: [Int: DocumentView.RowSelection] = [:]
        if let sel = selectionRange {
            for (i, r) in visibleRanges.enumerated() {
                let touches = sel.lowerBound <= r.upperBound && sel.upperBound > r.lowerBound
                guard touches else { continue }
                let lo = max(sel.lowerBound, r.lowerBound)
                let hi = min(max(sel.upperBound, r.lowerBound), r.upperBound)
                let a = utf16Index(lineStart: r.lowerBound, byteOffset: lo)
                let b = utf16Index(lineStart: r.lowerBound, byteOffset: hi)
                rows[i] = .init(range: NSRange(location: a, length: max(0, b - a)),
                                extendsToLineEnd: sel.upperBound > r.upperBound)
            }
        }
        documentView.selectionByRow = rows
    }

    /// 行頭 `lineStart` から `byteOffset` までの内容を、その行文字列内の UTF-16 オフセットに変換する。
    private func utf16Index(lineStart: Int, byteOffset: Int) -> Int {
        guard byteOffset > lineStart else { return 0 }
        let s = decodeString(rawBytes(in: lineStart..<byteOffset))
        return (s as NSString).length
    }

    /// 行頭 `lineStart`・行文字列 `lineString`・UTF-16 オフセット `utf16Index` から文書バイトオフセットを求める。
    private func byteOffset(lineStart: Int, lineString: String, utf16Index: Int) -> Int {
        let ns = lineString as NSString
        let clamped = min(max(0, utf16Index), ns.length)
        guard clamped > 0 else { return lineStart }
        let prefix = ns.substring(to: clamped)
        let n = prefix.data(using: encoding.stringEncoding)?.count ?? Array(prefix.utf8).count
        return lineStart + n
    }

    // MARK: - マウス

    private func handleMouseDown(_ e: NSEvent) {
        guard let b = byteAt(event: e) else { return }
        caretByte = b
        selectionAnchor = b
        caretGoalColumn = nil
        showCaretNow()
        refresh()
    }

    private func handleMouseDragged(_ e: NSEvent) {
        guard let b = byteAt(event: e) else { return }
        caretByte = b
        caretGoalColumn = nil
        showCaretNow()
        refresh()
    }

    private func byteAt(event e: NSEvent) -> Int? {
        let p = documentView.convert(e.locationInWindow, from: nil)
        guard let (row, u) = documentView.index(at: p), row < visibleRanges.count else { return nil }
        let s = (row < documentView.lines.count) ? documentView.lines[row].string : ""
        return byteOffset(lineStart: visibleRanges[row].lowerBound, lineString: s, utf16Index: u)
    }

    private func showCaretNow() {
        documentView.caretOn = true
    }

    // MARK: - キャレット移動（キーボード）

    private var lineCountDoc: Int { pieceTable?.lineCount ?? 0 }
    private var docByteCount: Int { pieceTable?.byteCount ?? 0 }

    /// 行 `line` の内容バイト範囲（CRLF の CR を落とす。キャレットは CR/LF 上に乗らない）。
    private func contentRange(ofLine line: Int) -> Range<Int> {
        guard let pt = pieceTable else { return 0..<0 }
        var r = pt.byteRange(ofLine: line)
        if r.upperBound > r.lowerBound, pt.bytes(in: (r.upperBound - 1)..<r.upperBound).first == 0x0D {
            r = r.lowerBound..<(r.upperBound - 1)
        }
        return r
    }

    /// 表示上限（`maxLineBytes`）でキャップした行文字列。極端に長い行でも 1 打鍵の処理を抑える。
    private func lineString(_ cr: Range<Int>) -> String {
        let capped = cr.lowerBound..<min(cr.upperBound, cr.lowerBound + maxLineBytes)
        return decodeString(rawBytes(in: capped))
    }

    /// 行 `cr` の UTF-16 カラム `column`（クランプ）に対応する文書バイトオフセット。
    private func byteForColumn(_ cr: Range<Int>, column: Int) -> Int {
        let s = lineString(cr)
        return byteOffset(lineStart: cr.lowerBound, lineString: s, utf16Index: column)
    }

    /// 行の「キャレット末尾」＝表示キャップ込みの内容末尾バイト。
    private func cappedEnd(_ cr: Range<Int>) -> Int { byteForColumn(cr, column: Int.max) }

    /// 目標バイトへキャレットを移動。`extend` で選択を伸ばし、`keepGoal` で上下移動の目標カラムを保つ。
    private func applyMove(to target: Int, extend: Bool, keepGoal: Bool = false) {
        caretByte = min(max(0, target), docByteCount)
        if !extend { selectionAnchor = caretByte }
        if !keepGoal { caretGoalColumn = nil }
        showCaretNow()
        scrollCaretIntoView()
        refresh()
    }

    /// キャレットのある行が可視範囲に入るよう `topLine` を寄せる。
    private func scrollCaretIntoView() {
        guard let pt = pieceTable else { return }
        let line = pt.line(ofByteOffset: caretByte)
        if line < topLine {
            topLine = line
        } else if line >= topLine + visibleLineCount {
            topLine = line - visibleLineCount + 1
        }
        topLine = min(max(0, topLine), maxTopLine)
    }

    private func moveHorizontal(forward: Bool, word: Bool, extend: Bool) {
        guard let pt = pieceTable else { return }
        let line = pt.line(ofByteOffset: caretByte)
        let cr = contentRange(ofLine: line)
        let target: Int
        if forward {
            if caretByte < cappedEnd(cr) {
                target = word ? wordBoundaryByte(cr, forward: true) : charByte(cr, forward: true)
            } else if line < lineCountDoc - 1 {
                target = pt.byteOffset(ofLineStart: line + 1)
            } else { target = caretByte }
        } else {
            if caretByte > cr.lowerBound {
                target = word ? wordBoundaryByte(cr, forward: false) : charByte(cr, forward: false)
            } else if line > 0 {
                target = cappedEnd(contentRange(ofLine: line - 1))
            } else { target = 0 }
        }
        applyMove(to: target, extend: extend)
    }

    /// 行内で 1 書記素分だけ進退したバイトオフセット。
    private func charByte(_ cr: Range<Int>, forward: Bool) -> Int {
        let s = lineString(cr)
        let ns = s as NSString
        let u = utf16Index(lineStart: cr.lowerBound, byteOffset: caretByte)
        if forward {
            guard u < ns.length else { return cappedEnd(cr) }
            let comp = ns.rangeOfComposedCharacterSequence(at: u)
            return byteOffset(lineStart: cr.lowerBound, lineString: s, utf16Index: comp.location + comp.length)
        } else {
            guard u > 0 else { return cr.lowerBound }
            let comp = ns.rangeOfComposedCharacterSequence(at: u - 1)
            return byteOffset(lineStart: cr.lowerBound, lineString: s, utf16Index: comp.location)
        }
    }

    /// 行内で次／前の単語境界へ動いたバイトオフセット。
    private func wordBoundaryByte(_ cr: Range<Int>, forward: Bool) -> Int {
        let s = lineString(cr)
        let ns = s as NSString
        var i = utf16Index(lineStart: cr.lowerBound, byteOffset: caretByte)
        if forward {
            while i < ns.length && !isWordChar(ns.character(at: i)) { i += 1 }
            while i < ns.length && isWordChar(ns.character(at: i)) { i += 1 }
        } else {
            while i > 0 && !isWordChar(ns.character(at: i - 1)) { i -= 1 }
            while i > 0 && isWordChar(ns.character(at: i - 1)) { i -= 1 }
        }
        return byteOffset(lineStart: cr.lowerBound, lineString: s, utf16Index: i)
    }

    private func isWordChar(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true } // サロゲート片は語の一部扱い
        return CharacterSet.alphanumerics.contains(scalar) || c == 0x5F // '_'
    }

    private func moveVertical(down: Bool, extend: Bool) {
        moveByLines(down ? 1 : -1, extend: extend)
    }

    private func moveByLines(_ delta: Int, extend: Bool) {
        guard let pt = pieceTable else { return }
        let line = pt.line(ofByteOffset: caretByte)
        let cr = contentRange(ofLine: line)
        let goal = caretGoalColumn ?? utf16Index(lineStart: cr.lowerBound, byteOffset: caretByte)
        caretGoalColumn = goal
        let target = min(max(0, line + delta), max(0, lineCountDoc - 1))
        if target == line {
            // 端の行では文書先頭／末尾へ寄せる。
            applyMove(to: delta > 0 ? cappedEnd(cr) : cr.lowerBound, extend: extend, keepGoal: true)
        } else {
            applyMove(to: byteForColumn(contentRange(ofLine: target), column: goal), extend: extend, keepGoal: true)
        }
    }

    private func moveToLineEdge(end: Bool, extend: Bool) {
        guard let pt = pieceTable else { return }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: caretByte))
        applyMove(to: end ? cappedEnd(cr) : cr.lowerBound, extend: extend)
    }

    private func selectAllText() {
        selectionAnchor = 0
        caretByte = docByteCount
        caretGoalColumn = nil
        showCaretNow()
        scrollCaretIntoView()
        refresh()
    }

    // MARK: - コピー

    /// 選択があればその範囲、なければ可視範囲をプレーンテキストでコピーする。
    private func copySelectionOrVisible() {
        let text: String
        if let sel = selectionRange {
            let capped = sel.lowerBound..<min(sel.upperBound, sel.lowerBound + 32 * 1024 * 1024)
            text = decodeString(rawBytes(in: capped))
        } else {
            text = documentView.lines.map { $0.string }.joined(separator: "\n")
        }
        guard !text.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - スクロール / キー入力（B1 はスクロールのみ）

    private func handleScrollWheel(_ event: NSEvent) {
        guard lineIndex != nil else { return }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= documentView.lineHeight }
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator / documentView.lineHeight)
        if lines != 0 {
            scrollAccumulator -= CGFloat(lines) * documentView.lineHeight
            setTopLine(topLine - lines)
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let page = max(1, visibleLineCount - 1)
        switch event.keyCode {
        case 125: setTopLine(topLine + 1)      // ↓
        case 126: setTopLine(topLine - 1)      // ↑
        case 121: setTopLine(topLine + page)   // Page Down
        case 116: setTopLine(topLine - page)   // Page Up
        case 115: setTopLine(0)                 // Home
        case 119: setTopLine(maxTopLine)       // End
        case 49:  setTopLine(topLine + page)   // Space
        default: break
        }
    }

    private func setTopLine(_ value: Int) {
        let clamped = min(max(0, value), maxTopLine)
        guard clamped != topLine else { return }
        topLine = clamped
        refresh()
    }

    private func updateScroller() {
        guard lineIndex != nil else { scroller.isEnabled = false; return }
        let total = displayCount, visible = visibleLineCount
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

    @objc private func scrollerAction(_ sender: NSScroller) {
        let page = max(1, visibleLineCount - 1)
        switch sender.hitPart {
        case .knob, .knobSlot: topLine = Int(Double(maxTopLine) * sender.doubleValue)
        case .decrementPage: topLine -= page
        case .incrementPage: topLine += page
        case .decrementLine: topLine -= 1
        case .incrementLine: topLine += 1
        default: break
        }
        topLine = min(max(0, topLine), maxTopLine)
        refresh()
    }

    // MARK: - ステータス

    private func emitState() {
        guard let idx = lineIndex, let buffer = fileBuffer else { return }
        let state = ViewerState(
            encodingName: encoding.displayName,
            lineCount: idx.displayLineCount,
            lineCountIsExact: idx.isComplete,
            fileSize: buffer.count,
            indexProgress: idx.isComplete ? 1.0 : 0.0
        )
        onStateChange?(state)
    }

    // MARK: - DocumentPane

    func reEmitState() { emitState() }
    func focusContent() { window?.makeFirstResponder(documentView) }

    /// 指定行（1 始まり）へスクロールする。
    func goToLine(_ line1Based: Int) {
        setTopLine(max(0, line1Based - 1))
        focusContent()
    }

    // MARK: - ドラッグ & ドロップ

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}

// MARK: - DocumentTextInputHandler（キー入力の受け口）

extension PieceTableViewer: DocumentTextInputHandler {
    /// `interpretKeyEvents` が解決した編集コマンドを処理する（B2a は移動・選択のみ）。
    func doCommand(_ selector: Selector) {
        guard pieceTable != nil else { return }

        // `...AndModifySelection:` を剥がして「選択を伸ばすか」を切り出す。
        var name = NSStringFromSelector(selector)
        var extend = false
        if name.hasSuffix("AndModifySelection:") {
            extend = true
            name = String(name.dropLast("AndModifySelection:".count)) + ":"
        }
        let page = max(1, visibleLineCount - 1)

        switch name {
        case "moveLeft:":  moveHorizontal(forward: false, word: false, extend: extend)
        case "moveRight:": moveHorizontal(forward: true,  word: false, extend: extend)
        case "moveWordLeft:", "moveWordBackward:":  moveHorizontal(forward: false, word: true, extend: extend)
        case "moveWordRight:", "moveWordForward:":  moveHorizontal(forward: true,  word: true, extend: extend)
        case "moveUp:":   moveVertical(down: false, extend: extend)
        case "moveDown:": moveVertical(down: true,  extend: extend)
        case "pageUp:":   moveByLines(-page, extend: extend)
        case "pageDown:": moveByLines(page,  extend: extend)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:", "moveToBeginningOfParagraph:":
            moveToLineEdge(end: false, extend: extend)
        case "moveToEndOfLine:", "moveToRightEndOfLine:", "moveToEndOfParagraph:":
            moveToLineEdge(end: true, extend: extend)
        case "moveToBeginningOfDocument:": applyMove(to: 0, extend: extend)
        case "moveToEndOfDocument:":       applyMove(to: docByteCount, extend: extend)
        case "selectAll:": selectAllText()
        // 純粋スクロール（キャレットは動かさない）。
        case "scrollPageUp:":   setTopLine(topLine - page)
        case "scrollPageDown:": setTopLine(topLine + page)
        case "scrollToBeginningOfDocument:": setTopLine(0)
        case "scrollToEndOfDocument:":       setTopLine(maxTopLine)
        // 変異系（insertNewline: / deleteBackward: など）は B2b。ここでは黙って無視。
        default: break
        }
    }

    /// 確定テキストの挿入は B2b で実装（B2a は読み取り専用）。
    func insertText(_ text: String) {}
}
