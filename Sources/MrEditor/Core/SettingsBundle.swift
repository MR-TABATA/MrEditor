import AppKit

/// 外観プロファイル（テーマ・配色・フォント・本文体裁）を 1 つに束ね、
/// ファイル書き出し／読み込みと共有 URL（`mreditor://theme?d=…`）でやり取りするための値型。
///
/// **束ねるのは「見た目」だけ**：テーマ preset・custom 6 色・フォント種別/サイズ・タブ幅・
/// 行間・現在行ハイライト・カーソル形状・長い行の折り返し。セッション（開いていたファイル）や
/// 更新チェック・保存進捗の見せ方といった「見た目でない」設定は**意図的に含めない**
/// （他人の環境を丸ごと上書きしないため）。
///
/// 共有 URL はバックエンドを持たず**自己完結**する（設定を base64url で URL に埋める）。
/// カスタムスキーム `mreditor://` は `Info.plist` の `CFBundleURLTypes` で登録し、
/// `application(_:open:)` が受けて確認のうえ適用する。
struct SettingsBundle: Codable, Equatable {
    /// スキーマ版数。将来フィールドが増えても古い版を安全に読めるように持つ。
    static let currentVersion = 1
    /// 共有 URL のスキーム／ホスト。
    static let urlScheme = "mreditor"
    static let urlHost = "theme"
    /// クエリキー（設定本体を base64url で載せる）。
    static let urlDataKey = "d"
    /// ファイル書き出しの拡張子（中身は素の JSON）。
    static let fileExtension = "mreditortheme"

    var version: Int
    /// `ThemePreset.rawValue`。未知の値は読み込み時に `.system` へ丸める。
    var themePreset: String
    /// `EditorTheme.ColorKey.rawValue` → "RRGGBBAA"（sRGB・alpha 込み 8 桁）。
    var customColors: [String: String]
    /// フォント種別（nil＝システム既定の等幅）。
    var fontName: String?
    var fontSize: Double
    var tabWidth: Int
    /// `LineSpacing.rawValue`。
    var lineSpacing: String
    var highlightCurrentLine: Bool
    /// `CursorShape.rawValue`。
    var cursorShape: String
    var lineWrap: Bool
    /// 背景の不透明度（0.30–1.00）。旧版の共有リンクには無いので optional。
    var backgroundOpacity: Double?
    /// ANSI カラー表示（閲覧時）。旧版の共有リンクには無いので optional。
    var ansiColors: Bool?

    enum DecodeError: Error, Equatable {
        case malformed          // JSON/base64 が壊れている
        case unsupportedVersion // 未来の版
        case wrongScheme        // URL のスキーム／ホストが違う
        case missingData        // URL にデータが無い
    }

    // MARK: - 現在値の取り込み

    /// 現在のグローバル設定から束を作る。
    static func capture() -> SettingsBundle {
        var colors: [String: String] = [:]
        for key in EditorTheme.ColorKey.allCases {
            colors[key.rawValue] = hexString(EditorTheme.customColor(key))
        }
        return SettingsBundle(
            version: currentVersion,
            themePreset: EditorTheme.preset.rawValue,
            customColors: colors,
            fontName: EditorFont.currentName,
            fontSize: Double(EditorFont.currentSize),
            tabWidth: AppSettings.tabWidth,
            lineSpacing: AppSettings.lineSpacing.rawValue,
            highlightCurrentLine: AppSettings.highlightCurrentLine,
            cursorShape: AppSettings.cursorShape.rawValue,
            lineWrap: AppSettings.lineWrap,
            backgroundOpacity: Double(EditorTheme.backgroundOpacity),
            ansiColors: EditorTheme.ansiColorsEnabled)
    }

    // MARK: - 適用

    /// この束をグローバル設定へ書き込む（各設定の既存 setter 経由なので通知も飛ぶ）。
    /// custom 色を先に入れると preset が一旦 `.custom` に倒れるため、**preset は最後に確定**する。
    func apply() {
        // フォント
        EditorFont.setName(fontName)
        EditorFont.setSize(CGFloat(fontSize))
        // 本文体裁
        AppSettings.tabWidth = tabWidth
        AppSettings.lineSpacing = LineSpacing(rawValue: lineSpacing) ?? .standard
        AppSettings.highlightCurrentLine = highlightCurrentLine
        AppSettings.cursorShape = CursorShape(rawValue: cursorShape) ?? .bar
        AppSettings.lineWrap = lineWrap
        if let backgroundOpacity { EditorTheme.backgroundOpacity = CGFloat(backgroundOpacity) }
        if let ansiColors { EditorTheme.ansiColorsEnabled = ansiColors }
        // 配色（custom 色 → preset の順で確定）
        for key in EditorTheme.ColorKey.allCases {
            if let hex = customColors[key.rawValue], let color = SettingsBundle.color(fromHex: hex) {
                EditorTheme.setCustomColor(key, color)   // preset を .custom に倒す
            }
        }
        EditorTheme.preset = ThemePreset(rawValue: themePreset) ?? .system
    }

    /// 適用したときに変わる主な項目（確認シート用の短い説明）。ローカライズ済みテーマ名を含む。
    func summaryLines() -> [String] {
        let themeName = L("prefs.theme.\(themePreset)")
        let fontDesc = (fontName ?? L("prefs.font.system")) + "  \(Int(fontSize)) pt"
        return ["\(L("prefs.theme")): \(themeName)",
                "\(L("prefs.font")): \(fontDesc)"]
    }

    // MARK: - シリアライズ

    /// JSON へ符号化（ファイル書き出し用の生バイト）。
    func jsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// JSON バイトから復元。版数と妥当性を検証する。
    static func decode(fromJSON data: Data) throws -> SettingsBundle {
        guard let bundle = try? JSONDecoder().decode(SettingsBundle.self, from: data) else {
            throw DecodeError.malformed
        }
        guard bundle.version <= currentVersion else { throw DecodeError.unsupportedVersion }
        return bundle
    }

    /// 設定を base64url 文字列へ（URL に埋める携行形）。
    func encodedString() -> String {
        base64url(jsonData())
    }

    /// base64url 文字列から復元。
    static func decode(fromEncoded string: String) throws -> SettingsBundle {
        guard let data = dataFromBase64url(string) else { throw DecodeError.malformed }
        return try decode(fromJSON: data)
    }

    // MARK: - 共有 URL

    /// 共有 URL（`mreditor://theme?d=<base64url>`）を作る。
    func shareURL() -> URL {
        var comps = URLComponents()
        comps.scheme = SettingsBundle.urlScheme
        comps.host = SettingsBundle.urlHost
        comps.queryItems = [URLQueryItem(name: SettingsBundle.urlDataKey, value: encodedString())]
        return comps.url!
    }

    /// 共有 URL を解析して復元。スキーム／ホスト違いやデータ欠落は typed error。
    static func decode(fromURL url: URL) throws -> SettingsBundle {
        guard url.scheme == urlScheme else { throw DecodeError.wrongScheme }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.host == urlHost else { throw DecodeError.wrongScheme }
        guard let data = comps.queryItems?.first(where: { $0.name == urlDataKey })?.value,
              !data.isEmpty else { throw DecodeError.missingData }
        return try decode(fromEncoded: data)
    }

    /// この URL が設定共有スキームかどうか（open ハンドラの振り分け用）。
    static func isSettingsURL(_ url: URL) -> Bool {
        url.scheme == urlScheme
    }

    // MARK: - 色 ↔ hex

    /// NSColor → "RRGGBBAA"（sRGB）。
    private static func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func b(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "%02X%02X%02X%02X",
                      b(c.redComponent), b(c.greenComponent), b(c.blueComponent), b(c.alphaComponent))
    }

    /// "RRGGBB" / "RRGGBBAA" → NSColor（sRGB）。桁数が違えば nil。
    static func color(fromHex hex: String) -> NSColor? {
        let s = hex.trimmingCharacters(in: .whitespaces)
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = (s.count == 8)
        let r, g, b, a: UInt64
        if hasAlpha {
            r = (value >> 24) & 0xFF; g = (value >> 16) & 0xFF; b = (value >> 8) & 0xFF; a = value & 0xFF
        } else {
            r = (value >> 16) & 0xFF; g = (value >> 8) & 0xFF; b = value & 0xFF; a = 0xFF
        }
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                       blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    // MARK: - base64url

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dataFromBase64url(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        // パディングを復元。
        let rem = s.count % 4
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: s)
    }
}
