import AppKit
import CoreText

/// テキスト入力（キャレット移動・変異）の委譲先。`PieceTableViewer` が実装する。
///
/// `DocumentView` は第一応答者としてキー入力を受け、`interpretKeyEvents` で
/// `NSTextInputClient` の各メソッドに分解したうえで、ここへ転送する。
/// 移動系（`doCommand`）＝B2a、確定テキスト挿入（`insertText`）＝B2b、
/// marked text（IME 変換中）＝B2c。
protocol DocumentTextInputHandler: AnyObject {
    /// `interpretKeyEvents` が解決した編集コマンド（`moveRight:` 等）。
    func doCommand(_ selector: Selector)
    /// 確定テキストの挿入。IME 確定もここに来る（marked を消して本挿入）。
    func insertText(_ text: String)

    // --- IME（marked text / 変換中）B2c ---
    /// 変換中文字列の更新。`selectedRange` は marked 内の選択（UTF-16）。
    func setMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange)
    /// 変換の確定（現在の marked をそのまま本挿入）。
    func unmarkText()
    /// 変換中か。
    func hasMarkedText() -> Bool
    /// 変換中文字列の範囲（marked 起点を 0 とするローカル UTF-16 範囲。無変換時は NSNotFound）。
    func markedRange() -> NSRange
    /// 選択／キャレット範囲（変換中は marked 内、そうでなければ空）。
    func selectedRange() -> NSRange
}

/// 可視行だけを描画する固定サイズビュー。
///
/// 状態（topLine やスクロール量）は持たない。表示すべき行の配列を
/// `LargeFileViewer` から受け取り、上から順に等幅・固定行高で描く。
/// 巨大な documentView 高さに頼らないため float 精度限界の影響を受けない。
final class DocumentView: NSView {
    var lineHeight: CGFloat = 16
    var gutterWidth: CGFloat = 64
    private let textLeftPadding: CGFloat = 8
    private let gutterRightPadding: CGFloat = 8

    /// 表示中の先頭行番号（0 始まり）。ガター番号表示に使う（連続表示時）。
    var firstLineNumber: Int = 0
    /// 各行の行番号（0 始まり）。非連続表示（フィルタ表示）のとき設定。nil なら firstLineNumber + i。
    var lineNumbers: [Int]? = nil
    /// 現在の検索一致がある行（可視リスト内のインデックス）。帯で強調。nil なら強調なし。
    var activeRow: Int? = nil
    private let activeLineColor = NSColor.systemTeal.withAlphaComponent(0.14)
    /// 行ごとの背景色（diff の追加/削除/変更の帯）。要素は `lines` と同じ並び。空なら塗らない。
    /// ガター（行番号）まで含めて塗るので、行が「どちら側に無いか」も色で分かる。
    var rowBackgrounds: [NSColor?] = []
    /// 行番号を出さない行（diff で相手側にしか無い行＝空白で埋める行）。`lineNumbers` の値がこれ。
    static let noLineNumber = -1
    /// 上から順に描画する行。
    var lines: [NSAttributedString] = [] { didSet { layoutsDirty = true } }

    var textAttributes: [NSAttributedString.Key: Any] = [:]
    private var gutterAttributes: [NSAttributedString.Key: Any] = [:]

    // MARK: - キャレット / 選択（PieceTableViewer のみ使用。未設定なら描かれない）

    /// キャレットの位置（可視行インデックスと、その行文字列内の UTF-16 オフセット）。
    /// nil ＝キャレットが可視範囲外／無し。
    var caret: (row: Int, utf16Index: Int)?
    /// 点滅の表示位相（false の間はキャレットを描かない）。
    var caretOn: Bool = true
    /// 各可視行の選択ハイライト。`range` はその行文字列内の UTF-16 範囲、
    /// `extendsToLineEnd` は改行をまたいで行末まで選択が続くか（右端まで帯を伸ばす）。
    struct RowSelection { var range: NSRange; var extendsToLineEnd: Bool }
    var selectionByRow: [Int: RowSelection] = [:]
    private var selectionColor = EditorTheme.current().selection

    /// 長い行の扱い。false＝折り返さず横スクロール、true＝内容幅で折り返す（B6・config 連動）。
    var wrapEnabled = false { didSet { if wrapEnabled != oldValue { layoutsDirty = true; needsDisplay = true } } }
    /// 折り返し無しのときの水平スクロール量（px）。
    var horizontalOffset: CGFloat = 0

    // MARK: - 表示設定（config 連動）

    /// キャレット行を淡い帯で強調するか（選択が無いときのみ）。
    var highlightCurrentLine = AppSettings.highlightCurrentLine
    /// キャレット形状。
    var cursorShape: CursorShape = AppSettings.cursorShape
    /// ブロックカーソルの幅（configure で font から算出）。
    private var caretWidth: CGFloat = 8
    private var currentLineColor = EditorTheme.current().currentLine
    /// 本文背景色（configure で theme から更新。draw の背景 fill に使う）。
    private var backgroundColor = EditorTheme.current().background
    /// ガター背景・区切り線（configure で theme から更新）。
    private var gutterBackground = EditorTheme.current().chromeBackground
    private var gutterSeparator = EditorTheme.current().separator

    /// 各可視論理行のレイアウト（折り返し・描画・座標変換）。lines/wrap/幅/フォント変化で再構築。
    private var rowLayouts: [LineLayout] = []
    private var layoutsDirty = true
    private var layoutWidth: CGFloat = 0

    /// 入力イベントを LargeFileViewer へ転送するためのフック。
    var onScrollWheel: ((NSEvent) -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?
    var onCopy: (() -> Void)?
    /// 編集メニュー（切り取り・貼り付け・全選択）を PieceTableViewer へ転送するフック（B2b）。
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onSelectAll: (() -> Void)?
    /// マウス操作を PieceTableViewer へ転送するためのフック（押下・ドラッグ）。
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?

    /// 編集用のアンドゥマネージャ（B2b）。PieceTableViewer が編集を有効化するとき注入する。
    /// メニュー ⌘Z / ⌘⇧Z（`undo:` / `redo:`）はレスポンダチェーンでここに届く。
    weak var editUndoManager: UndoManager?

    /// テキスト入力の委譲先。設定時のみキー入力を `interpretKeyEvents` 経由で編集系に流す。
    /// nil（読み取り専用の LargeFileViewer / 索引構築中）なら従来の `onKeyDown`（スクロール）。
    weak var inputHandler: DocumentTextInputHandler?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(font: NSFont) {
        lineHeight = EditorStyle.lineHeight(for: font)
        caretWidth = EditorStyle.caretWidth(for: font)
        // 行番号が収まるよう、ガター幅をフォントサイズに追従させる。
        gutterWidth = max(64, ceil(font.pointSize * 4.5))
        // 配色（config 連動）を読み直す。
        let theme = EditorTheme.current()
        selectionColor = theme.selection
        currentLineColor = theme.currentLine
        backgroundColor = theme.background
        gutterBackground = theme.chromeBackground
        gutterSeparator = theme.separator
        textAttributes = [
            .font: font,
            .foregroundColor: theme.foreground,
            .paragraphStyle: EditorStyle.paragraphStyle(for: font),
        ]
        gutterAttributes = [
            .font: font,
            .foregroundColor: theme.chromeSecondaryText,
        ]
        layoutsDirty = true
    }

    private var contentX: CGFloat { gutterWidth + textLeftPadding }

    /// 論理行レイアウトを（必要なら）再構築する。折り返し時は内容幅で行を折る。
    private func rebuildLayoutsIfNeeded() {
        let width = max(1, bounds.width - contentX - 4)
        if !layoutsDirty && width == layoutWidth && rowLayouts.count == lines.count { return }
        layoutWidth = width
        layoutsDirty = false
        rowLayouts = lines.map { LineLayout($0, maxWidth: width, wrap: wrapEnabled, lineHeight: lineHeight) }
    }

    /// 背景不透明度 < 1.0 のときは非不透明ビューとして描く（背後のデスクトップを透かす）。
    override var isOpaque: Bool { EditorTheme.isOpaqueBackground }

    override func draw(_ dirtyRect: NSRect) {
        let clip = dirtyRect.intersection(bounds)
        if !EditorTheme.isOpaqueBackground {
            // 非不透明時: 前フレームの残像を消してから半透明色を重ねる。
            NSColor.clear.set()
            clip.fill(using: .copy)
        }
        EditorTheme.withBackgroundOpacity(backgroundColor).setFill()
        // **dirtyRect をそのまま塗らない。** NSView は既定でクリップしないため、dirtyRect が
        // 自分の bounds を超えて（ウィンドウ全体まで）来ると、隣に並んだビューを塗り潰す。
        // 単独表示では全面を塗るので露見しなかったが、diff で左右に並べた瞬間に左が消えた。
        clip.fill()

        // ガター背景
        let gutterRect = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        EditorTheme.withBackgroundOpacity(gutterBackground).setFill()
        gutterRect.fill()
        gutterSeparator.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: gutterWidth - 0.5, y: 0))
        divider.line(to: NSPoint(x: gutterWidth - 0.5, y: bounds.height))
        divider.stroke()

        guard !lines.isEmpty else { return }
        rebuildLayoutsIfNeeded()

        let xOff = wrapEnabled ? 0 : horizontalOffset
        let numOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        var y: CGFloat = 0
        for (i, layout) in rowLayouts.enumerated() {
            if y > bounds.height { break }
            let rowH = layout.height

            // diff の行帯（ガターごと塗る＝「この行は相手側に無い」が色で分かる）
            if i < rowBackgrounds.count, let bg = rowBackgrounds[i] {
                bg.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: rowH).fill()
            }

            // キャレット行の帯（選択が無いときのみ・折り返し分の高さ全体）
            if highlightCurrentLine, caret?.row == i, selectionByRow[i] == nil {
                currentLineColor.setFill()
                NSRect(x: gutterWidth, y: y, width: max(0, bounds.width - gutterWidth), height: rowH).fill()
            }

            // アクティブ一致行の帯（折り返し分の高さ全体）
            if i == activeRow {
                activeLineColor.setFill()
                NSRect(x: gutterWidth, y: y, width: max(0, bounds.width - gutterWidth), height: rowH).fill()
            }

            // ガター（行番号・右寄せ・先頭サブ行の高さに合わせる）
            let lineNo = (lineNumbers != nil && i < lineNumbers!.count) ? lineNumbers![i] : firstLineNumber + i
            // diff で相手側にしか無い行は番号を出さない（存在しない行に番号を振らない）。
            let numStr = lineNo == DocumentView.noLineNumber
                ? NSAttributedString(string: "", attributes: gutterAttributes)
                : NSAttributedString(string: "\(lineNo + 1)", attributes: gutterAttributes)
            let numSize = numStr.size()
            let numX = gutterWidth - gutterRightPadding - numSize.width
            numStr.draw(with: NSRect(x: max(2, numX), y: y, width: numSize.width, height: lineHeight), options: numOpts)

            // ここから先（選択・本文・キャレット）は横スクロールで左へずれる。
            // ガターの上に本文が乗らないよう、本文領域へクリップする。
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: gutterWidth, y: 0,
                                      width: max(0, bounds.width - gutterWidth),
                                      height: bounds.height)).setClip()
            defer { NSGraphicsContext.restoreGraphicsState() }

            // 選択ハイライト（折り返しをまたいで内包矩形で塗る）
            if let sel = selectionByRow[i] {
                selectionColor.setFill()
                let origin = NSPoint(x: contentX - xOff, y: y)
                layout.enumerateSelectionRects(sel.range, extendToEnd: sel.extendsToLineEnd,
                                               origin: origin, viewWidth: bounds.width) { NSBezierPath(rect: $0).fill() }
            }

            // 本文（折り返し分をまとめて描画。折り返し無しは水平オフセットを引く）
            layout.draw(at: NSPoint(x: contentX - xOff, y: y))

            // キャレット（形状は config 連動）
            if caretOn, let c = caret, c.row == i {
                let p = layout.caretPoint(forCharIndex: c.utf16Index)
                let x = contentX - xOff + p.x
                NSColor.textColor.setFill()
                switch cursorShape {
                case .bar:
                    NSRect(x: x, y: y + p.y, width: 1.5, height: lineHeight).fill()
                case .block:
                    NSColor.textColor.withAlphaComponent(0.4).setFill()
                    NSRect(x: x, y: y + p.y, width: caretWidth, height: lineHeight).fill()
                case .underline:
                    NSRect(x: x, y: y + p.y + lineHeight - 2, width: caretWidth, height: 2).fill()
                }
            }
            y += rowH
        }

        if !lines.isEmpty { OpenTiming.firstPaint() }   // MREDITOR_TIMING=1 のときだけ動く
    }

    /// 点 `p`（このビュー座標）に最も近い挿入位置を (可視行, 行内 UTF-16 オフセット) で返す。
    func index(at p: NSPoint) -> (row: Int, utf16Index: Int)? {
        guard !lines.isEmpty else { return nil }
        rebuildLayoutsIfNeeded()
        let xOff = wrapEnabled ? 0 : horizontalOffset
        var y: CGFloat = 0
        for (i, layout) in rowLayouts.enumerated() {
            if p.y < y + layout.height || i == rowLayouts.count - 1 {
                let local = NSPoint(x: max(0, p.x - contentX + xOff), y: max(0, p.y - y))
                return (i, layout.charIndex(at: local))
            }
            y += layout.height
        }
        return (rowLayouts.count - 1, 0)
    }

    /// 可視論理行 `row` の総高さ（折り返し分込み）。キャレットスクロール計算用に viewer が使う。
    func rowHeight(_ row: Int) -> CGFloat {
        rebuildLayoutsIfNeeded()
        guard row >= 0, row < rowLayouts.count else { return lineHeight }
        return rowLayouts[row].height
    }

    /// 可視論理行 `row` の描画幅（折り返し無しのとき最長サブ行幅）。水平スクロール上限に使う。
    func rowWidth(_ row: Int) -> CGFloat {
        rebuildLayoutsIfNeeded()
        guard row >= 0, row < rowLayouts.count else { return 0 }
        return rowLayouts[row].width
    }

    /// 折り返し無しのときに水平スクロールできる最大量（可視行の最長幅 − 表示幅）。
    var maxHorizontalOffset: CGFloat {
        guard !wrapEnabled else { return 0 }
        rebuildLayoutsIfNeeded()
        let widest = rowLayouts.map { $0.width }.max() ?? 0
        let visible = max(0, bounds.width - contentX - 4)
        return max(0, widest - visible + 12)
    }

    /// 水平スクロール量を設定（クランプ）。変化したら再描画。
    func setHorizontalOffset(_ x: CGFloat) {
        let clamped = min(max(0, x), maxHorizontalOffset)
        guard clamped != horizontalOffset else { return }
        horizontalOffset = clamped
        needsDisplay = true
    }

    /// 折り返し無しのとき、キャレットが水平方向に見えるよう `horizontalOffset` を寄せる。
    func ensureCaretVisibleHorizontally() {
        guard !wrapEnabled, let c = caret else { return }
        rebuildLayoutsIfNeeded()
        guard c.row < rowLayouts.count else { return }
        let x = rowLayouts[c.row].caretPoint(forCharIndex: c.utf16Index).x
        let visibleWidth = max(0, bounds.width - contentX - 4)
        var off = horizontalOffset
        if x - off > visibleWidth - 12 { off = x - visibleWidth + 12 }
        if x - off < 0 { off = x - 12 }
        setHorizontalOffset(off)
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?(event)
    }

    override func keyDown(with event: NSEvent) {
        if inputHandler != nil {
            interpretKeyEvents([event])
        } else {
            onKeyDown?(event)
        }
    }

    /// 入力ハンドラが無い（読み取り専用）ときは入力コンテキストを持たず、IME を起動させない。
    override var inputContext: NSTextInputContext? {
        inputHandler == nil ? nil : super.inputContext
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onMouseDown?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(event)
    }

    /// 標準のコピー（⌘C）。可視範囲を LargeFileViewer 経由でクリップボードへ。
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    /// 切り取り（⌘X）／貼り付け（⌘V）／全選択（⌘A）。編集有効時のみ PieceTableViewer が処理（B2b）。
    @objc func cut(_ sender: Any?) { onCut?() }
    @objc func paste(_ sender: Any?) { onPaste?() }
    override func selectAll(_ sender: Any?) {
        if let onSelectAll { onSelectAll() } else { super.selectAll(sender) }
    }

    /// アンドゥ（⌘Z）／リドゥ（⌘⇧Z）。編集用マネージャへ委譲する（B2b）。
    @objc func undo(_ sender: Any?) { editUndoManager?.undo() }
    @objc func redo(_ sender: Any?) { editUndoManager?.redo() }
}

// MARK: - メニュー項目の有効／無効

extension DocumentView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return editUndoManager?.canUndo ?? false
        case #selector(redo(_:)): return editUndoManager?.canRedo ?? false
        case #selector(cut(_:)):
            return inputHandler != nil          // 編集有効時のみ（読み取り専用ビューアでは無効）
        case #selector(copy(_:)):
            return true                          // 読み取り専用でも可。選択の有無はフックが判断
        case #selector(selectAll(_:)):
            return onSelectAll != nil && !lines.isEmpty
        case #selector(paste(_:)):
            return inputHandler != nil && NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
        default:
            return true
        }
    }
}

// MARK: - NSTextInputClient

/// キー入力を編集コマンド／確定テキスト／IME に分解して `inputHandler` へ転送する。
/// B2a は移動系（`doCommandBySelector`）のみ本実装。marked text（IME）は B2c で拡張する。
extension DocumentView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        inputHandler?.insertText(text)
    }

    override func doCommand(by selector: Selector) {
        // 未対応セレクタもここで握り潰し、`noResponder` のビープを避ける。
        inputHandler?.doCommand(selector)
    }

    // --- marked text（IME 変換中）: B2c。状態と描画は PieceTableViewer が持つ。 ---
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        inputHandler?.setMarkedText(text, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    func unmarkText() { inputHandler?.unmarkText() }
    func hasMarkedText() -> Bool { inputHandler?.hasMarkedText() ?? false }
    func markedRange() -> NSRange { inputHandler?.markedRange() ?? NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { inputHandler?.selectedRange() ?? NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// 変換候補ウィンドウの位置決め。現在のキャレット（変換中は marked 内）の画面矩形を返す。
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let c = caret, let win = window else { return .zero }
        rebuildLayoutsIfNeeded()
        let xOff = wrapEnabled ? 0 : horizontalOffset
        var y: CGFloat = 0
        for (i, layout) in rowLayouts.enumerated() {
            if i == c.row {
                let p = layout.caretPoint(forCharIndex: c.utf16Index)
                let inView = NSRect(x: contentX - xOff + p.x, y: y + p.y, width: 1, height: lineHeight)
                return win.convertToScreen(convert(inView, to: nil))
            }
            y += layout.height
        }
        return .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

// MARK: - 1 論理行のレイアウト（折り返し・描画・座標変換）

/// `NSLayoutManager` で 1 論理行をレイアウトし、折り返し込みの描画・キャレット・ヒットテスト・
/// 選択矩形を提供する。折り返し無し（`wrap=false`）のときはコンテナ幅を無限にして 1 行に収める。
private final class LineLayout {
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    let rowCount: Int
    let height: CGFloat
    let width: CGFloat

    init(_ attr: NSAttributedString, maxWidth: CGFloat, wrap: Bool, lineHeight: CGFloat) {
        storage = NSTextStorage(attributedString: attr)
        let w = wrap ? maxWidth : CGFloat.greatestFiniteMagnitude
        container = NSTextContainer(size: NSSize(width: w, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        // 折り返しで何行になったかを数える。
        var rows = 0
        let glyphs = manager.numberOfGlyphs
        if glyphs == 0 {
            rows = 1
        } else {
            var gi = 0
            while gi < glyphs {
                var lr = NSRange()
                _ = manager.lineFragmentRect(forGlyphAt: gi, effectiveRange: &lr)
                rows += 1
                gi = NSMaxRange(lr)
            }
        }
        rowCount = max(1, rows)
        height = CGFloat(rowCount) * lineHeight
        width = ceil(manager.usedRect(for: container).width)
    }

    func draw(at origin: CGPoint) {
        let gr = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: gr, at: origin)   // 検索ハイライト等の背景色
        manager.drawGlyphs(forGlyphRange: gr, at: origin)
    }

    /// 文字位置 `ci`（UTF-16）のキャレット原点（このレイアウト座標・左上原点）。
    func caretPoint(forCharIndex ci: Int) -> CGPoint {
        let len = storage.length
        guard len > 0 else { return .zero }
        let clamped = min(max(0, ci), len)
        if clamped >= len {
            let last = manager.numberOfGlyphs - 1
            guard last >= 0 else { return .zero }
            let lr = manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
            let rect = manager.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: container)
            return CGPoint(x: rect.maxX, y: lr.minY)
        }
        let gi = manager.glyphIndexForCharacter(at: clamped)
        let lr = manager.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
        let loc = manager.location(forGlyphAt: gi)
        return CGPoint(x: lr.minX + loc.x, y: lr.minY)
    }

    /// レイアウト座標 `point`（左上原点）に最も近い挿入位置（UTF-16）。
    func charIndex(at point: CGPoint) -> Int {
        guard manager.numberOfGlyphs > 0 else { return 0 }
        var frac: CGFloat = 0
        let gi = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &frac)
        var ci = manager.characterIndexForGlyph(at: gi)
        if frac > 0.5 { ci += 1 }
        return min(max(0, ci), storage.length)
    }

    /// UTF-16 レンジの選択矩形を（折り返しをまたいで）列挙する。`extendToEnd` で右端まで伸ばす。
    func enumerateSelectionRects(_ range: NSRange, extendToEnd: Bool, origin: CGPoint,
                                 viewWidth: CGFloat, _ body: (NSRect) -> Void) {
        let len = storage.length
        let loc = min(max(0, range.location), len)
        let end = min(range.location + range.length, len)
        let charRange = NSRange(location: loc, length: max(0, end - loc))
        if charRange.length == 0 {
            if extendToEnd {   // 改行のみ選択（空行など）→ 行頭に細い帯
                let p = caretPoint(forCharIndex: loc)
                body(NSRect(x: origin.x + p.x, y: origin.y + p.y, width: max(4, viewWidth - (origin.x + p.x)), height: height / CGFloat(rowCount)))
            }
            return
        }
        let glyphRange = manager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rects: [NSRect] = []
        manager.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { rect, _ in
            var r = rect.offsetBy(dx: origin.x, dy: origin.y)
            if extendToEnd { r.size.width = max(r.width, viewWidth - r.minX) }
            rects.append(r)
        }
        for r in rects { body(r) }
    }
}
