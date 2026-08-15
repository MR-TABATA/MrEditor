import AppKit

extension EditorColorTheme {
    /// 桁ガイド線の色。**設定には出さずテーマから導く**（配色タブに項目を増やさない）。
    /// ルーラーの印と本文に重ねる線で濃さを変えるので、透明度は呼ぶ側が決める。
    func columnGuide(alpha: CGFloat) -> NSColor {
        chromeSecondaryText.withAlphaComponent(alpha)
    }
}

/// 本文の上に出す桁ルーラー（A）と、桁ガイドの操作面（B）。
///
/// 両ペインで**同じこのビュー**を使う。小ファイルは `NSScrollView` の上に、巨大ファイルは
/// `DocumentView` の上に置き、それぞれが `contentInset`（1 桁目の x）と `horizontalOffset`
/// （横スクロール量）を教える。桁 ↔ x の変換は `ColumnRuler` にしかないので、
/// 置き方が違っても目盛りの位置は必ず一致する。
final class ColumnRulerView: NSView {
    static let height: CGFloat = 16

    /// 等幅フォント 1 桁の幅。
    var columnWidth: CGFloat = 8 { didSet { if columnWidth != oldValue { needsDisplay = true } } }
    /// このビューの座標で、1 桁目の左端が来る x（ガター幅＋本文の左余白）。
    var contentInset: CGFloat = 0 { didSet { if contentInset != oldValue { needsDisplay = true } } }
    /// 本文の横スクロール量。
    var horizontalOffset: CGFloat = 0 { didSet { if horizontalOffset != oldValue { needsDisplay = true } } }
    /// 引いてあるガイド。
    var guides = ColumnGuides() { didSet { if guides != oldValue { needsDisplay = true } } }
    /// キャレットのある桁（1 始まり）。nil なら強調しない。
    var currentColumn: Int? { didSet { if currentColumn != oldValue { needsDisplay = true } } }
    /// 選択の桁範囲（1 始まり・閉区間）。nil なら帯を出さない。
    var selectedColumns: ClosedRange<Int>? { didSet { if selectedColumns != oldValue { needsDisplay = true } } }

    /// ルーラーをクリックしてガイドを足す／消す。
    var onToggleGuide: ((Int) -> Void)?

    /// 数字ラベルの当たり判定を緩める許容幅（桁）。細い線をピクセル単位で狙わせない。
    private let hitTolerance = 1

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { EditorTheme.isOpaqueBackground }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    /// このビュー座標の x にある桁。
    private func column(atViewX x: CGFloat) -> Int {
        ColumnRuler.column(atX: x - contentInset + horizontalOffset, columnWidth: columnWidth)
    }

    /// 桁 `col` の左端のビュー座標 x。
    private func viewX(ofColumn col: Int) -> CGFloat {
        contentInset - horizontalOffset + ColumnRuler.x(ofColumn: col, columnWidth: columnWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = EditorTheme.current()
        if !EditorTheme.isOpaqueBackground {
            NSColor.clear.set()
            dirtyRect.intersection(bounds).fill(using: .copy)
        }
        EditorTheme.withBackgroundOpacity(theme.chromeBackground).setFill()
        dirtyRect.intersection(bounds).fill()

        // 下端の区切り線（ガターの区切りと同じ色）。
        theme.separator.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        divider.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        divider.stroke()

        // 本文が始まる位置より左（ガターの上）には目盛りを描かない。
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: NSRect(x: contentInset, y: 0,
                                  width: max(0, bounds.width - contentInset),
                                  height: bounds.height)).setClip()

        // 選択の桁範囲（帯）。目盛りより下に敷く。
        if let sel = selectedColumns {
            let x0 = viewX(ofColumn: sel.lowerBound)
            let x1 = viewX(ofColumn: sel.upperBound + 1)
            theme.selection.setFill()
            NSRect(x: x0, y: 0, width: max(1, x1 - x0), height: bounds.height - 1).fill()
        }

        // キャレット桁（1 桁ぶんの塗り）。
        if let cur = currentColumn {
            let x0 = viewX(ofColumn: cur)
            theme.currentLine.setFill()
            NSRect(x: x0, y: 0, width: max(1, columnWidth), height: bounds.height - 1).fill()
        }

        drawTicks(theme: theme)
        drawGuideMarkers(theme: theme)
    }

    private func drawTicks(theme: EditorColorTheme) {
        let width = max(0, bounds.width - contentInset)
        let ticks = ColumnRuler.ticks(offset: horizontalOffset, width: width, columnWidth: columnWidth)
        guard !ticks.isEmpty else { return }

        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: theme.chromeSecondaryText,
        ]
        // 数字が隣とぶつかるほど詰まったら数字は出さず目盛りだけにする。
        let majorSpacing = columnWidth * 10
        let showLabels = majorSpacing >= 26

        theme.chromeSecondaryText.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for tick in ticks {
            let x = floor(contentInset - horizontalOffset + tick.x) + 0.5
            let top = tick.isMajor ? bounds.height - 6 : bounds.height - 4
            path.move(to: NSPoint(x: x, y: top))
            path.line(to: NSPoint(x: x, y: bounds.height - 1))
        }
        path.stroke()

        guard showLabels else { return }
        for tick in ticks where tick.isMajor {
            let label = NSAttributedString(string: "\(tick.column)", attributes: labelAttrs)
            let size = label.size()
            let x = contentInset - horizontalOffset + tick.x
            // 目盛りの右隣に置く。1 桁目だけは線の上に乗らないよう少し右へ。
            label.draw(at: NSPoint(x: x + 2, y: max(0, (bounds.height - 6 - size.height) / 2)))
        }
    }

    private func drawGuideMarkers(theme: EditorColorTheme) {
        guard !guides.isEmpty else { return }
        theme.columnGuide(alpha: 0.85).setFill()
        for col in guides.columns {
            let x = floor(viewX(ofColumn: col))
            // 掴みやすいよう、線そのものより太い印を出す。
            NSRect(x: x - 1, y: 1, width: 3, height: bounds.height - 3).fill()
        }
    }

    // MARK: - 操作

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.x >= contentInset else { return }
        let col = column(atViewX: p.x)
        // 近くに既にあるならそれを消す（細い線を正確に狙わせない）。
        let target = guides.nearest(to: col, within: hitTolerance) ?? col
        onToggleGuide?(target)
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: contentInset, y: 0,
                             width: max(0, bounds.width - contentInset), height: bounds.height),
                      cursor: .crosshair)
    }
}
