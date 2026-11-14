import AppKit

/// 分析メニューとビュープリセットの入口を出すか。**いまは出さない**（コードは残してある）。
/// 入口は `AppDelegate`（分析メニュー）と `StructuredBanner`（プリセットのボタン）の 2 か所だけ。
enum AnalysisAvailability {
    static let isEnabled = false
}

/// 分析ペインのタブ（＝「分析」メニューの項目）。
///
/// 1 本のファイルを「見る」だけでなく、全体を走査して「答えを出す」機能。
public enum AnalysisFeature: String, CaseIterable, Sendable {
    /// 値ごとの出現回数（`sort | uniq -c | sort -rn` 相当）。
    case aggregate
    /// 列の統計（ユニーク数・最小最大・空欄数）。
    case columnStats
    /// 時間分布（いつ増えたか）。
    case timeHistogram
    /// フォルダを跨ぐ横断検索。
    case crossFileSearch

    /// 「分析」メニューに出す順。
    static var menuOrder: [AnalysisFeature] { allCases }

    /// `Localizable.strings` で使うキーの語幹（`analysis.aggregate.menu` など）。
    var localizationKey: String { "analysis.\(rawValue)" }
}
