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
    private static let fallbackVersion = "1.21.0"

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
        declaredURL(from: value)
    }

    /// Info.plist に宣言された URL。空文字・空白のみ・URL にならない値は「宣言なし」。
    static func declaredURL(from value: Any?) -> URL? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return URL(string: s)
    }

    // MARK: - 要望

    /// 要望の受け口（GitHub の Issue フォーム）と、公開の一覧（状況つき）を宣言するキー
    /// （`scripts/make_app.sh` が書く）。
    static let requestFormKey = "MrEditorRequestForm"
    static let requestListKey = "MrEditorRequestList"

    /// 要望の受け口。**宣言が無ければ nil ＝ ヘルプメニューに項目を出さない。**
    ///
    /// 更新確認の feed と同じ理由で、core には URL を焼き付けない。同じ core から包む Pro 版に
    /// 無料版の要望ページを出すと、買った人の要望が、別の製品の一覧に載ってしまう。
    static var requestFormURL: URL? { declaredURL(from: Bundle.main.infoDictionary?[requestFormKey]) }

    /// 公開の要望一覧（英語版のページ）。宣言が無ければ nil。
    static var requestListURL: URL? { declaredURL(from: Bundle.main.infoDictionary?[requestListKey]) }

    /// 受け口の URL に、バージョンと OS を添える（Issue フォームの同名の欄が、最初から埋まる）。
    /// 既に付いている問い合わせ（`template=` など）は残す。
    static func requestURL(form: URL, version: String, os: String) -> URL? {
        guard var c = URLComponents(url: form, resolvingAgainstBaseURL: false) else { return nil }
        c.queryItems = (c.queryItems ?? []) + [
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "os", value: os),
        ]
        return c.url
    }

    /// 一覧のページを、言語に合わせる。サイトは英語が `name.html`、日本語が `name.ja.html`。
    static func requestListURL(base: URL, japanese: Bool) -> URL {
        guard japanese, base.pathExtension == "html" else { return base }
        let name = base.deletingPathExtension().lastPathComponent
        return base.deletingLastPathComponent().appendingPathComponent("\(name).ja.html")
    }

    /// 「macOS 26.0」のような、要望に添える OS の表記。
    static func osDescription(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }
}
