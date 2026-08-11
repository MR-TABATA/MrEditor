import Foundation

/// アプリ全体で参照する基本情報。
///
/// **製品名を変えるときはここ 1 箇所だけ変更すればよい。**
/// メニュー・ウィンドウタイトルなどの実行時表示はすべて `AppInfo.name` を参照する。
/// （配布用 .app のバンドル名等は `scripts/make_app.sh` の `APP_NAME` 側で揃える。）
enum AppInfo {
    /// 製品名（表示名）。**バンドルの `CFBundleName` が唯一の元**（`scripts/make_app.sh` の
    /// `APP_NAME`）。同じ core から無料版 "MrEditor" と Pro 版 "MrkEditor" の 2 つの .app が
    /// 出来るため、コード側に製品名を焼き付けない。開発ビルド（バンドル無し）では無料版扱い。
    static var name: String {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? fallbackName
    }
    private static let fallbackName = "MrEditor"

    /// 表示用バージョン。配布 .app は Info.plist（CFBundleShortVersionString）を優先し、
    /// 開発ビルド（バンドル無し）ではこの定数へフォールバックする。
    /// **リリース時は `scripts/make_app.sh` の `VERSION` と揃える。**
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallbackVersion
    }
    private static let fallbackVersion = "1.11.1"

    /// ヘルプメニューから開くプロジェクトページ。
    static let helpURL = URL(string: "https://github.com/MR-TABATA/MrEditor")!
}
