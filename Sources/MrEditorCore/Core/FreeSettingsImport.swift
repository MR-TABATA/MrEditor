import AppKit

/// 同じ Mac にインストールされた無料版（MrEditor）から、Pro 側の設定へ安全に取り込む。
///
/// **Pro 専用の機能。** 呼び出し口は Pro 側（`MrkPro`）にしか存在しない。core 自身のメニュー・
/// 実行ファイルはこの型を一切参照しないので、無料版に機能が漏れることはない
/// （`scripts/check_consistency.py` の pro_gate 検査は「core 内で `ProFeature` の
/// ケースを未ゲートで使っていないか」を見るものだが、この型はそもそも `ProFeature` の
/// ケースではないので対象外 —— ゲートの必要が無い形にしてある）。
///
/// 意図的に含めないもの:
///   - セッション・下書き（[[AppSettings.session]]）… 開いていたファイルの復元情報
///   - ファイルごとの列定義（`MrEditor.columnFields`）… 絶対パスをキーに持つため
///   - 自動更新チェックの設定・最終チェック時刻 … アプリごとに更新経路が別
///   - AI プロバイダ設定 … 既に Keychain 共有アカウントで解決済み（[[AppSettings.aiConfig]]）。
///     ここでも UserDefaults 経由で運ぶと、真実の源が二重になる
///   - 秘密情報（API キー等） … そもそも UserDefaults には無く Keychain にしかない
public struct FreeSettingsImport: Equatable {
    // 外観（[[EditorTheme]] / [[EditorFont]]）
    public var themePresetRawValue: String
    /// `EditorTheme.ColorKey.rawValue` → 色。
    public var customColors: [String: NSColor]
    public var backgroundOpacity: Double
    public var ansiColors: Bool
    public var fontName: String?
    public var fontSize: Double

    // 挙動（[[AppSettings]]）
    public var saveProgressStyleRawValue: String
    public var lineWrap: Bool
    public var filterContextLines: Int
    public var searchFilterOn: Bool
    public var tabWidth: Int
    public var lineSpacingRawValue: String
    public var highlightCurrentLine: Bool
    public var showLineNumbers: Bool
    public var showInvisibles: Bool
    public var cursorShapeRawValue: String
    public var autoReloadExternalChanges: Bool

    /// 指定したバンドル ID の UserDefaults ドメインから読む。
    /// そのアプリが一度も起動されていない等でドメインが空なら nil。
    public static func capture(fromBundleID bundleID: String) -> FreeSettingsImport? {
        guard let source = UserDefaults(suiteName: bundleID),
              let domain = source.persistentDomain(forName: bundleID), !domain.isEmpty else { return nil }

        let theme = EditorTheme.appearanceSnapshot(from: source)
        let font = EditorFont.snapshot(from: source)
        let behavior = AppSettings.behaviorSnapshot(from: source)

        return FreeSettingsImport(
            themePresetRawValue: theme.preset.rawValue,
            customColors: theme.customColors,
            backgroundOpacity: Double(theme.backgroundOpacity),
            ansiColors: theme.ansiColorsEnabled,
            fontName: font.name,
            fontSize: Double(font.size),
            saveProgressStyleRawValue: behavior.saveProgressStyle.rawValue,
            lineWrap: behavior.lineWrap,
            filterContextLines: behavior.filterContextLines,
            searchFilterOn: behavior.searchFilterOn,
            tabWidth: behavior.tabWidth,
            lineSpacingRawValue: behavior.lineSpacing.rawValue,
            highlightCurrentLine: behavior.highlightCurrentLine,
            showLineNumbers: behavior.showLineNumbers,
            showInvisibles: behavior.showInvisibles,
            cursorShapeRawValue: behavior.cursorShape.rawValue,
            autoReloadExternalChanges: behavior.autoReloadExternalChanges)
    }

    /// 自分自身（呼び出し側アプリ）のグローバル設定へ適用する。
    /// 既存の setter 経由なので、開いているウィンドウへの通知も既存の仕組みでそのまま飛ぶ。
    public func apply() {
        // custom 色を先に入れると preset が一旦 .custom に倒れるため、preset は最後に確定する
        // （[[SettingsBundle.apply]] と同じ順序）。
        for key in EditorTheme.ColorKey.allCases {
            if let color = customColors[key.rawValue] {
                EditorTheme.setCustomColor(key, color)
            }
        }
        EditorTheme.preset = ThemePreset(rawValue: themePresetRawValue) ?? .system
        EditorTheme.backgroundOpacity = CGFloat(backgroundOpacity)
        EditorTheme.ansiColorsEnabled = ansiColors
        EditorFont.setName(fontName)
        EditorFont.setSize(CGFloat(fontSize))

        AppSettings.saveProgressStyle = SaveProgressStyle(rawValue: saveProgressStyleRawValue) ?? .sheet
        AppSettings.lineWrap = lineWrap
        AppSettings.filterContextLines = filterContextLines
        AppSettings.searchFilterOn = searchFilterOn
        AppSettings.tabWidth = tabWidth
        AppSettings.lineSpacing = LineSpacing(rawValue: lineSpacingRawValue) ?? .standard
        AppSettings.highlightCurrentLine = highlightCurrentLine
        AppSettings.showLineNumbers = showLineNumbers
        AppSettings.showInvisibles = showInvisibles
        AppSettings.cursorShape = CursorShape(rawValue: cursorShapeRawValue) ?? .bar
        AppSettings.autoReloadExternalChanges = autoReloadExternalChanges
    }

    /// 確認シート用の短い説明（[[SettingsBundle.summaryLines]] と同じ見せ方）。
    public func summaryLines() -> [String] {
        let themeName = L("prefs.theme.\(themePresetRawValue)")
        let fontDesc = (fontName ?? L("prefs.font.system")) + "  \(Int(fontSize)) pt"
        return ["\(L("prefs.theme")): \(themeName)", "\(L("prefs.font")): \(fontDesc)"]
    }
}
