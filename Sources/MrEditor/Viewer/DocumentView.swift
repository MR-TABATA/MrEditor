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
    /// 上から順に描画する行。
    var lines: [NSAttributedString] = []

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
    private let selectionColor = NSColor.selectedTextBackgroundColor

    /// 行文字列 → CTLine のキャッシュ（同一フレーム内でキャレット・選択・ヒットテストが共有）。
    private var ctLineCache: [Int: CTLine] = [:]

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
        let lm = NSLayoutManager()
        lineHeight = ceil(lm.defaultLineHeight(for: font))
        // 行番号が収まるよう、ガター幅をフォントサイズに追従させる。
        gutterWidth = max(64, ceil(font.pointSize * 4.5))
        textAttributes = [
            .font: font,
            .foregroundColor: NSColor.textColor,
        ]
        gutterAttributes = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        ctLineCache.removeAll(keepingCapacity: true)
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        // ガター背景
        let gutterRect = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        NSColor.windowBackgroundColor.setFill()
        gutterRect.fill()
        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: gutterWidth - 0.5, y: 0))
        divider.line(to: NSPoint(x: gutterWidth - 0.5, y: bounds.height))
        divider.stroke()

        guard !lines.isEmpty else { return }

        let contentX = gutterWidth + textLeftPadding
        let contentWidth = max(0, bounds.width - contentX)

        let drawOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        for (i, line) in lines.enumerated() {
            let y = CGFloat(i) * lineHeight
            if y > bounds.height { break }

            // アクティブ一致行の帯（本文領域）
            if i == activeRow {
                let band = NSRect(x: gutterWidth, y: y, width: max(0, bounds.width - gutterWidth), height: lineHeight)
                activeLineColor.setFill()
                band.fill()
            }

            // 選択ハイライト（テキストの下に敷く）
            if let sel = selectionByRow[i] {
                let ctl = ctLine(for: i)
                let x0 = contentX + CTLineGetOffsetForStringIndex(ctl, sel.range.location, nil)
                let x1 = sel.extendsToLineEnd
                    ? bounds.width
                    : contentX + CTLineGetOffsetForStringIndex(ctl, sel.range.location + sel.range.length, nil)
                let w = max(x1 - x0, sel.extendsToLineEnd ? 4 : 0)
                if w > 0 {
                    selectionColor.setFill()
                    NSRect(x: x0, y: y, width: w, height: lineHeight).fill()
                }
            }

            // ガター（行番号、右寄せ）
            let lineNo = (lineNumbers != nil && i < lineNumbers!.count) ? lineNumbers![i] : firstLineNumber + i
            let numStr = NSAttributedString(string: "\(lineNo + 1)",
                                            attributes: gutterAttributes)
            let numSize = numStr.size()
            let numX = gutterWidth - gutterRightPadding - numSize.width
            let numRect = NSRect(x: max(2, numX), y: y, width: numSize.width, height: lineHeight)
            numStr.draw(with: numRect, options: drawOpts)

            // 本文（右端でクリップ。横スクロールは v0.2 以降）
            let lineRect = NSRect(x: contentX, y: y, width: contentWidth, height: lineHeight)
            line.draw(with: lineRect, options: drawOpts)

            // キャレット（テキストの上に重ねる）
            if caretOn, let c = caret, c.row == i {
                let ctl = ctLine(for: i)
                let x = contentX + CTLineGetOffsetForStringIndex(ctl, c.utf16Index, nil)
                NSColor.textColor.setFill()
                NSRect(x: x, y: y, width: 1.5, height: lineHeight).fill()
            }
        }
    }

    /// 行文字列の CTLine（同一フレーム内でキャッシュ。x 位置計算とヒットテストで共有）。
    private func ctLine(for row: Int) -> CTLine {
        if let c = ctLineCache[row] { return c }
        let attr = (row >= 0 && row < lines.count) ? lines[row] : NSAttributedString(string: "")
        let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
        ctLineCache[row] = line
        return line
    }

    /// 点 `p`（このビュー座標）に最も近い挿入位置を (可視行, 行内 UTF-16 オフセット) で返す。
    func index(at p: NSPoint) -> (row: Int, utf16Index: Int)? {
        guard !lines.isEmpty else { return nil }
        let contentX = gutterWidth + textLeftPadding
        var row = Int(floor(p.y / lineHeight))
        row = min(max(0, row), lines.count - 1)
        let ctl = ctLine(for: row)
        let idx = CTLineGetStringIndexForPosition(ctl, CGPoint(x: max(0, p.x - contentX), y: 0))
        return (row, idx == kCFNotFound ? 0 : max(0, idx))
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
        let ctl = ctLine(for: c.row)
        let x = gutterWidth + textLeftPadding + CTLineGetOffsetForStringIndex(ctl, c.utf16Index, nil)
        let y = CGFloat(c.row) * lineHeight
        let inWindow = convert(NSRect(x: x, y: y, width: 1, height: lineHeight), to: nil)
        return win.convertToScreen(inWindow)
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
