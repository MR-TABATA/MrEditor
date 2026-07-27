import Foundation

/// 不可視文字の可視化に使う記号と、1 行のどこに何を描くかの算出（純ロジック・UI 非依存）。
///
/// 両ペイン（`DocumentView` の自前描画と `EditorTextView` の NSTextView 描画）が
/// 同じ結果を使うので、見た目が一致する。**本文は書き換えない**（記号は重ねて描くだけ）。
/// タブを "→" に置換してしまうと桁揃えもキャレットのバイト対応も壊れるため。
///
/// 半角スペースは全部に点を打つと本文が読めなくなるので**行末の連なりだけ**出す
/// （消し忘れの行末空白は見えて嬉しい情報、文中の空白はノイズ）。全角スペースは
/// 日本語ファーストの要なので位置に関係なく出す。
enum InvisibleGlyphs {
    static let tab = "→"
    static let eol = "¬"
    static let ideographicSpace = "□"
    static let trailingSpace = "·"

    /// 行内のどの UTF-16 位置にどの記号を描くか。
    struct Marker: Equatable {
        /// 行文字列内の UTF-16 オフセット（その文字の**上に**記号を描く）。
        let utf16Index: Int
        let glyph: String
    }

    /// 1 行の文字列（改行を含まない）から記号の並びを返す。改行記号は行末に別途描くので含めない。
    static func markers(in line: String) -> [Marker] {
        let ns = line as NSString
        guard ns.length > 0 else { return [] }

        // 行末の半角スペースの連なり（この位置以降のスペースだけ点を打つ）。
        var trailingStart = ns.length
        while trailingStart > 0, ns.character(at: trailingStart - 1) == 0x0020 { trailingStart -= 1 }

        var out: [Marker] = []
        for i in 0..<ns.length {
            switch ns.character(at: i) {
            case 0x0009: out.append(Marker(utf16Index: i, glyph: tab))
            case 0x3000: out.append(Marker(utf16Index: i, glyph: ideographicSpace))
            case 0x0020 where i >= trailingStart: out.append(Marker(utf16Index: i, glyph: trailingSpace))
            default: break
            }
        }
        return out
    }
}
