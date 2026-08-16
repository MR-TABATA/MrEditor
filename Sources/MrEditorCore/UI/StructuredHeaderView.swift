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

    /// 掴み手の当たり判定（桁）。細い線をピクセル単位で狙わせない。
    private let hitTolerance = 1

    /// 掴んでいる列と、いまの引きずり先の桁（プレビュー線を出すためだけに持つ）。
    private var draggingIndex: Int?
    private var draggingColumn: Int?

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
    }

    /// 列名。**列の幅で切る**（隣へはみ出すと、どの名前がどの列か分からなくなる）。
    private func drawNames(theme: EditorColorTheme) {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.chromeSecondaryText]
        for col in columns {
            let x = viewX(ofColumn: col.start)
            let w = CGFloat(col.width) * columnWidth
            guard x + w > 0, x < bounds.width else { continue }   // 画面外は描かない
            let name = TabularFormatter.pad(col.name, to: col.width)
            NSAttributedString(string: name, attributes: attrs)
                .draw(in: NSRect(x: x, y: 3, width: w, height: bounds.height - 5))
        }
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
        // 一番近い掴み手（許容 1 桁）。
        let hit = handleColumns.enumerated()
            .filter { abs($0.element - col) <= hitTolerance }
            .min { abs($0.element - col) < abs($1.element - col) }
        guard let hit else { return }
        draggingIndex = hit.offset
        draggingColumn = hit.element
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingIndex != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let col = column(atViewX: max(contentInset, p.x))
        guard col != draggingColumn else { return }
        draggingColumn = col          // 線を動かすだけ。本文はまだ組み直さない。
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { draggingIndex = nil; draggingColumn = nil; needsDisplay = true }
        guard let index = draggingIndex, let to = draggingColumn,
              columns.indices.contains(index) else { return }
        let width = max(TabularFormatter.minColumnWidth,
                        min(to - columns[index].start, TabularFormatter.maxColumnWidth))
        guard width != columns[index].width else { return }
        onResize?(index, width)
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
