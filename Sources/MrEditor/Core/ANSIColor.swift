import AppKit

/// ANSI SGR（Select Graphic Rendition）エスケープの解釈に使う 16 色パレット＋既定 fg/bg。
/// 標準色は xterm 準拠の固定色。既定 fg/bg は現在のテーマ色を渡して受け取る（どのテーマでも自然に見せる）。
struct ANSIPalette {
    /// 通常 8 色（0–7）＋高輝度 8 色（8–15）。index は SGR の色番号に対応。
    var colors: [NSColor]
    var defaultForeground: NSColor
    var defaultBackground: NSColor

    /// 現在のテーマ（本文 fg/bg）から既定色を取り、標準 16 色は xterm 固定で組む。
    static func from(theme: EditorColorTheme) -> ANSIPalette {
        ANSIPalette(colors: xterm16, defaultForeground: theme.foreground, defaultBackground: theme.background)
    }

    /// xterm の標準 16 色（0=black … 7=white、8–15＝高輝度）。
    static let xterm16: [NSColor] = [
        hex(0x000000), hex(0xCD0000), hex(0x00CD00), hex(0xCDCD00),
        hex(0x0000EE), hex(0xCD00CD), hex(0x00CDCD), hex(0xE5E5E5),
        hex(0x7F7F7F), hex(0xFF0000), hex(0x00FF00), hex(0xFFFF00),
        hex(0x5C5CFF), hex(0xFF00FF), hex(0x00FFFF), hex(0xFFFFFF),
    ]

    /// xterm 256 色パレットの n 番目（16–231＝6×6×6 立方、232–255＝グレースケール）。
    func color256(_ n: Int) -> NSColor {
        if n < 16 { return colors[n] }
        if n >= 232 {
            let v = CGFloat(8 + (n - 232) * 10) / 255
            return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        }
        let i = n - 16
        let r = i / 36, g = (i / 6) % 6, b = i % 6
        func c(_ x: Int) -> CGFloat { x == 0 ? 0 : CGFloat(55 + x * 40) / 255 }
        return NSColor(srgbRed: c(r), green: c(g), blue: c(b), alpha: 1)
    }

    private static func hex(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// ANSI SGR エスケープを解釈し、色付き `NSAttributedString` と、エスケープ除去後のプレーン文字列を返す。
enum ANSIColor {
    /// 1 行（改行を含まない前提）を走査する。エスケープが 1 つも無ければ `nil`（呼び出し側は従来経路へ）。
    /// - `base`: フォント/段落スタイル等のベース属性（fg は SGR が上書きする）。
    /// - 戻り値 `plain` はエスケープ除去後の可視テキスト（検索ハイライトのレンジ計算用）。
    static func attributed(_ line: String, base: [NSAttributedString.Key: Any],
                           palette: ANSIPalette) -> (attributed: NSAttributedString, plain: String)? {
        // ESC(0x1B) が無ければ ANSI 対象外。
        guard line.utf8.contains(0x1B) else { return nil }

        let scalars = Array(line.unicodeScalars)
        let out = NSMutableAttributedString()
        var plain = String.UnicodeScalarView()
        var state = SGRState(palette: palette)
        var i = 0
        // 現在の run を貯めて、属性が変わる/終端でまとめて emit する。
        var run = String.UnicodeScalarView()

        func flushRun() {
            guard !run.isEmpty else { return }
            let s = String(run)
            out.append(NSAttributedString(string: s, attributes: state.attributes(base: base)))
            run = String.UnicodeScalarView()
        }

        while i < scalars.count {
            let sc = scalars[i]
            // CSI シーケンス: ESC '[' … （終端文字まで）。SGR('m') のみ解釈し、他は表示から除去。
            if sc.value == 0x1B, i + 1 < scalars.count, scalars[i + 1] == "[" {
                var j = i + 2
                var params = String.UnicodeScalarView()
                while j < scalars.count {
                    let c = scalars[j]
                    // 終端＝0x40–0x7E の最終バイト。
                    if c.value >= 0x40 && c.value <= 0x7E {
                        if c == "m" { flushRun(); state.apply(String(params)) }
                        // 'm' 以外の CSI（カーソル移動等）は表示から捨てる。
                        break
                    }
                    params.append(c)
                    j += 1
                }
                i = j + 1
                continue
            }
            // 裸の ESC やその他 C0 制御は表示に載せず読み飛ばす（ESC 単独など）。
            if sc.value == 0x1B { i += 1; continue }
            run.append(sc)
            plain.append(sc)
            i += 1
        }
        flushRun()
        return (out, String(plain))
    }

    /// SGR の現在状態（色・太字・斜体・下線）。`apply` で `1;31` 等のパラメータ列を反映する。
    /// 色は palette を持って即時に `NSColor` へ解決し、状態は次の SGR まで持ち越す。
    private struct SGRState {
        let palette: ANSIPalette
        var fg: NSColor?
        var bg: NSColor?
        var bold = false
        var italic = false
        var underline = false

        mutating func apply(_ params: String) {
            // 空（`ESC[m`）は reset 扱い。
            let parts = params.isEmpty ? ["0"] : params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            var k = 0
            while k < parts.count {
                let code = Int(parts[k]) ?? 0
                switch code {
                case 0: fg = nil; bg = nil; bold = false; italic = false; underline = false
                case 1: bold = true
                case 3: italic = true
                case 4: underline = true
                case 22: bold = false
                case 23: italic = false
                case 24: underline = false
                case 30...37: fg = palette.colors[code - 30]
                case 90...97: fg = palette.colors[code - 90 + 8]
                case 40...47: bg = palette.colors[code - 40]
                case 100...107: bg = palette.colors[code - 100 + 8]
                case 39: fg = nil
                case 49: bg = nil
                case 38, 48:                     // 拡張色: 38;5;n / 38;2;r;g;b（bg は 48）
                    let isFG = (code == 38)
                    if k + 1 < parts.count, parts[k + 1] == "5", k + 2 < parts.count {
                        let c = palette.color256(Int(parts[k + 2]) ?? 0)
                        if isFG { fg = c } else { bg = c }
                        k += 2
                    } else if k + 1 < parts.count, parts[k + 1] == "2", k + 4 < parts.count {
                        let r = Int(parts[k + 2]) ?? 0, g = Int(parts[k + 3]) ?? 0, b = Int(parts[k + 4]) ?? 0
                        let c = NSColor(srgbRed: CGFloat(min(255, r)) / 255, green: CGFloat(min(255, g)) / 255,
                                        blue: CGFloat(min(255, b)) / 255, alpha: 1)
                        if isFG { fg = c } else { bg = c }
                        k += 4
                    }
                default: break
                }
                k += 1
            }
        }

        func attributes(base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var attrs = base
            if let fg { attrs[.foregroundColor] = fg }
            if let bg { attrs[.backgroundColor] = bg }
            if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if bold || italic, let f = base[.font] as? NSFont {
                var traits: NSFontTraitMask = []
                if bold { traits.insert(.boldFontMask) }
                if italic { traits.insert(.italicFontMask) }
                attrs[.font] = NSFontManager.shared.convert(f, toHaveTrait: traits)
            }
            return attrs
        }
    }
}
