import AppKit

/// 本文の体裁（タブ幅・行間）をフォントと設定から導出する共通ヘルパ。
/// 大ファイル（`DocumentView`/`LineLayout`）と小ファイル（`NSTextView`）の
/// 両経路で同じ段落スタイル・行高を使い、見た目を一致させる。
enum EditorStyle {

    /// 現在のフォント・設定に基づく段落スタイル（タブ幅と行高を含む）。
    /// `minimum/maximumLineHeight` を等しく固定して、折り返しの各サブ行も
    /// 単一行と同じ行高になるようにする（`DocumentView.lineHeight` と一致）。
    static func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let tab = tabInterval(for: font)
        p.defaultTabInterval = tab
        p.tabStops = []                       // 等間隔タブに統一（既定の 8 個のタブストップを消す）
        let h = lineHeight(for: font)
        p.minimumLineHeight = h
        p.maximumLineHeight = h
        return p
    }

    /// 1 行あたりの高さ（行間倍率込み・整数 px）。
    static func lineHeight(for font: NSFont) -> CGFloat {
        let lm = NSLayoutManager()
        let base = lm.defaultLineHeight(for: font)
        return ceil(base * AppSettings.lineSpacing.multiplier)
    }

    /// タブ 1 個分の幅（`tabWidth` 文字ぶんの半角スペース幅）。
    static func tabInterval(for font: NSFont) -> CGFloat {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        return space * CGFloat(AppSettings.tabWidth)
    }

    /// ブロックカーソルの幅（等幅 1 文字ぶん）。
    static func caretWidth(for font: NSFont) -> CGFloat {
        let w = ("0" as NSString).size(withAttributes: [.font: font]).width
        return w > 0 ? w : max(2, font.pointSize * 0.6)
    }
}
