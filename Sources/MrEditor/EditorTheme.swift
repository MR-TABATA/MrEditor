import AppKit

/// 本文エリアの配色（5 色）と、周辺 UI（chrome）の配色をまとめたもの。
/// 大ファイル（`DocumentView` 自前描画）と小ファイル（`NSTextView`）の両経路、
/// 検索ヒット描画、およびサイドバー/ガター/ステータス/検索パネル/タイトルバーで同じ色を使う。
struct EditorColorTheme {
    // MARK: 本文エリア
    /// 本文の文字色。
    var foreground: NSColor
    /// 本文の背景色。
    var background: NSColor
    /// キャレット行を淡く強調する帯の色（alpha 付き）。
    var currentLine: NSColor
    /// 選択範囲の背景色。
    var selection: NSColor
    /// 検索ヒットの背景色（alpha 付き）。
    var searchMatch: NSColor

    // MARK: 周辺 UI（chrome）
    /// サイドバー/ガター/ステータス/検索パネル/タイトルバーの背景。
    var chromeBackground: NSColor
    /// サイドバー行など主要ラベルの文字色。
    var chromeText: NSColor
    /// ステータスバー・行番号など副次ラベルの文字色。
    var chromeSecondaryText: NSColor
    /// 選択中サイドバー行の背景。
    var chromeActiveBackground: NSColor
    /// 選択中サイドバー行のラベル色。
    var chromeActiveText: NSColor
    /// 区切り線の色。
    var separator: NSColor
    /// 未保存ドキュメントの目印色（サイドバーの●と×）。
    var dirtyIndicator: NSColor
    /// 窓に強制するアピアランス（framework コントロール/タイトル文字/スクロールバーの明暗を揃える）。
    /// nil＝OS 追従（system プリセット）。
    var appearanceName: NSAppearance.Name?
}

/// 配色プリセット。`system` はセマンティック色でライト/ダーク自動追従、
/// 固定プリセットは sRGB 固定色（追従しない）、`custom` はユーザ指定の 5 色。
enum ThemePreset: String, CaseIterable {
    case system
    case solarizedDark
    case solarizedLight
    case monokai
    case custom
}

/// エディタ本文＋周辺 UI の配色をグローバルに保持し永続化する。フォント（`EditorFont`）と同様に
/// UserDefaults へ保存し、変更は既存の `.mrEditorDisplayChanged` で全ビューア/ウィンドウへ通知する。
enum EditorTheme {
    private static let defaults = UserDefaults.standard
    private static let presetKey = "MrEditor.themePreset"
    /// custom 時の各色（NSKeyedArchiver で Data 化して alpha/colorspace を保つ）。
    private static let customPrefix = "MrEditor.themeCustom."

    /// custom 時にユーザが指定する色。本文 5 色＋未保存の目印色。周辺 UI 色はここから派生させる。
    enum ColorKey: String, CaseIterable {
        case foreground, background, currentLine, selection, searchMatch, dirtyIndicator
    }

    // MARK: - プリセット選択

    static var preset: ThemePreset {
        get { ThemePreset(rawValue: defaults.string(forKey: presetKey) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: presetKey); postChanged() }
    }

    // MARK: - 現在の配色

    /// 現在の配色。preset に応じて固定色／セマンティック色／custom 保存色を返す。
    static func current() -> EditorColorTheme {
        switch preset {
        case .custom: return customTheme()
        default:      return builtin(preset)
        }
    }

    /// プリセットの色定義（プレビュー用にも使う）。`custom` は現在の custom 保存色。
    static func builtin(_ preset: ThemePreset) -> EditorColorTheme {
        switch preset {
        case .system:
            // 既存ハードコード値と一致（既定で現状と完全一致・周辺 UI もセマンティックで自動追従）。
            return EditorColorTheme(
                foreground: .textColor,
                background: .textBackgroundColor,
                currentLine: NSColor.textColor.withAlphaComponent(0.06),
                selection: .selectedTextBackgroundColor,
                searchMatch: NSColor.systemYellow.withAlphaComponent(0.45),
                chromeBackground: .windowBackgroundColor,
                chromeText: .labelColor,
                chromeSecondaryText: .secondaryLabelColor,
                chromeActiveBackground: .selectedContentBackgroundColor,
                chromeActiveText: .white,
                separator: .separatorColor,
                dirtyIndicator: .systemOrange,
                appearanceName: nil)
        case .solarizedDark:
            return themed(fg: hex(0x93A1A1), bg: hex(0x002B36),
                          currentLine: hex(0xFFFFFF, 0.06), selection: hex(0x274642),
                          searchMatch: hex(0xB58900, 0.45), dirty: .systemOrange)
        case .solarizedLight:
            return themed(fg: hex(0x586E75), bg: hex(0xFDF6E3),
                          currentLine: hex(0x000000, 0.05), selection: hex(0xD6CFB8),
                          searchMatch: hex(0xB58900, 0.40), dirty: .systemOrange)
        case .monokai:
            return themed(fg: hex(0xF8F8F2), bg: hex(0x272822),
                          currentLine: hex(0xFFFFFF, 0.06), selection: hex(0x49483E),
                          searchMatch: hex(0xE6DB74, 0.40), dirty: .systemOrange)
        case .custom:
            return customTheme()
        }
    }

    // MARK: - カスタム色

    /// custom の 1 色を設定し、preset を `.custom` に切り替えて通知する。
    static func setCustomColor(_ key: ColorKey, _ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
            defaults.set(data, forKey: customPrefix + key.rawValue)
        }
        // custom へ切り替え（postChanged はここで一度だけ）。
        defaults.set(ThemePreset.custom.rawValue, forKey: presetKey)
        postChanged()
    }

    /// custom の 1 色を読む。未設定なら system プリセットの対応色にフォールバック。
    static func customColor(_ key: ColorKey) -> NSColor {
        if let data = defaults.data(forKey: customPrefix + key.rawValue),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        let sys = builtin(.system)
        switch key {
        case .foreground:    return sys.foreground
        case .background:    return sys.background
        case .currentLine:   return sys.currentLine
        case .selection:     return sys.selection
        case .searchMatch:   return sys.searchMatch
        case .dirtyIndicator: return sys.dirtyIndicator
        }
    }

    private static func customTheme() -> EditorColorTheme {
        themed(fg: customColor(.foreground), bg: customColor(.background),
               currentLine: customColor(.currentLine), selection: customColor(.selection),
               searchMatch: customColor(.searchMatch), dirty: customColor(.dirtyIndicator))
    }

    // MARK: - 周辺 UI 色の派生

    /// 本文 5 色から周辺 UI（chrome）色を派生させてテーマを組み立てる。
    /// chrome は前景と背景の混色で作るため、ダーク系は自然に少し明るく、ライト系は少し暗くなる。
    private static func themed(fg: NSColor, bg: NSColor, currentLine: NSColor,
                              selection: NSColor, searchMatch: NSColor, dirty: NSColor) -> EditorColorTheme {
        let bgS = bg.usingColorSpace(.sRGB) ?? bg
        let fgS = fg.usingColorSpace(.sRGB) ?? fg
        func blend(_ t: CGFloat) -> NSColor { mix(bgS, fgS, t) }
        // 相対輝度（sRGB 近似）で明暗を判定し、窓アピアランスを決める。
        let lum = 0.2126 * bgS.redComponent + 0.7152 * bgS.greenComponent + 0.0722 * bgS.blueComponent
        return EditorColorTheme(
            foreground: fg, background: bg,
            currentLine: currentLine, selection: selection, searchMatch: searchMatch,
            // 本文（メイン）から明確に濃淡を付けるため、chrome は前景寄りに 0.14 混色する。
            chromeBackground: blend(0.14),
            chromeText: blend(0.90),
            chromeSecondaryText: blend(0.58),
            chromeActiveBackground: blend(0.28),
            chromeActiveText: blend(0.98),
            separator: blend(0.26),
            dirtyIndicator: dirty,
            appearanceName: lum < 0.5 ? .darkAqua : .aqua)
    }

    /// 2 色を成分ごとに t で線形補間（alpha は 1 固定）。
    private static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                alpha: 1.0)
    }

    // MARK: - ヘルパ

    private static func hex(_ rgb: Int, _ alpha: CGFloat = 1.0) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: alpha)
    }

    private static func postChanged() {
        NotificationCenter.default.post(name: .mrEditorDisplayChanged, object: nil)
    }
}
