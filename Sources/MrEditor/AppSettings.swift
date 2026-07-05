import Foundation

/// 保存中の進捗の見せ方。
/// - `statusBar`: 非モーダル。保存中もスクロール・閲覧できる（編集だけ一時停止）。
/// - `sheet`: モーダルシート。分かりやすいが保存が終わるまで操作をブロック。
enum SaveProgressStyle: String {
    case statusBar
    case sheet
}

/// アプリの永続設定（UserDefaults 集約）。
enum AppSettings {
    private static let defaults = UserDefaults.standard
    private static let saveProgressKey = "MrEditor.saveProgressStyle"

    static var saveProgressStyle: SaveProgressStyle {
        get { SaveProgressStyle(rawValue: defaults.string(forKey: saveProgressKey) ?? "") ?? .statusBar }
        set { defaults.set(newValue.rawValue, forKey: saveProgressKey) }
    }
}
