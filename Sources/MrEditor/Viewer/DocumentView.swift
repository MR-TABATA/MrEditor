import AppKit

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

    /// 入力イベントを LargeFileViewer へ転送するためのフック。
    var onScrollWheel: ((NSEvent) -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?
    var onCopy: (() -> Void)?

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
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?(event)
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    /// 標準のコピー（⌘C）。可視範囲を LargeFileViewer 経由でクリップボードへ。
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }
}
