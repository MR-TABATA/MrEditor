import Foundation

/// アプリ全体で参照する基本情報。
///
/// **製品名を変えるときはここ 1 箇所だけ変更すればよい。**
/// メニュー・ウィンドウタイトルなどの実行時表示はすべて `AppInfo.name` を参照する。
/// （配布用 .app のバンドル名等は `scripts/make_app.sh` の `APP_NAME` 側で揃える。）
enum AppInfo {
    /// 製品名（表示名）。
    static let name = "MrEditor"

    /// 表示用バージョン。配布 .app は Info.plist（CFBundleShortVersionString）を優先し、
    /// 開発ビルド（バンドル無し）ではこの定数へフォールバックする。
    /// **リリース時は `scripts/make_app.sh` の `VERSION` と揃える。**
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallbackVersion
    }
    private static let fallbackVersion = "1.7"

    /// ヘルプメニューから開くプロジェクトページ。
    static let helpURL = URL(string: "https://github.com/MR-TABATA/MrEditor")!
}
