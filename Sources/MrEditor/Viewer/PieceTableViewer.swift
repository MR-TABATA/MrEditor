import AppKit

/// 巨大ファイルの表示・編集・保存・検索・追従をすべて担う自前ビューア（1.0 の大ファイル既定）。
///
/// 「固定サイズ `DocumentView` ＋自前 `NSScroller`（行単位）」で任意サイズへスケールさせる。
/// 原本は `FileBuffer`（mmap）に `PieceTable` を被せ、可視行だけをその場でデコードして描く。
///
/// - 未編集（クリーン）: 表示・検索（`SearchEngine`）・追従（tail -f）を LineIndex+mmap で行う。
/// - 編集後（dirty）: piece table を真として表示し、検索・追従は一時停止（mmap と乖離するため）。
///   保存は全文をストリーム書き出し → atomic 差し替え（非同期・進捗表示）。
final class PieceTableViewer: NSView, DocumentPane {
    private let documentView = DocumentView()
    private let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))

    private var fileBuffer: FileBuffer?
    private var lineIndex: LineIndex?
    /// 原本に被せた piece table（B2 以降の編集の土台。完成索引から改行数を渡して生成）。
    private var pieceTable: PieceTable?
    /// バッファ（piece table のバイト列）のエンコード。表示・挿入・検索に使う。
    private var encoding: DetectedEncoding = .utf8
    /// 保存時に書き出すエンコード。既定はバッファと同じ。ユーザーが変えると `encoding` と乖離し、
    /// 次回保存で S(=encoding)→T(=saveEncoding) 変換書き出し＋そのエンコードで開き直して再一致させる。
    private var saveEncoding: DetectedEncoding = .utf8
    /// ファイルの改行コード。挿入・貼り付けする改行はこれに揃える（読み込み時に検出。既定 LF）。
    private var lineEnding: LineEnding = .lf
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
    /// 非同期保存の実行中か（この間は編集を一時停止。スクロール・閲覧は可）。
    private var isSaving = false
    /// 実行中の保存のキャンセル用トークン（背景スレッドが各チャンクで参照）。
    private var saveToken: CancelToken?
    /// 未保存状態の変化通知（タイトルバーの編集済みドット用）。
    var onDirtyChange: ((Bool) -> Void)?
    /// piece table バックのペインは編集ペイン（索引構築中は入力が無効なだけ）。
    var canEdit: Bool { true }
    /// 挿入時に検出エンコードで表現できずに UTF-8 へフォールバックしたか（保存時に一度警告）。
    private var didEncodingFallback = false
    /// すべて置換の一括適用中（perform ごとの refresh/スクロールを抑止し、末尾で1回だけ再描画）。
    private var batchEditing = false
    /// 置換操作中は編集で検索パターンを消さない（反復置換で次の一致を探し続けるため）。
    private var preserveSearchOnEdit = false

    // 検索・追従（B4）: 未保存の編集がある間は無効（mmap と文書が乖離するため）。
    var supportsSearch: Bool { searchEngine != nil && !isDirty }
    var supportsFollow: Bool { fileBuffer != nil && !isDirty }

    /// クリーン（未編集）の間は表示・検索・追従を LineIndex+mmap で行う（原本＝piece table 内容）。
    /// 編集して dirty になると piece table を真として表示し、検索・追従は止める。
    private var readsFromOriginal: Bool { !isDirty }

    // MARK: - 検索状態（B4・LargeFileViewer から移植。クリーン時のみ有効）
    private var searchQuery = ""
    private var searchTerms: [String] = []
    private var regexMode = false
    private var searchRegex: NSRegularExpression?
    private var caseSensitive = false
    private var filterMode = false
    private var matchHighlight = EditorTheme.current().searchMatch
    private var searchEngine: SearchEngine?
    private var searchResults = SearchEngine.Result()
    private var currentMatchIdx = -1
    private var currentMatchLine = -1
    private var searchDebounce: DispatchWorkItem?
    private var searchEpoch = 0

    /// tail -f（末尾追従）。クリーン時のみ。
    private var followMode = false
    private var followTimer: Timer?

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
        documentView.configure(font: EditorFont.current())
        documentView.wrapEnabled = AppSettings.lineWrap
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
        documentView.configure(font: EditorFont.current())
        layoutSubviewsManually()
        refresh()
    }

    /// 折り返し設定を反映する（config 変更・ドキュメント切替時）。
    func applyLineWrap() {
        documentView.wrapEnabled = AppSettings.lineWrap
        if documentView.wrapEnabled { documentView.setHorizontalOffset(0) }
        refresh()
    }

    /// 表示設定（タブ幅・行間・現在行ハイライト・カーソル形状）を反映する。
    func applyDisplaySettings() {
        documentView.highlightCurrentLine = AppSettings.highlightCurrentLine
        documentView.cursorShape = AppSettings.cursorShape
        matchHighlight = EditorTheme.current().searchMatch
        // タブ幅・行間・配色は configure(font:) が段落スタイル・行高・色へ織り込む。
        documentView.configure(font: EditorFont.current())
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

    /// 表示空間の総行数。フィルタ表示＝一致行数、クリーン＝LineIndex、編集後＝piece table。
    private var displayCount: Int {
        if filterMode { return searchResults.lines.count }
        if readsFromOriginal { return lineIndex?.displayLineCount ?? pieceTable?.lineCount ?? 0 }
        return pieceTable?.lineCount ?? 0
    }
    private var maxTopLine: Int { max(0, displayCount - visibleLineCount) }

    // MARK: - ファイルを開く

    @discardableResult
    func open(url: URL) -> Bool { open(url: url, forcedEncoding: nil) }

    /// バッファ（表示・再デコード）のエンコード。「開き直す」メニューのチェック表示に使う。
    var currentEncoding: DetectedEncoding { encoding }
    /// 保存時に書き出すエンコード。「テキストエンコーディング」メニューのチェック表示に使う。
    var currentSaveEncoding: DetectedEncoding { saveEncoding }

    /// 保存時のエンコードを設定する（まだ書き出さない。dirty にして次の保存で変換する）。
    func setSaveEncoding(_ enc: DetectedEncoding) {
        guard enc != saveEncoding else { return }
        saveEncoding = enc
        setDirty(true)          // 保存すべき変更（＝出力エンコードの変更）が生じた
        emitState()             // ステータスバーの表示エンコードを更新
    }

    /// 現在のファイルを指定エンコードで開き直す（自動判定ミスの文字化けを直す）。編集は破棄される。
    @discardableResult
    func reopen(withEncoding enc: DetectedEncoding) -> Bool {
        guard let url = fileURL else { return false }
        return open(url: url, forcedEncoding: enc)
    }

    /// `forcedEncoding` を渡すと自動判定を上書きしてそのエンコードで開く（エンコード指定再オープン）。
    @discardableResult
    func open(url: URL, forcedEncoding: DetectedEncoding?) -> Bool {
        guard let buffer = FileBuffer(url: url) else { NSSound.beep(); return false }
        self.fileBuffer = buffer
        self.fileURL = url
        self.pieceTable = nil

        let prefix = buffer.data(in: 0..<min(buffer.count, 64 * 1024))
        self.encoding = forcedEncoding ?? EncodingDetector.detect(prefix)
        self.saveEncoding = encoding        // 開いた直後は保存先＝バッファのエンコード
        self.lineEnding = LineEnding.detect(prefix, encoding: encoding)
        self.searchEngine = SearchEngine(buffer: buffer, encoding: encoding)
        clearSearchState()

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
        var attributed: [NSAttributedString] = []

        if filterMode {
            // 一致行だけを表示（非連続・クリーン時のみ）。キャレット編集は使わない。
            let matches = searchResults.lines
            var numbers: [Int] = []
            var k = 0
            while k < needed, topLine + k < matches.count {
                let fl = matches[topLine + k]
                let range = lineIndex?.lineRanges(from: fl, count: 1).first ?? (0..<0)
                attributed.append(decodeLine(range))
                numbers.append(fl)
                k += 1
            }
            visibleRanges = []
            documentView.lineNumbers = numbers
            documentView.activeRow = nil
            documentView.lines = attributed
            documentView.caret = nil
            documentView.selectionByRow = [:]
        } else {
            let ranges = lineRanges(from: topLine, count: needed)
            visibleRanges = ranges
            attributed.reserveCapacity(ranges.count)
            for r in ranges { attributed.append(decodeLine(r)) }
            documentView.lineNumbers = nil
            documentView.firstLineNumber = topLine
            // 検索でジャンプした一致行を帯で強調。
            let visMatch = currentMatchIdx >= 0 && currentMatchLine >= topLine
                && currentMatchLine < topLine + attributed.count
            documentView.activeRow = visMatch ? currentMatchLine - topLine : nil

            // IME 変換中はキャレット行に marked 文字列を下線付きで差し込み、選択は隠す。
            if hasMarked, let (row, col) = spliceMarkedText(into: &attributed) {
                documentView.lines = attributed
                documentView.caret = (row, col)
                documentView.selectionByRow = [:]
            } else {
                documentView.lines = attributed
                updateCaretAndSelectionViews()
            }
        }
        documentView.needsDisplay = true

        updateScroller()
        emitState()
        if filterMode {
            emitSearchState(searching: !searchResults.isComplete,
                            progress: searchResults.isComplete ? 100 : 0, invalid: false)
        }
    }

    /// 可視行のバイト範囲を求める。クリーン時は LineIndex（追従で伸びる）、編集後は piece table（CR 込み）。
    private func lineRanges(from start: Int, count: Int) -> [Range<Int>] {
        if readsFromOriginal, let idx = lineIndex {
            return idx.lineRanges(from: start, count: count)
        }
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
        let attr = NSMutableAttributedString(string: str, attributes: documentView.textAttributes)
        if !searchTerms.isEmpty || searchRegex != nil { highlightMatches(in: attr, text: str) }
        return attr
    }

    /// 行内の一致箇所に背景色を付ける（可視行のみ・グローバル索引不要）。
    private func highlightMatches(in attr: NSMutableAttributedString, text: String) {
        for r in matchRanges(in: text) { attr.addAttribute(.backgroundColor, value: matchHighlight, range: r) }
    }

    /// 行文字列内の一致（UTF-16 レンジ）を返す。ハイライトと置換で共有。
    private func matchRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        if let rx = searchRegex {
            rx.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let r = m?.range, r.length > 0 { out.append(r) }
            }
        } else {
            let opts: NSString.CompareOptions = caseSensitive ? [] : .caseInsensitive
            for term in searchTerms where !term.isEmpty {
                var from = 0
                while from <= ns.length {
                    let r = ns.range(of: term, options: opts, range: NSRange(location: from, length: ns.length - from))
                    if r.location == NSNotFound { break }
                    out.append(r)
                    from = r.location + max(1, r.length)
                }
            }
            out.sort { $0.location < $1.location }
        }
        return out
    }

    /// 行内の (一致レンジ, 置換後文字列) を返す。literal は replacement そのまま、regex は $1 展開。
    private func matchReplacements(in text: String, with replacement: String) -> [(NSRange, String)] {
        if let rx = searchRegex {
            let ns = text as NSString
            var out: [(NSRange, String)] = []
            for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                out.append((m.range, rx.replacementString(for: m, in: text, offset: 0, template: replacement)))
            }
            return out
        }
        return matchRanges(in: text).map { ($0, replacement) }
    }

    /// 文書のバイト範囲を取り出す。クリーン時は mmap 直読み、編集後は piece table 経由。
    private func rawBytes(in range: Range<Int>) -> [UInt8] {
        guard range.lowerBound < range.upperBound else { return [] }
        if !readsFromOriginal, let pt = pieceTable { return pt.bytes(in: range) }
        if let buffer = fileBuffer { return [UInt8](buffer.data(in: range)) }
        return pieceTable?.bytes(in: range) ?? []
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
        documentView.ensureCaretVisibleHorizontally()
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
        switch e.clickCount {
        case 2: selectWord(at: b)      // ダブルクリック＝単語選択
        case 3: selectLine(at: b)      // トリプルクリック＝行選択
        default:
            // Shift+クリック＝既存アンカーからクリック位置まで選択を拡張。
            placeCaret(at: b, extend: e.modifierFlags.contains(.shift))
        }
    }

    /// 単一クリック相当。キャレットを `byte` へ。`extend` なら既存アンカーから選択を拡張する。
    private func placeCaret(at byte: Int, extend: Bool) {
        caretByte = byte
        if !extend { selectionAnchor = byte }
        caretGoalColumn = nil
        showCaretNow()
        refresh()
    }

    /// バイト `byte` を含む単語を選択する（語文字の連なり。語上でなければキャレットのみ）。
    private func selectWord(at byte: Int) {
        guard let pt = pieceTable else { return }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: byte))
        let str = lineString(cr)
        let ns = str as NSString
        let u = min(utf16Index(lineStart: cr.lowerBound, byteOffset: byte), ns.length)
        var lo = u, hi = u
        if u < ns.length && isWordChar(ns.character(at: u)) {
            while lo > 0 && isWordChar(ns.character(at: lo - 1)) { lo -= 1 }
            while hi < ns.length && isWordChar(ns.character(at: hi)) { hi += 1 }
        } else if u > 0 && isWordChar(ns.character(at: u - 1)) {   // 語の直後をクリック
            while lo > 0 && isWordChar(ns.character(at: lo - 1)) { lo -= 1 }
        } else {                                                   // 語の上でない
            caretByte = byte; selectionAnchor = byte; caretGoalColumn = nil
            showCaretNow(); refresh(); return
        }
        selectionAnchor = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: lo)
        caretByte = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: hi)
        caretGoalColumn = nil
        showCaretNow(); refresh()
    }

    /// バイト `byte` の論理行全体を選択する（行頭〜次行頭。改行を含む）。
    private func selectLine(at byte: Int) {
        guard let pt = pieceTable else { return }
        let line = pt.line(ofByteOffset: byte)
        selectionAnchor = pt.byteOffset(ofLineStart: line)
        caretByte = line < lineCountDoc - 1 ? pt.byteOffset(ofLineStart: line + 1) : docByteCount
        caretGoalColumn = nil
        showCaretNow(); refresh()
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
    /// 貼り付け等で混在した改行（\r\n / \r / \n）はファイルの EOL に揃えてから符号化する。
    private func encodeForInsertion(_ text: String) -> [UInt8] {
        let normalized = lineEnding.normalize(text)
        if let d = normalized.data(using: encoding.stringEncoding) { return [UInt8](d) }
        didEncodingFallback = true
        return Array(normalized.utf8)
    }

    /// すべての変異の起点。`range` を `bytes` で置換し、キャレット／選択を更新、逆操作をアンドゥに積む。
    /// 逆操作もこの関数を通るため、アンドゥを実行すると自動的にリドゥ（さらにその逆）が積まれる。
    private func perform(replace range: Range<Int>, with bytes: [UInt8], newCaret: Int, newAnchor: Int) {
        guard let pt = pieceTable, !isSaving else { return }   // 保存中は変異させない（背景で全文を読んでいる）
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
        let wasClean = !isDirty
        setDirty(true)
        if wasClean && !preserveSearchOnEdit { stopSearchAndFollowForEdit() }   // 検索・追従は編集で無効化
        showCaretNow()
        if batchEditing { return }   // 一括置換中は末尾でまとめて再描画
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

    /// 非同期保存（もっさり回避）。書き出しは背景キューで行い、進捗を main に報告、
    /// 完了で main で atomic 差し替え＋UI 更新。保存中は編集を一時停止（スクロール・閲覧は可）。
    /// `saveAs=true`（または未保存）は先に保存先パネルを出す。`onBegin` は書き出し開始時に呼ぶ。
    /// 保存先エンコード（`saveEncoding`）がバッファ（`encoding`）と異なれば書き出し時に変換し、
    /// 成功後はそのエンコードで開き直して整合させる（エンコード変換保存）。
    func saveAsync(saveAs: Bool,
                   onBegin: @escaping () -> Void,
                   progress: @escaping (Double) -> Void,
                   completion: @escaping (Bool) -> Void) {
        guard let pt = pieceTable, !isSaving else { completion(false); return }
        let url: URL
        if saveAs || fileURL == nil {
            let panel = NSSavePanel()
            if let u = fileURL {
                panel.directoryURL = u.deletingLastPathComponent()
                panel.nameFieldStringValue = u.lastPathComponent
            }
            guard panel.runModal() == .OK, let u = panel.url else { completion(false); return }
            url = u
        } else {
            url = fileURL!
        }

        isSaving = true
        let token = CancelToken()
        saveToken = token
        onBegin()
        let total = max(1, pt.byteCount)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".mreditor-save-\(UUID().uuidString)")
        // 変換保存の元／先エンコード（同じなら通常の生バイト書き出し）。
        let source = self.encoding
        let target: DetectedEncoding? = (saveEncoding != source) ? saveEncoding : nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var writeErrno: Int32 = 0
            var cancelled = false
            var encFallback = false
            var wrote = 0, lastReport = 0
            if FileManager.default.createFile(atPath: tmp.path, contents: nil),
               let handle = try? FileHandle(forWritingTo: tmp) {
                do {
                    let reportProgress = {
                        if wrote - lastReport >= (128 << 20) {          // 128MB ごとに進捗報告
                            lastReport = wrote
                            let f = Double(wrote) / Double(total)
                            DispatchQueue.main.async { progress(f) }
                        }
                    }
                    if let target {
                        encFallback = try EncodingTranscoder.stream(
                            from: source, to: target,
                            feed: { sink in
                                try pt.writeAll { slice in
                                    if token.isCancelled { throw CancelToken.Cancelled() }
                                    try sink(slice)
                                    wrote += slice.count
                                    reportProgress()
                                }
                            },
                            emit: { try handle.write(contentsOf: $0) })
                    } else {
                        try pt.writeAll { slice in
                            if token.isCancelled { throw CancelToken.Cancelled() }
                            try handle.write(contentsOf: Data(slice))
                            wrote += slice.count
                            reportProgress()
                        }
                    }
                    try handle.close()
                } catch is CancelToken.Cancelled {
                    cancelled = true
                    try? handle.close()
                } catch {
                    writeErrno = Int32((error as NSError).code); if writeErrno == 0 { writeErrno = EIO }
                    try? handle.close()
                }
            } else {
                writeErrno = EIO
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isSaving = false
                self.saveToken = nil
                if cancelled {                                  // ユーザー中断: 一時ファイルを捨て、dirty のまま
                    try? FileManager.default.removeItem(at: tmp)
                    completion(false); return
                }
                guard writeErrno == 0 else {
                    try? FileManager.default.removeItem(at: tmp)
                    NSAlert(error: NSError(domain: NSPOSIXErrorDomain, code: Int(writeErrno))).runModal()
                    completion(false); return
                }
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                    } else {
                        try FileManager.default.moveItem(at: tmp, to: url)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    NSAlert(error: error).runModal()
                    completion(false); return
                }
                self.fileURL = url
                if let target {
                    // 変換保存: 書き出し済みの新エンコードで開き直し、メモリ＝ディスクを一致させる。
                    if encFallback {
                        let a = NSAlert()
                        a.messageText = L("convert.lossy", target.displayName)
                        a.runModal()
                    }
                    self.open(url: url, forcedEncoding: target)
                    completion(true); return
                }
                self.setDirty(false)
                if self.didEncodingFallback {
                    let a = NSAlert()
                    a.messageText = L("save.encodingFallback", self.encoding.displayName)
                    a.runModal()
                    self.didEncodingFallback = false
                }
                self.emitState()
                completion(true)
            }
        }
    }

    /// 実行中の非同期保存を中断する（背景の書き出しを止め、一時ファイルを破棄。dirty は維持）。
    func cancelSave() { saveToken?.cancel() }

    /// 保存キャンセル用の小さなスレッドセーフ・フラグ。
    private final class CancelToken {
        struct Cancelled: Error {}
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
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
        // 折り返し無しのときは水平スクロールも扱う（トラックパッド横スワイプ）。
        if !documentView.wrapEnabled, event.scrollingDeltaX != 0 {
            documentView.setHorizontalOffset(documentView.horizontalOffset - event.scrollingDeltaX)
        }
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

    // MARK: - 検索（B4・クリーン時のみ有効。SearchEngine で mmap を走査）

    func setSearchQuery(_ q: String) { guard readsFromOriginal, q != searchQuery else { return }; searchQuery = q; rebuildSearch() }
    func setRegexMode(_ on: Bool) { guard readsFromOriginal, on != regexMode else { return }; regexMode = on; rebuildSearch() }
    func setCaseSensitive(_ on: Bool) { guard readsFromOriginal, on != caseSensitive else { return }; caseSensitive = on; rebuildSearch() }

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
                do { searchRegex = try NSRegularExpression(pattern: searchQuery, options: opts) } catch { invalid = true }
            }
        } else {
            searchTerms = searchQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        refresh()
        if searchQuery.isEmpty {
            searchResults = .init(); emitSearchState(searching: false, progress: 0, invalid: false); return
        }
        if invalid {
            searchResults = .init(); emitSearchState(searching: false, progress: 0, invalid: true); return
        }
        let mode: SearchMode = regexMode ? .regex(searchRegex!) : .terms(searchTerms)
        emitSearchState(searching: true, progress: 0, invalid: false)
        let work = DispatchWorkItem { [weak self] in self?.runSearch(mode, epoch: epoch) }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func runSearch(_ mode: SearchMode, epoch: Int) {
        searchEngine?.search(mode, caseSensitive: caseSensitive, progress: { [weak self] res, p in
            guard let self, self.searchEpoch == epoch else { return }
            self.searchResults = res
            if self.filterMode { self.refresh() }
            else { self.emitSearchState(searching: true, progress: Int(p * 100), invalid: false) }
        }, completion: { [weak self] res in
            guard let self, self.searchEpoch == epoch else { return }
            self.searchResults = res
            if self.filterMode { self.refresh() }
            else { self.emitSearchState(searching: false, progress: 100, invalid: false) }
        })
    }

    private func clearSearchState() {
        searchQuery = ""; searchTerms = []; searchRegex = nil
        filterMode = false; searchResults = .init()
        currentMatchIdx = -1; currentMatchLine = -1
        searchEpoch += 1
        searchDebounce?.cancel()
        searchEngine?.cancel()
    }

    func setFilterMode(_ on: Bool) {
        guard on != filterMode else { return }
        let matches = searchResults.lines
        if on {
            filterMode = true
            topLine = max(0, currentMatchIdx)
        } else {
            let fileLine = (topLine >= 0 && topLine < matches.count) ? matches[topLine] : topLine
            filterMode = false
            topLine = fileLine
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

    private func firstMatchIndex(after line: Int) -> Int {
        let lines = searchResults.lines
        var lo = 0, hi = lines.count
        while lo < hi { let mid = (lo + hi) / 2; if lines[mid] > line { hi = mid } else { lo = mid + 1 } }
        return lo
    }

    func findNext() {
        if filterMode { guard !searchResults.lines.isEmpty else { NSSound.beep(); return }; setTopLine(topLine + 1); return }
        let lines = searchResults.lines
        guard !lines.isEmpty else { NSSound.beep(); return }
        let idx = currentMatchIdx >= 0 ? (currentMatchIdx + 1) % lines.count
                                       : min(firstMatchIndex(after: topLine - 1), lines.count - 1)
        jumpToMatch(idx)
    }

    func findPrev() {
        if filterMode { guard !searchResults.lines.isEmpty else { NSSound.beep(); return }; setTopLine(topLine - 1); return }
        let lines = searchResults.lines
        guard !lines.isEmpty else { NSSound.beep(); return }
        let idx = currentMatchIdx >= 0 ? (currentMatchIdx - 1 + lines.count) % lines.count
                                       : (firstMatchIndex(after: topLine - 1) - 1 + lines.count) % lines.count
        jumpToMatch(idx)
    }

    private func jumpToMatch(_ idx: Int) {
        currentMatchIdx = idx
        currentMatchLine = searchResults.lines[idx]
        setTopLine(searchResults.lines[idx])
        emitSearchState(searching: !searchResults.isComplete,
                        progress: searchResults.isComplete ? 100 : 0, invalid: false)
    }

    /// 編集で dirty になったら検索・追従・フィルタを止める（mmap と文書が乖離するため）。
    private func stopSearchAndFollowForEdit() {
        if followMode { setFollowMode(false) }
        if !searchQuery.isEmpty || filterMode {
            clearSearchState()
            emitSearchState(searching: false, progress: 0, invalid: false)
        }
    }

    // MARK: - 置換（Find & Replace・B5）

    /// 現在の検索パターン（`searchTerms`/`searchRegex`）にマッチした一致を全部 `replacement` に置換。
    /// クリーン時の検索結果（一致行）を使い、各行の一致を求めて END→START に一括適用（1 アンドゥ）。
    func replaceAll(with replacement: String) {
        guard let pt = pieceTable, !isSaving, !searchQuery.isEmpty else { NSSound.beep(); return }
        let lines = searchResults.lines
        guard !lines.isEmpty else { NSSound.beep(); return }   // 一致なし

        // 各一致行の (文書バイトレンジ, 置換バイト列) を集める。
        var edits: [(Range<Int>, [UInt8])] = []
        for fl in lines where fl < pt.lineCount {
            let cr = contentRange(ofLine: fl)
            let str = lineString(cr)
            for (r, rep) in matchReplacements(in: str, with: replacement) {
                let bs = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: r.location)
                let be = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: r.location + r.length)
                if bs < be { edits.append((bs..<be, encodeForInsertion(rep))) }
            }
        }
        guard !edits.isEmpty else { NSSound.beep(); return }

        // 後方から適用すれば前方のオフセットは不変。全体を1つのアンドゥにまとめる。
        edits.sort { $0.0.lowerBound > $1.0.lowerBound }
        let count = edits.count
        undoMgr.beginUndoGrouping()
        batchEditing = true
        preserveSearchOnEdit = true
        for (range, bytes) in edits {
            perform(replace: range, with: bytes, newCaret: range.lowerBound + bytes.count, newAnchor: range.lowerBound + bytes.count)
        }
        preserveSearchOnEdit = false
        batchEditing = false
        undoMgr.endUndoGrouping()

        selectionAnchor = caretByte
        scrollCaretIntoView()
        refresh()
        onSearchState?(count, count, false, 100, false)   // 「N 件置換」相当のフィードバック
    }

    /// 現在の選択が一致ならそれを置換して次へ、一致でなければ次の一致を選択する（反復置換）。
    func replaceCurrent(with replacement: String) {
        guard pieceTable != nil, !isSaving, !searchQuery.isEmpty else { NSSound.beep(); return }
        if let sel = selectionRange, let rep = replacementForSelection(sel, replacement) {
            let bytes = encodeForInsertion(rep)
            preserveSearchOnEdit = true
            perform(replace: sel, with: bytes,
                    newCaret: sel.lowerBound + bytes.count, newAnchor: sel.lowerBound + bytes.count)
            preserveSearchOnEdit = false
            _ = selectNextMatch(from: caretByte)
        } else {
            if !selectNextMatch(from: caretByte) { NSSound.beep() }
        }
    }

    /// 選択テキストが検索パターンに一致すれば置換後文字列を返す（literal はそのまま/regex は $1 展開）。無一致は nil。
    private func replacementForSelection(_ sel: Range<Int>, _ replacement: String) -> String? {
        let str = decodeString(rawBytes(in: sel))
        let ns = str as NSString
        if let rx = searchRegex {
            guard let m = rx.firstMatch(in: str, range: NSRange(location: 0, length: ns.length)),
                  m.range.location == 0, m.range.length == ns.length else { return nil }
            return rx.replacementString(for: m, in: str, offset: 0, template: replacement)
        }
        for term in searchTerms where !term.isEmpty {
            if ns.compare(term, options: caseSensitive ? [] : .caseInsensitive) == .orderedSame { return replacement }
        }
        return nil
    }

    /// バイト `from` 以降で次の一致を探して選択する（前方スキャン・編集中でも動く）。見つかれば true。
    @discardableResult
    private func selectNextMatch(from: Int) -> Bool {
        guard let pt = pieceTable else { return false }
        let startLine = pt.line(ofByteOffset: from)
        let total = pt.lineCount
        // 現在行は from 以降のみ、以降の行は行頭から。末尾まで走査して無ければ先頭から from の行まで（ラップ）。
        func scan(_ range: Range<Int>, minByte: Int) -> Range<Int>? {
            for line in range where line < total {
                let cr = contentRange(ofLine: line)
                let str = lineString(cr)
                for r in matchRanges(in: str) {
                    let bs = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: r.location)
                    let be = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: r.location + r.length)
                    if bs >= minByte && bs < be { return bs..<be }
                }
            }
            return nil
        }
        let hit = scan(startLine..<total, minByte: from) ?? scan(0..<(startLine + 1), minByte: 0)
        guard let range = hit else { return false }
        selectionAnchor = range.lowerBound
        caretByte = range.upperBound
        caretGoalColumn = nil
        showCaretNow()
        scrollCaretIntoView()
        refresh()
        return true
    }

    // MARK: - tail -f（末尾追従・B4・クリーン時のみ）

    var isFollowing: Bool { followMode }

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
        guard let newSize = buffer.remapIfGrownTry() else { return }
        idx.extend(toByte: newSize)
        if wasAtBottom { topLine = maxTopLine }
        refresh()
    }

    // MARK: - ステータス

    /// 全索引途中の進捗（buildInBackground から更新）。ステータスバーの「索引中 N%」に使う。
    private var partialProgress: Double = 0

    private func emitState() {
        guard let idx = lineIndex, let buffer = fileBuffer else { return }
        // クリーン時は LineIndex（追従で伸びる）、編集後は piece table を真とする。
        let state = ViewerState(
            encodingName: saveEncoding.displayName,      // 保存されるエンコードを表示（変更は次の保存で反映）
            lineCount: readsFromOriginal ? idx.displayLineCount : (pieceTable?.lineCount ?? idx.displayLineCount),
            lineCountIsExact: readsFromOriginal ? idx.isComplete : (pieceTable != nil),
            fileSize: readsFromOriginal ? buffer.count : (pieceTable?.byteCount ?? buffer.count),
            indexProgress: idx.isComplete ? 1.0 : partialProgress
        )
        onStateChange?(state)
    }

    // MARK: - DocumentPane

    func reEmitState() { emitState() }
    func focusContent() { window?.makeFirstResponder(documentView) }

    /// 指定行（1 始まり）へスクロールする。
    func goToLine(_ line1Based: Int) {
        if filterMode { setFilterMode(false) }
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
        self.saveEncoding = encoding
        self.lineEnding = LineEnding.detect(Data(bytes), encoding: encoding)
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

    // 置換（B5）: 検索状態を直接注入して置換を駆動する（open の非同期を迂回）。
    func _testSetSearch(terms: [String], regex: NSRegularExpression? = nil, caseSensitive: Bool = false, matchLines: [Int]) {
        self.searchTerms = terms
        self.searchRegex = regex
        self.caseSensitive = caseSensitive
        self.searchQuery = regex?.pattern ?? terms.joined(separator: " ")
        var r = SearchEngine.Result()
        r.lines = matchLines
        r.lineCount = matchLines.count
        r.isComplete = true
        self.searchResults = r
    }
    func _testReplaceAll(_ s: String) { replaceAll(with: s) }
    func _testReplaceCurrent(_ s: String) { replaceCurrent(with: s) }
    var _testSelection: Range<Int>? { selectionRange }

    // 選択（B7）
    func _testSelectWord(at byte: Int) { selectWord(at: byte) }
    func _testSelectLine(at byte: Int) { selectLine(at: byte) }
    func _testClick(at byte: Int, extend: Bool = false) { placeCaret(at: byte, extend: extend) }

    // 保存（B3）
    var _testIsDirty: Bool { isDirty }
    @discardableResult func _testWrite(to url: URL) -> Bool { write(to: url) }
    func _testSaveAsync(to url: URL, onBegin: @escaping () -> Void,
                        progress: @escaping (Double) -> Void, completion: @escaping (Bool) -> Void) {
        fileURL = url
        saveAsync(saveAs: false, onBegin: onBegin, progress: progress, completion: completion)
    }
    func _testSetSaveEncoding(_ enc: DetectedEncoding) { setSaveEncoding(enc) }
    var _testSaveEncoding: DetectedEncoding { saveEncoding }
    var _testIsSaving: Bool { isSaving }

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
            insertBytes(lineEnding.bytes)
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
