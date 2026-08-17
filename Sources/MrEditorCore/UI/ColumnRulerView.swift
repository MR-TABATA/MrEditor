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
    /// 項目定義をいじれるか。**構造化表示中は false**——整形後の表示では画面の桁と
    /// 定義の桁が別物なので、印を出すのも掴ませるのも嘘になる（目盛りは表示の桁として有効）。
    var guidesEditable = true { didSet { if guidesEditable != oldValue { needsDisplay = true } } }
    /// キャレットのある桁（1 始まり）。nil なら強調しない。
    var currentColumn: Int? { didSet { if currentColumn != oldValue { needsDisplay = true } } }
    /// キャレットのいる項目の桁範囲。**Tab で項目を渡ったことが、ここで分かる。**
    var currentField: ClosedRange<Int>? { didSet { if currentField != oldValue { needsDisplay = true } } }
    /// 右端に出す一言（`⌥Tab で 2 行目以降も揃います`）。**押す物ではなく、ただの文字。**
    /// ボタンやアイコンは気づかれない一方、ここに文が出ていれば読める。
    /// nil で消える——**揃え終わったら消す**（出しっぱなしは景色になって読まれない）。
    var hint: String? { didSet { if hint != oldValue { needsDisplay = true } } }
    /// 選択の桁範囲（1 始まり・閉区間）。nil なら帯を出さない。
    var selectedColumns: ClosedRange<Int>? { didSet { if selectedColumns != oldValue { needsDisplay = true } } }

    /// ルーラーをクリックしてガイドを足す／消す。
    var onToggleGuide: ((Int) -> Void)?
    /// ガイドを掴んで動かす（from, to）。動かせたら true を返すこと（行き先が埋まっていたら false）。
    var onMoveGuide: ((Int, Int) -> Bool)?
    /// ガイドを動かし終えたとき（離した時）。**引きずっている間は呼ばない**——
    /// 1 桁ごとに全行を組み直すと、数千行で指に付いてこなくなる。
    var onGuideDragEnded: (() -> Void)?

    /// 数字ラベルの当たり判定を緩める許容幅（桁）。細い線をピクセル単位で狙わせない。
    private let hitTolerance = 1

    /// 掴んでいるガイドの桁（ドラッグ中のみ）。
    private var draggingColumn: Int?
    /// 掴んだのが**既にあったガイド**か（そうでなければ mouseDown で足したばかり）。
    private var draggingExisting = false
    /// 掴んでから 1 桁でも動いたか（動かなければクリック＝トグル）。
    private var didDrag = false

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

    /// 案内文が占める幅（目盛りをそのぶん手前で止める）。
    private func hintTextWidth() -> CGFloat {
        guard let hint, !hint.isEmpty else { return 0 }
        let size = NSAttributedString(string: hint,
                                      attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).size()
        return size.width + 14
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

        // 案内文は**クリップを掛ける前**に描く。目盛り用のクリップは右端を空けてあるので、
        // 後から描くと自分で切り落とすことになる（実際に消えていた）。
        drawHint(theme: theme)

        // 本文が始まる位置より左（ガターの上）には目盛りを描かない。
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let hintWidth = hintTextWidth()
        NSBezierPath(rect: NSRect(x: contentInset, y: 0,
                                  width: max(0, bounds.width - contentInset - hintWidth),
                                  height: bounds.height)).setClip()

        // 選択の桁範囲（帯）。目盛りより下に敷く。
        if let sel = selectedColumns {
            let x0 = viewX(ofColumn: sel.lowerBound)
            let x1 = viewX(ofColumn: sel.upperBound + 1)
            theme.selection.setFill()
            NSRect(x: x0, y: 0, width: max(1, x1 - x0), height: bounds.height - 1).fill()
        }

        // キャレットのいる項目（帯＋桁範囲の名前）。キャレット桁より先に敷く。
        if let field = currentField {
            let x0 = viewX(ofColumn: field.lowerBound)
            let x1 = viewX(ofColumn: field.upperBound + 1)
            theme.currentLine.setFill()
            NSRect(x: x0, y: 0, width: max(1, x1 - x0), height: bounds.height - 1).fill()

            // 幅が足りるときだけ「9-14」と出す（詰まっているなら帯だけで十分）。
            let name = "\(field.lowerBound)-\(field.upperBound)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: theme.chromeSecondaryText,
            ]
            let label = NSAttributedString(string: name, attributes: attrs)
            let size = label.size()
            if size.width + 6 <= x1 - x0 {
                label.draw(at: NSPoint(x: x0 + ((x1 - x0) - size.width) / 2,
                                       y: max(0, (bounds.height - 6 - size.height) / 2)))
            }
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

    /// 右端の一言。目盛りより後に描く（クリップの外なので数字とは重ならない）。
    private func drawHint(theme: EditorColorTheme) {
        guard let hint, !hint.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: theme.chromeSecondaryText,
        ]
        let text = NSAttributedString(string: hint, attributes: attrs)
        let size = text.size()
        let x = bounds.width - size.width - 8
        guard x > contentInset else { return }        // 狭い窓では出さない（目盛りを潰さない）
        text.draw(at: NSPoint(x: x, y: max(0, (bounds.height - size.height) / 2)))
    }

    private func drawGuideMarkers(theme: EditorColorTheme) {
        guard !guides.isEmpty, guidesEditable else { return }
        theme.columnGuide(alpha: 0.85).setFill()
        for col in guides.columns {
            let x = floor(viewX(ofColumn: col))
            // 掴みやすいよう、線そのものより太い印を出す。
            NSRect(x: x - 1, y: 1, width: 3, height: bounds.height - 3).fill()
        }
    }

    // MARK: - 操作

    /// クリックで置く／消す、掴んで動かす。
    ///
    /// **1 桁ずらすのに「消して置き直す」をさせない。** 既にあるガイドの上で押したら
    /// そのまま掴んだ状態にし、動かさずに離したときだけ消す。何も無い所で押したら
    /// その場で 1 本置き、**そのまま続けて動かせる**（置いてから微調整、が 1 操作で済む）。
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard guidesEditable, p.x >= contentInset else { return }
        let col = column(atViewX: p.x)
        didDrag = false
        if let hit = guides.nearest(to: col, within: hitTolerance) {
            draggingColumn = hit
            draggingExisting = true
        } else {
            draggingColumn = col
            draggingExisting = false
            onToggleGuide?(col)      // 置くのは押した時点（動かすなら続けてドラッグ）
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = draggingColumn else { return }
        let p = convert(event.locationInWindow, from: nil)
        let to = column(atViewX: max(contentInset, p.x))
        guard to != from else { return }
        if onMoveGuide?(from, to) == true {
            draggingColumn = to
            didDrag = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { draggingColumn = nil; draggingExisting = false; didDrag = false }
        if didDrag { onGuideDragEnded?(); return }
        guard let col = draggingColumn, draggingExisting else { return }
        // 離した場所が押した桁と違うなら、途中の drag イベントが届かなかっただけ＝動かす。
        // ここを見ずに消すと、素早く掴んで動かしたときにガイドが消える。
        let p = convert(event.locationInWindow, from: nil)
        let to = column(atViewX: max(contentInset, p.x))
        if to != col, onMoveGuide?(col, to) == true { onGuideDragEnded?(); return }
        onToggleGuide?(col)          // 既にあるガイドを動かさず離した＝消す
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: contentInset, y: 0,
                             width: max(0, bounds.width - contentInset), height: bounds.height),
                      cursor: .crosshair)
    }
}
