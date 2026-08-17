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
    private static let fallbackVersion = "1.12.2"

    /// ヘルプメニューから開くプロジェクトページ。
    static let helpURL = URL(string: "https://github.com/MR-TABATA/MrEditor")!

    /// Info.plist で更新確認の feed を宣言するキー（`scripts/make_app.sh` が書く）。
    static let updateFeedKey = "MrEditorUpdateFeed"

    /// 更新を調べに行く先。**宣言が無ければ nil＝更新確認そのものをしない。**
    ///
    /// 同じ core から無料版と Pro の 2 つの .app が出来るので、ここに URL を焼き付けると
    /// **買った人に無料版のダウンロードを勧める**ことになる。配布の出どころは製品ごとに
    /// バンドルが宣言し、core は宣言が無ければ黙る（無料版だけが自分の feed を書く）。
    static var updateFeedURL: URL? {
        updateFeed(from: Bundle.main.infoDictionary?[updateFeedKey])
    }

    /// Info.plist の値から feed を取り出す（テストのため分離）。空文字・空白のみは「無し」。
    static func updateFeed(from value: Any?) -> URL? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return URL(string: s)
    }
}
