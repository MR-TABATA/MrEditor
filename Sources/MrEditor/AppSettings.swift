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
    private static let lineWrapKey = "MrEditor.lineWrap"

    static var saveProgressStyle: SaveProgressStyle {
        get { SaveProgressStyle(rawValue: defaults.string(forKey: saveProgressKey) ?? "") ?? .sheet }
        set { defaults.set(newValue.rawValue, forKey: saveProgressKey) }
    }

    /// 長い行を折り返すか。false＝折り返さず横スクロール（既定）、true＝内容幅で折り返す。
    static var lineWrap: Bool {
        get { defaults.bool(forKey: lineWrapKey) }
        set { defaults.set(newValue, forKey: lineWrapKey); NotificationCenter.default.post(name: .mrEditorLineWrapChanged, object: nil) }
    }
}

extension Notification.Name {
    /// 長い行の折り返し設定が変わったとき（開いているビューアへ反映）。
    static let mrEditorLineWrapChanged = Notification.Name("MrEditor.lineWrapChanged")
}
