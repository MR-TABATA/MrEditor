import AppKit

/// 小ファイル編集用 `NSTextView` の派生。標準の機能（IME・アンドゥ・選択）は
/// そのままに、キャレット形状と現在行ハイライトだけを config 連動で差し替える。
final class EditorTextView: NSTextView {
    var cursorShape: CursorShape = AppSettings.cursorShape
    var highlightCurrentLine: Bool = AppSettings.highlightCurrentLine

    private var caretWidth: CGFloat {
        EditorStyle.caretWidth(for: font ?? EditorFont.current())
    }

    // MARK: - 現在行ハイライト

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightCurrentLine, selectedRange().length == 0,
              let lm = layoutManager, let tc = textContainer else { return }
        let len = (string as NSString).length
        let loc = min(selectedRange().location, len)
        let glyph = lm.glyphIndexForCharacter(at: loc)
        var frag: NSRect
        if lm.numberOfGlyphs == 0 {
            frag = lm.extraLineFragmentRect            // 空ドキュメント
        } else {
            frag = lm.lineFragmentRect(forGlyphAt: min(glyph, lm.numberOfGlyphs - 1), effectiveRange: nil)
        }
        frag.origin.x = 0
        frag.size.width = bounds.width
        frag = frag.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        _ = tc
        EditorTheme.current().currentLine.setFill()
        frag.fill()
    }

    /// 選択（キャレット）移動で現在行ハイライトを描き直す。
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if highlightCurrentLine { needsDisplay = true }
    }

    // MARK: - キャレット形状

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard cursorShape != .bar else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        guard flag else { return }
        var r = rect
        r.size.width = caretWidth
        if cursorShape == .block {
            color.withAlphaComponent(0.4).setFill()
        } else { // underline
            r.origin.y = rect.maxY - 2
            r.size.height = 2
            color.setFill()
        }
        r.fill()
    }

    /// ブロック／アンダーラインは幅を持つため、消去範囲を 1 文字ぶん広げる。
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = invalidRect
        if cursorShape != .bar { r.size.width += caretWidth }
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }
}
