import AppKit

/// 左右のカラムの間に立つ、マージ用の帯。
///
/// 差分の塊（ハンク）ごとに **→** を描き、**クリックで右を取り込む**。もう一度押すと取り消す。
/// キーボード（⌥→）だけでは誰も気づかないので、押せるものを目に見える場所に置く。
/// FileMerge や Beyond Compare と同じ形。
final class MergeGutter: NSView {

    /// 可視行ごとの状態。上から順に並ぶ（`DiffViewer.refresh` が組む）。
    struct Row {
        /// この行が属するハンク（op 添字）。差分でない行は nil。
        ///
        /// **先頭行だけでなく、ハンクの全行に入れる。** 矢印は先頭にしか描かないが、
        /// クリックはハンクのどの行でも受ける ―― 先頭行(14pt)しか押せないと、
        /// 人間の指では外れる（実際、矢印の下寄りを押すと無反応だった）。
        let hunkOp: Int?
        /// この行がハンクの先頭か（矢印を描く行）。
        let isHead: Bool
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

    /// 矢印の大きさ。**行からはみ出させない** ―― はみ出すと、はみ出した部分を押しても
    /// 隣の行と判定されて無反応になる（実際にそれで「押しても何も変わらない」と言われた）。
    private var markSize: CGFloat { min(16, max(10, lineHeight - 2)) }

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
            guard row.isHead else { continue }
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

    /// 差分の行の上ではポインタを指の形にする（押せると分かるように）。
    override func resetCursorRects() {
        discardCursorRects()
        for (i, row) in rows.enumerated() where row.hunkOp != nil {
            let y = CGFloat(i) * lineHeight
            addCursorRect(NSRect(x: 0, y: y, width: bounds.width, height: lineHeight),
                          cursor: .pointingHand)
        }
    }

    // MARK: - アクセシビリティ

    /// 矢印を**本物のボタンとして公開する**。
    ///
    /// VoiceOver から押せるようになる（実利）。同時に、E2E テストが**座標に頼らず**
    /// 名前で押せるようになる ―― 座標クリックの検証は、ウィンドウ位置が 4pt ずれた
    /// だけで嘘の結果を出す（実際に 4 回続けて騙された）。
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityChildren() -> [Any]? {
        rows.enumerated().compactMap { i, row -> MergeArrowElement? in
            guard row.isHead, let op = row.hunkOp else { return nil }
            let e = MergeArrowElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.button)
            e.setAccessibilityLabel(L(row.adopted ? "diff.a11y.undo" : "diff.a11y.take"))
            e.setAccessibilityIdentifier("merge-arrow-\(op)")
            e.setAccessibilityFrameInParentSpace(
                NSRect(x: 0, y: CGFloat(i) * lineHeight, width: bounds.width, height: lineHeight))
            e.onPress = { [weak self] in self?.onToggle?(op) }
            return e
        }
    }
}

/// ガターの矢印 1 つ。押せる（VoiceOver / E2E から）。
final class MergeArrowElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
