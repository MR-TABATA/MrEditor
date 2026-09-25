import AppKit

/// 構造化表示中に本文の上へ固定する列名の帯（グリッドの見出し）と、列幅の掴み手。
///
/// **桁ルーラーと同じ場所・同じ座標計算**（`ColumnRuler`）を使う。両ペインで同じこのビューを
/// 使い、それぞれが `contentInset`（1 桁目の x）と `horizontalOffset`（横スクロール量）を教える。
///
/// 列名は本文の 1 行目とは限らない（NDJSON はキー、固定長は桁そのもの）。スクロールしても
/// 消えないので、581 万行の 300 万行目でも「この列は何か」が分かる。
final class StructuredHeaderView: NSView {
    static let height: CGFloat = 20

    /// 等幅フォント 1 桁の幅。
    var columnWidth: CGFloat = 8 { didSet { if columnWidth != oldValue { needsDisplay = true } } }
    /// このビューの座標で、1 桁目の左端が来る x。
    var contentInset: CGFloat = 0 { didSet { if contentInset != oldValue { needsDisplay = true } } }
    /// 本文の横スクロール量。
    var horizontalOffset: CGFloat = 0 { didSet { if horizontalOffset != oldValue { needsDisplay = true } } }

    /// 列名と、各列が始まる桁・幅（`TabularFormatter` から貰う）。
    struct Column: Equatable { let name: String; let start: Int; let width: Int }
    var columns: [Column] = [] { didSet { if columns != oldValue { needsDisplay = true } } }

    /// 列幅を変え終わったとき（列の番号・新しい幅）。**離した時だけ呼ぶ**（引きずるたびに
    /// 数百万行を組み直さない）。
    var onResize: ((Int, Int) -> Void)?

    /// 列を並べ替え終わったとき（元の列番号・移動先の列番号）。**離した時だけ呼ぶ**
    /// （resize と同じ作法。引きずるたびに本文を組み直さない）。
    var onReorder: ((Int, Int) -> Void)?

    /// この整形が並べ替えに対応しているか（B19: fixedWidth は対象外 ── 項目=桁位置そのもの
    /// なので、呼ぶ側が `mode` を見て設定する）。既定は対応あり。
    var allowsReorder: Bool = true

    /// 掴み手の当たり判定（桁）。細い線をピクセル単位で狙わせない。
    private let hitTolerance = 1

    /// 掴んでいる列と、いまの引きずり先の桁（プレビュー線を出すためだけに持つ）。
    private var draggingIndex: Int?
    private var draggingColumn: Int?

    /// 並べ替え中の掴み元の列と、いまの挿入先の列（どちらも `columns` の index）。
    private var reorderSourceIndex: Int?
    private var reorderTargetIndex: Int?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { EditorTheme.isOpaqueBackground }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: - 桁 ↔ x（ルーラーと同じ式）

    private func viewX(ofColumn col: Int) -> CGFloat {
        contentInset - horizontalOffset + ColumnRuler.x(ofColumn: col, columnWidth: columnWidth)
    }

    private func column(atViewX x: CGFloat) -> Int {
        ColumnRuler.column(atX: x - contentInset + horizontalOffset, columnWidth: columnWidth)
    }

    /// 掴み手のある桁（各列の右端の次）。
    private var handleColumns: [Int] { columns.map { $0.start + $0.width } }

    /// x にある列の index（並べ替えの掴み元・挿入先の判定に使う）。画面外なら nil。
    private func columnIndex(atViewX x: CGFloat) -> Int? {
        let col = column(atViewX: x)
        return columns.firstIndex { col >= $0.start && col < $0.start + max($0.width, 1) }
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        let theme = EditorTheme.current()
        if !EditorTheme.isOpaqueBackground {
            NSColor.clear.set()
            dirtyRect.intersection(bounds).fill(using: .copy)
        }
        EditorTheme.withBackgroundOpacity(theme.chromeBackground).setFill()
        dirtyRect.intersection(bounds).fill()

        theme.separator.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        divider.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        divider.stroke()

        // ガターの上には何も描かない。
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: NSRect(x: contentInset, y: 0,
                                  width: max(0, bounds.width - contentInset),
                                  height: bounds.height)).setClip()

        drawNames(theme: theme)
        drawHandles(theme: theme)
        drawReorderFeedback(theme: theme)
    }

    /// 列名。**列の幅で切る**（隣へはみ出すと、どの名前がどの列か分からなくなる）。
    /// 並べ替え中は掴み元の列を薄く見せて「持ち上げている」ことを示す。
    private func drawNames(theme: EditorColorTheme) {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        for (i, col) in columns.enumerated() {
            let x = viewX(ofColumn: col.start)
            let w = CGFloat(col.width) * columnWidth
            guard x + w > 0, x < bounds.width else { continue }   // 画面外は描かない
            let alpha: CGFloat = (i == reorderSourceIndex) ? 0.35 : 1.0
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: theme.chromeSecondaryText.withAlphaComponent(alpha),
            ]
            let name = TabularFormatter.pad(col.name, to: col.width)
            NSAttributedString(string: name, attributes: attrs)
                .draw(in: NSRect(x: x, y: 3, width: w, height: bounds.height - 5))
        }
    }

    /// 並べ替え中、挿入先を示す縦線。**resize のプレビュー線とは別スタイル**
    /// （太い実線＋アクセント色）にして、「境界を動かす」のか「列ごと差し込む」のか区別する。
    private func drawReorderFeedback(theme: EditorColorTheme) {
        guard reorderSourceIndex != nil, let target = reorderTargetIndex,
              columns.indices.contains(target) else { return }
        let col = columns[target]
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        let x = floor(viewX(ofColumn: col.start)) + 0.5
        path.move(to: NSPoint(x: x, y: 0))
        path.line(to: NSPoint(x: x, y: bounds.height))
        path.stroke()
    }

    /// 列の境界（掴み手）。引きずっている間はその位置に濃い線を出す。
    private func drawHandles(theme: EditorColorTheme) {
        theme.separator.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for col in handleColumns {
            let x = floor(viewX(ofColumn: col)) + 0.5
            path.move(to: NSPoint(x: x, y: 2))
            path.line(to: NSPoint(x: x, y: bounds.height - 2))
        }
        path.stroke()

        guard let preview = draggingColumn else { return }
        theme.columnGuide(alpha: 0.9).setStroke()
        let live = NSBezierPath()
        live.lineWidth = 2
        let x = floor(viewX(ofColumn: preview)) + 0.5
        live.move(to: NSPoint(x: x, y: 0))
        live.line(to: NSPoint(x: x, y: bounds.height))
        live.stroke()
    }

    // MARK: - 操作

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.x >= contentInset else { return }
        let col = column(atViewX: p.x)
        // 一番近い掴み手（許容 1 桁）。境界を掴んだら resize、外れたら並べ替えを試す
        // （2 つのジェスチャーは排他 ── 境界が先勝ち）。
        let hit = handleColumns.enumerated()
            .filter { abs($0.element - col) <= hitTolerance }
            .min { abs($0.element - col) < abs($1.element - col) }
        if let hit {
            draggingIndex = hit.offset
            draggingColumn = hit.element
            needsDisplay = true
            return
        }
        guard allowsReorder, let index = columnIndex(atViewX: p.x) else { return }
        reorderSourceIndex = index
        reorderTargetIndex = index
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if draggingIndex != nil {
            let col = column(atViewX: max(contentInset, p.x))
            guard col != draggingColumn else { return }
            draggingColumn = col          // 線を動かすだけ。本文はまだ組み直さない。
            needsDisplay = true
            return
        }
        guard reorderSourceIndex != nil else { return }
        guard let target = columnIndex(atViewX: max(contentInset, p.x)), target != reorderTargetIndex else { return }
        reorderTargetIndex = target        // 挿入先の線を動かすだけ。本文はまだ組み直さない。
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if draggingIndex != nil {
            defer { draggingIndex = nil; draggingColumn = nil; needsDisplay = true }
            guard let index = draggingIndex, let to = draggingColumn,
                  columns.indices.contains(index) else { return }
            let width = max(TabularFormatter.minColumnWidth,
                            min(to - columns[index].start, TabularFormatter.maxColumnWidth))
            guard width != columns[index].width else { return }
            onResize?(index, width)
            return
        }
        defer { reorderSourceIndex = nil; reorderTargetIndex = nil; needsDisplay = true }
        guard let from = reorderSourceIndex, let to = reorderTargetIndex, from != to else { return }
        onReorder?(from, to)
    }

    override func resetCursorRects() {
        for col in handleColumns {
            let x = viewX(ofColumn: col)
            guard x >= contentInset else { continue }
            addCursorRect(NSRect(x: x - 3, y: 0, width: 6, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }
}
