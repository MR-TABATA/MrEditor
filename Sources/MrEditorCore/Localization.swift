import Foundation

/// ローカライズ済み文字列を引く小さなヘルパ。
///
/// SPM が生成するリソースバンドル（`Bundle.module`）の Info.plist には
/// `CFBundleLocalizations` が載らないため、`Bundle.preferredLocalizations`
/// による自動ネゴシエーションが常に開発言語（en）にフォールバックしてしまう。
/// そこで **利用可能ロケールとユーザの優先言語を自前で突き合わせ**、
/// 該当する `*.lproj` を直接ロードして使う。
private let localizedBundle: Bundle = {
    let available = Bundle.module.localizations            // 例: ["ja", "en"]

    func bestMatch() -> String {
        for pref in Locale.preferredLanguages {            // 例: ["ja-JP", "en", …]
            if available.contains(pref) { return pref }
            let code = String(pref.prefix { $0 != "-" })   // "ja-JP" → "ja"
            if available.contains(code) { return code }
        }
        return "en"                                        // 開発言語へフォールバック
    }

    if let path = Bundle.module.path(forResource: bestMatch(), ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle
    }
    return .module
}()

/// ローカライズ文字列を引く。可変長引数があれば `String(format:)` でフォーマットする
/// （例: `L("menu.about", AppInfo.name)`）。
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = localizedBundle.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}
