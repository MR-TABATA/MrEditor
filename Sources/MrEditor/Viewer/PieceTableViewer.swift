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

    /// IME 変換中文字列（B2c）。空＝変換なし。ドキュメント（PieceTable）には入れず、
    /// キャレット位置に下線付きで描画だけする。確定時に本挿入する。
    private var markedText = ""
    /// 変換中文字列内の選択／キャレット（marked 内 UTF-16）。
    private var markedSelection = NSRange(location: 0, length: 0)
    private var hasMarked: Bool { !markedText.isEmpty }

    /// 編集のアンドゥ／リドゥ（B2b）。1 編集＝1 アクションを逆操作として積む。
    private let undoMgr = UndoManager()
    /// アンドゥ用に控える旧バイトの上限。これを超える巨大編集はアンドゥ不可とし履歴を破棄（メモリ保護）。
    private let maxUndoBytes = 64 * 1024 * 1024

    var onStateChange: ((ViewerState) -> Void)?
    var onSearchState: ((Int, Int, Bool, Int, Bool) -> Void)?   // B1 では未使用
    var onDropFiles: (([URL]) -> Void)?

    // MARK: - 編集・保存状態（B3）

    /// 未保存の変更があるか。
    private(set) var isDirty = false
    /// 未保存状態の変化通知（タイトルバーの編集済みドット用）。
    var onDirtyChange: ((Bool) -> Void)?
    /// piece table バックのペインは編集ペイン（索引構築中は入力が無効なだけ）。
    var canEdit: Bool { true }
    /// 挿入時に検出エンコードで表現できずに UTF-8 へフォールバックしたか（保存時に一度警告）。
    private var didEncodingFallback = false

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
        documentView.onCut = { [weak self] in self?.cutSelection() }
        documentView.onPaste = { [weak self] in self?.pasteClipboard() }
        documentView.onSelectAll = { [weak self] in self?.selectAllText() }
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
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        didEncodingFallback = false
        setDirty(false)
        undoMgr.removeAllActions()   // 別ファイルの編集履歴を持ち越さない
        refresh()

        idx.buildInBackground(progress: { [weak self] p in
            self?.partialProgress = p
            self?.emitState()
        }, completion: { [weak self] in
            guard let self, let buffer = self.fileBuffer, self.lineIndex === idx else { return }
            // 完成索引から原本の改行数を渡し、init の原本全スキャンを省いて piece table を作る。
            self.pieceTable = PieceTable(original: FileBufferSource(buffer),
                                         originalNewlines: idx.originalNewlines,
                                         locator: idx)
            // piece table が揃ったら編集を有効化（それまでは読み取り専用でスクロールのみ）。
            self.documentView.inputHandler = self
            self.documentView.editUndoManager = self.undoMgr
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

        // IME 変換中はキャレット行に marked 文字列を下線付きで差し込み、選択は隠す。
        if hasMarked, let (row, col) = spliceMarkedText(into: &attributed) {
            documentView.lines = attributed
            documentView.caret = (row, col)
            documentView.selectionByRow = [:]
        } else {
            documentView.lines = attributed
            updateCaretAndSelectionViews()
        }
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

    // MARK: - 編集（変異・B2b）

    /// 文字列を検出エンコードのバイト列へ。表現不能なら UTF-8 へフォールバックし、保存時に警告する。
    private func encodeForInsertion(_ text: String) -> [UInt8] {
        if let d = text.data(using: encoding.stringEncoding) { return [UInt8](d) }
        didEncodingFallback = true
        return Array(text.utf8)
    }

    /// すべての変異の起点。`range` を `bytes` で置換し、キャレット／選択を更新、逆操作をアンドゥに積む。
    /// 逆操作もこの関数を通るため、アンドゥを実行すると自動的にリドゥ（さらにその逆）が積まれる。
    private func perform(replace range: Range<Int>, with bytes: [UInt8], newCaret: Int, newAnchor: Int) {
        guard let pt = pieceTable else { return }
        let lo = max(0, range.lowerBound), hi = min(pt.byteCount, range.upperBound)
        guard lo <= hi, !(lo == hi && bytes.isEmpty) else { return }

        let prevCaret = caretByte, prevAnchor = selectionAnchor
        // 巨大編集はアンドゥ用の退避でメモリを食うため、閾値超過は履歴を破棄して非可逆に。
        let undoable = (hi - lo) <= maxUndoBytes && bytes.count <= maxUndoBytes
        let old = undoable ? pt.bytes(in: lo..<hi) : []

        if hi > lo { pt.delete(lo..<hi) }
        if !bytes.isEmpty { pt.insert(bytes, at: lo) }

        if undoable {
            let inverse = lo..<(lo + bytes.count)
            undoMgr.registerUndo(withTarget: self) { target in
                target.perform(replace: inverse, with: old, newCaret: prevCaret, newAnchor: prevAnchor)
            }
        } else {
            undoMgr.removeAllActions()
        }

        caretByte = min(max(0, newCaret), pt.byteCount)
        selectionAnchor = min(max(0, newAnchor), pt.byteCount)
        caretGoalColumn = nil
        setDirty(true)
        showCaretNow()
        scrollCaretIntoView()
        refresh()
    }

    /// キャレット位置（選択があればその範囲）に `bytes` を挿入する。
    private func insertBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let range = selectionRange ?? caretByte..<caretByte
        let caret = range.lowerBound + bytes.count
        perform(replace: range, with: bytes, newCaret: caret, newAnchor: caret)
    }

    /// バイト範囲を削除する（キャレットは範囲先頭へ）。
    private func deleteRange(_ range: Range<Int>) {
        let lo = max(0, range.lowerBound), hi = min(docByteCount, range.upperBound)
        guard lo < hi else { return }
        perform(replace: lo..<hi, with: [], newCaret: lo, newAnchor: lo)
    }

    /// deleteBackward の削除範囲（行内は 1 書記素、行頭では直前の改行 CR?LF）。
    private func backwardDeleteRange() -> Range<Int>? {
        guard let pt = pieceTable, caretByte > 0 else { return nil }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: caretByte))
        if caretByte > cr.lowerBound {
            return charByte(cr, forward: false)..<caretByte
        }
        // 行頭 → 直前行末の改行を消して行結合（CRLF は 2 バイトまとめて）。
        var start = caretByte - 1
        if start > 0, pt.bytes(in: (start - 1)..<start).first == 0x0D { start -= 1 }
        return start..<caretByte
    }

    /// deleteForward の削除範囲（行内は 1 書記素、行末では次の改行 CR?LF）。
    private func forwardDeleteRange() -> Range<Int>? {
        guard let pt = pieceTable, caretByte < docByteCount else { return nil }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: caretByte))
        if caretByte < cr.upperBound {
            return caretByte..<charByte(cr, forward: true)
        }
        // 行末（内容末尾）→ 次行頭までの改行を消して行結合。
        let line = pt.line(ofByteOffset: caretByte)
        guard line < lineCountDoc - 1 else { return nil }
        return caretByte..<pt.byteOffset(ofLineStart: line + 1)
    }

    /// 単語単位の削除（選択があればそれを優先）。
    private func deleteWord(forward: Bool) {
        if let sel = selectionRange { deleteRange(sel); return }
        guard let pt = pieceTable else { return }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: caretByte))
        if forward {
            if caretByte < cr.upperBound { deleteRange(caretByte..<wordBoundaryByte(cr, forward: true)) }
            else if let r = forwardDeleteRange() { deleteRange(r) }
        } else {
            if caretByte > cr.lowerBound { deleteRange(wordBoundaryByte(cr, forward: false)..<caretByte) }
            else if let r = backwardDeleteRange() { deleteRange(r) }
        }
    }

    /// 行頭／行末までを削除する（Ctrl-U / Ctrl-K 相当）。
    private func deleteToLineEdge(end: Bool) {
        if let sel = selectionRange { deleteRange(sel); return }
        guard let pt = pieceTable else { return }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: caretByte))
        if end { deleteRange(caretByte..<cappedEnd(cr)) }
        else { deleteRange(cr.lowerBound..<caretByte) }
    }

    // MARK: - 切り取り / 貼り付け

    /// 選択を切り取る（コピー → 削除）。選択が無ければビープ。
    private func cutSelection() {
        guard pieceTable != nil, let sel = selectionRange else { NSSound.beep(); return }
        let capped = sel.lowerBound..<min(sel.upperBound, sel.lowerBound + 32 * 1024 * 1024)
        let text = decodeString(rawBytes(in: capped))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        deleteRange(sel)
    }

    /// クリップボードの文字列をキャレット位置（選択があれば置換）へ貼り付ける。
    private func pasteClipboard() {
        guard pieceTable != nil,
              let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { NSSound.beep(); return }
        insertBytes(encodeForInsertion(text))
    }

    // MARK: - 保存（B3・ストリーム書き出し → atomic 差し替え）

    private func setDirty(_ value: Bool) {
        guard value != isDirty else { return }
        isDirty = value
        onDirtyChange?(value)
    }

    /// 既存パスへ保存（パス未確定なら Save As）。成功で true。
    @discardableResult
    func save() -> Bool {
        guard pieceTable != nil else { NSSound.beep(); return false }
        guard let url = fileURL else { return saveAs() }
        return write(to: url)
    }

    /// 保存先を選んで保存（NSSavePanel）。成功で true。
    @discardableResult
    func saveAs() -> Bool {
        guard pieceTable != nil else { NSSound.beep(); return false }
        let panel = NSSavePanel()
        if let url = fileURL {
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    /// piece table の全内容を一時ファイルへストリーム書き出しし、原子的に `url` へ差し替える。
    /// 全文をメモリに載せない。原本の mmap は差し替え後も生き続ける（読み出しは正しいまま）。
    private func write(to url: URL) -> Bool {
        guard let pt = pieceTable else { NSSound.beep(); return false }
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".mreditor-save-\(UUID().uuidString)")

        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            NSSound.beep(); return false
        }
        do {
            try pt.writeAll { slice in try handle.write(contentsOf: Data(slice)) }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            NSAlert(error: error).runModal()
            return false
        }
        // 原子的差し替え（同一ボリューム上の rename 相当）。既存があれば置換、無ければ移動。
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            NSAlert(error: error).runModal()
            return false
        }

        fileURL = url
        setDirty(false)
        if didEncodingFallback {
            let a = NSAlert()
            a.messageText = L("save.encodingFallback", encoding.displayName)
            a.runModal()
            didEncodingFallback = false
        }
        emitState()
        return true
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

    /// 全索引途中の進捗（buildInBackground から更新）。ステータスバーの「索引中 N%」に使う。
    private var partialProgress: Double = 0

    private func emitState() {
        guard let idx = lineIndex, let buffer = fileBuffer else { return }
        // piece table 完成後は編集で LineIndex が陳腐化するため、行数・サイズは piece table を真とする。
        let state = ViewerState(
            encodingName: encoding.displayName,
            lineCount: pieceTable?.lineCount ?? idx.displayLineCount,
            lineCountIsExact: pieceTable != nil || idx.isComplete,
            fileSize: pieceTable?.byteCount ?? buffer.count,
            indexProgress: idx.isComplete ? 1.0 : partialProgress
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

#if DEBUG
// MARK: - テスト用シーム（B2b の編集パイプラインをヘッドレスに駆動する）

/// GUI を立てずに `insertText` / `doCommand` / アンドゥ / 切り取り・貼り付けを document 単位で検証するための入口。
extension PieceTableViewer {
    /// インメモリ原本で piece table を用意し、編集を有効化する（ファイル open の非同期経路を迂回）。
    func _testLoad(_ bytes: [UInt8], encoding: DetectedEncoding = .utf8) {
        self.encoding = encoding
        self.pieceTable = PieceTable(bytes: bytes)
        self.caretByte = 0
        self.selectionAnchor = 0
        self.caretGoalColumn = nil
        self.undoMgr.removeAllActions()
    }

    var _testDocBytes: [UInt8] {
        guard let pt = pieceTable else { return [] }
        return pt.bytes(in: 0..<pt.byteCount)
    }
    var _testDocString: String { decodeString(_testDocBytes) }
    var _testCaret: Int { caretByte }
    var _testLineCount: Int { pieceTable?.lineCount ?? 0 }

    func _testSetCaret(_ b: Int) { caretByte = b; selectionAnchor = b; caretGoalColumn = nil }
    func _testSelect(_ r: Range<Int>) { selectionAnchor = r.lowerBound; caretByte = r.upperBound }
    func _testInsert(_ s: String) { insertText(s) }
    func _testCommand(_ selector: String) { doCommand(Selector(selector)) }
    func _testCut() { cutSelection() }
    func _testPaste() { pasteClipboard() }
    func _testUndo() { undoMgr.undo() }
    func _testRedo() { undoMgr.redo() }

    // 保存（B3）
    var _testIsDirty: Bool { isDirty }
    @discardableResult func _testWrite(to url: URL) -> Bool { write(to: url) }

    // IME（B2c）
    var _testHasMarked: Bool { hasMarked }
    var _testMarkedText: String { markedText }
    func _testSetMarked(_ s: String, sel: NSRange) {
        setMarkedText(s, selectedRange: sel, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func _testUnmark() { unmarkText() }
}
#endif

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
        // --- 変異系（B2b）---
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:":
            insertBytes([0x0A])
        case "insertTab:": insertBytes([0x09])
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:":
            if let sel = selectionRange { deleteRange(sel) }
            else if let r = backwardDeleteRange() { deleteRange(r) }
        case "deleteForward:":
            if let sel = selectionRange { deleteRange(sel) }
            else if let r = forwardDeleteRange() { deleteRange(r) }
        case "deleteWordBackward:": deleteWord(forward: false)
        case "deleteWordForward:":  deleteWord(forward: true)
        case "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:": deleteToLineEdge(end: false)
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:":             deleteToLineEdge(end: true)
        case "insertBacktab:", "insertTabIgnoringFieldEditor:": break
        default: break
        }
    }

    /// 確定テキスト（通常入力・IME 確定・ペースト経由の一部）をキャレット位置へ挿入する（B2b）。
    /// 変換中だった場合は marked を破棄し、確定文字列を本挿入する（B2c）。
    func insertText(_ text: String) {
        guard pieceTable != nil else { return }
        let wasMarked = hasMarked
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        if !text.isEmpty {
            insertBytes(encodeForInsertion(text))   // perform() 内で refresh
        } else if wasMarked {
            refresh()                               // 空確定（変換キャンセル）→ 下線を消す
        }
    }

    // MARK: - IME（marked text / 変換中・B2c）

    func setMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange) {
        guard pieceTable != nil else { return }
        // 変換開始時（まだ marked が無い）に選択があれば、その選択を削除してそこに合成する。
        if !hasMarked, let sel = selectionRange { deleteRange(sel) }
        markedText = text
        let n = (text as NSString).length
        let loc = min(max(0, selectedRange.location), n)
        markedSelection = NSRange(location: loc, length: min(selectedRange.length, n - loc))
        caretGoalColumn = nil
        showCaretNow()
        refresh()
    }

    func unmarkText() {
        guard pieceTable != nil else { return }
        let t = markedText
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        if !t.isEmpty { insertBytes(encodeForInsertion(t)) } else { refresh() }
    }

    func hasMarkedText() -> Bool { hasMarked }

    func markedRange() -> NSRange {
        hasMarked ? NSRange(location: 0, length: (markedText as NSString).length)
                  : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        hasMarked ? markedSelection : NSRange(location: 0, length: 0)
    }

    /// キャレット行の可視表示に marked 文字列を下線付きで差し込み、marked 内キャレット位置 (row, col) を返す。
    /// ドキュメントは変更しない（描画のみ）。marked に改行は無い前提（日本語変換は単一行）。
    private func spliceMarkedText(into lines: inout [NSAttributedString]) -> (row: Int, col: Int)? {
        guard hasMarked,
              let row = visibleRanges.firstIndex(where: { caretByte >= $0.lowerBound && caretByte <= $0.upperBound }),
              row < lines.count else { return nil }
        let col = utf16Index(lineStart: visibleRanges[row].lowerBound, byteOffset: caretByte)
        let m = NSMutableAttributedString(attributedString: lines[row])
        let clampedCol = min(col, m.length)
        var attrs = documentView.textAttributes
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        m.insert(NSAttributedString(string: markedText, attributes: attrs), at: clampedCol)
        lines[row] = m
        let caretCol = clampedCol + min(markedSelection.location, (markedText as NSString).length)
        return (row, caretCol)
    }
}
