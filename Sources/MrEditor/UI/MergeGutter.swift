import AppKit

/// 左右のカラムの間に立つ、マージ用の帯。
///
/// 差分の塊（ハンク）ごとに **→** を描き、**クリックで右を取り込む**。もう一度押すと取り消す。
/// キーボード（⌥→）だけでは誰も気づかないので、押せるものを目に見える場所に置く。
/// FileMerge や Beyond Compare と同じ形。
final class MergeGutter: NSView {

    /// 可視行ごとの状態。上から順に並ぶ（`DiffViewer.refresh` が組む）。
    struct Row {
        /// この行がハンクの**先頭**なら、その op 添字。先頭でなければ nil（矢印は先頭にだけ描く）。
        let hunkOp: Int?
        /// そのハンクを採用済みか。
        let adopted: Bool
        /// いま選んでいるハンクか。
        let current: Bool
    }

    var rows: [Row] = [] { didSet { needsDisplay = true } }
    var lineHeight: CGFloat = 16 { didSet { needsDisplay = true } }

    /// 矢印が押されたときに呼ばれる（op 添字を渡す）。
    var onToggle: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    /// 非アクティブなウィンドウでも、最初のクリックで矢印が効くようにする。
    ///
    /// 既定では、非キーウィンドウへの最初のクリックは「窓を前面に出す」だけで消える。
    /// 他のアプリから戻ってきて矢印を押した人には**何も起きない**ように見える
    /// （実際にそれで検証が 4 回失敗した）。取り込みは 1 クリックで済むべき操作。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let markSize: CGFloat = 16

    private var background: NSColor { EditorTheme.current().chromeBackground }
    private var separator: NSColor { EditorTheme.current().separator }
    private var arrowIdle: NSColor { NSColor.secondaryLabelColor }
    private var arrowCurrent: NSColor { NSColor.systemTeal }
    private var arrowAdopted: NSColor { NSColor.systemBlue }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.intersection(bounds).fill()

        separator.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0.5, y: 0))
        line.line(to: NSPoint(x: 0.5, y: bounds.height))
        line.move(to: NSPoint(x: bounds.width - 0.5, y: 0))
        line.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.height))
        line.stroke()

        for (i, row) in rows.enumerated() {
            guard row.hunkOp != nil else { continue }
            let y = CGFloat(i) * lineHeight
            let rect = NSRect(x: (bounds.width - markSize) / 2,
                              y: y + (lineHeight - markSize) / 2,
                              width: markSize, height: markSize)
            drawArrow(in: rect, adopted: row.adopted, current: row.current)
        }
    }

    /// 採用済みは塗りつぶし、未採用は輪郭だけ。選んでいるハンクは色を変える。
    private func drawArrow(in rect: NSRect, adopted: Bool, current: Bool) {
        let color = adopted ? arrowAdopted : (current ? arrowCurrent : arrowIdle)
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        if adopted {
            color.setFill()
            circle.fill()
        } else {
            color.withAlphaComponent(current ? 0.9 : 0.45).setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
        }

        // → の形。採用済みは白抜き。
        let arrow = NSBezierPath()
        let mid = rect.midY
        let x0 = rect.minX + 4.5, x1 = rect.maxX - 4.5
        arrow.move(to: NSPoint(x: x0, y: mid))
        arrow.line(to: NSPoint(x: x1, y: mid))
        arrow.move(to: NSPoint(x: x1 - 3.5, y: mid - 3.5))
        arrow.line(to: NSPoint(x: x1, y: mid))
        arrow.line(to: NSPoint(x: x1 - 3.5, y: mid + 3.5))
        arrow.lineWidth = 1.4
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        (adopted ? NSColor.white : color.withAlphaComponent(current ? 1.0 : 0.6)).setStroke()
        arrow.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.y / max(1, lineHeight))
        guard i >= 0, i < rows.count, let op = rows[i].hunkOp else { return }
        onToggle?(op)
    }

    /// 矢印の上ではポインタを指の形にする（押せると分かるように）。
    override func resetCursorRects() {
        discardCursorRects()
        for (i, row) in rows.enumerated() where row.hunkOp != nil {
            let y = CGFloat(i) * lineHeight
            addCursorRect(NSRect(x: 0, y: y, width: bounds.width, height: lineHeight),
                          cursor: .pointingHand)
        }
    }
}
