import AppKit

/// 小ファイル編集ペイン（`NSTextView`）の左に行番号を出すガター。
///
/// 巨大ファイル側は `DocumentView` が可視行を自前で描くのでガターも自前だが、
/// 小ファイル側は AppKit のレイアウトに乗っているので `NSRulerView` に載せる。
/// 見た目（背景・区切り線・文字色・フォント）は `DocumentView` のガターに揃える。
final class LineNumberRulerView: NSRulerView {
    /// 行頭索引の供給元。本文が変わると `EditableViewer` が作り直したものを返す。
    var lineIndexProvider: (() -> LineStartIndex)?

    private let rightPadding: CGFloat = 8
    private let leftPadding: CGFloat = 6

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 行数の桁数とフォントに合わせてガター幅を決める（`DocumentView` と同じ考え方）。
    func updateThickness() {
        let font = EditorFont.current()
        let digits = max(3, String(lineIndexProvider?().lineCount ?? 1).count)
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(width * CGFloat(digits)) + leftPadding + rightPadding
        if abs(thickness - ruleThickness) > 0.5 { ruleThickness = thickness }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let lm = textView.layoutManager, let tc = textView.textContainer else { return }

        // 背景と右端の区切り線（本文側のガターと同じ配色）。
        let theme = EditorTheme.current()
        EditorTheme.withBackgroundOpacity(theme.chromeBackground).setFill()
        bounds.fill()
        theme.separator.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        divider.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        divider.stroke()

        let font = EditorFont.current()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.chromeSecondaryText]
        let index = lineIndexProvider?() ?? LineStartIndex("")
        let text = textView.string as NSString

        // 可視範囲（＝スクロール位置）に掛かる論理行だけ番号を描く。
        let visible = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let lastVisibleChar = NSMaxRange(charRange)

        // ルーラ座標へ移すためのオフセット（スクロール量＋テキストコンテナの余白）。
        let originY = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y

        var line = index.lineIndex(at: charRange.location)
        var charIndex = index.start(ofLine: line)
        while charIndex <= text.length {
            if charIndex > lastVisibleChar { break }
            let y: CGFloat
            if text.length == 0 || charIndex == text.length {
                // 末尾が改行なら、その後ろの空行（extra line fragment）にも番号を振る。
                let extra = lm.extraLineFragmentRect
                if extra.isEmpty { break }
                y = originY + extra.minY
            } else {
                let glyph = lm.glyphIndexForCharacter(at: charIndex)
                let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
                // 行間を広げると本文の基線は行の下寄りに来る。番号も同じ基線に合わせる。
                y = originY + frag.minY + lm.location(forGlyphAt: glyph).y - font.ascender
            }
            let label = NSAttributedString(string: "\(line + 1)", attributes: attrs)
            let size = label.size()
            label.draw(at: NSPoint(x: max(2, ruleThickness - rightPadding - size.width), y: y))

            line += 1
            if charIndex == text.length { break }
            charIndex = NSMaxRange(text.lineRange(for: NSRange(location: charIndex, length: 0)))
        }
    }
}
