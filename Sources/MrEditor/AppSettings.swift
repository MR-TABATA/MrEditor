import Foundation

/// 保存中の進捗の見せ方。
/// - `statusBar`: 非モーダル。保存中もスクロール・閲覧できる（編集だけ一時停止）。
/// - `sheet`: モーダルシート。分かりやすいが保存が終わるまで操作をブロック。
enum SaveProgressStyle: String {
    case statusBar
    case sheet
}

/// 行間（本文の行の高さ倍率）。
enum LineSpacing: String, CaseIterable {
    case standard   // 1.0（既定）
    case wide       // 1.3
    case wider      // 1.6

    var multiplier: CGFloat {
        switch self {
        case .standard: return 1.0
        case .wide:     return 1.3
        case .wider:    return 1.6
        }
    }
}

/// キャレット（挿入位置）の形状。編集可能なペインで有効。
enum CursorShape: String, CaseIterable {
    case bar        // 縦線（既定）
    case block      // 塗り矩形（1 文字幅）
    case underline  // 下線
}

/// アプリの永続設定（UserDefaults 集約）。
enum AppSettings {
    private static let defaults = UserDefaults.standard
    private static let saveProgressKey = "MrEditor.saveProgressStyle"
    private static let lineWrapKey = "MrEditor.lineWrap"
    private static let tabWidthKey = "MrEditor.tabWidth"
    private static let lineSpacingKey = "MrEditor.lineSpacing"
    private static let highlightCurrentLineKey = "MrEditor.highlightCurrentLine"
    private static let cursorShapeKey = "MrEditor.cursorShape"

    static var saveProgressStyle: SaveProgressStyle {
        get { SaveProgressStyle(rawValue: defaults.string(forKey: saveProgressKey) ?? "") ?? .sheet }
        set { defaults.set(newValue.rawValue, forKey: saveProgressKey) }
    }

    /// 長い行を折り返すか。false＝折り返さず横スクロール（既定）、true＝内容幅で折り返す。
    static var lineWrap: Bool {
        get { defaults.bool(forKey: lineWrapKey) }
        set { defaults.set(newValue, forKey: lineWrapKey); NotificationCenter.default.post(name: .mrEditorLineWrapChanged, object: nil) }
    }

    /// タブの表示幅（文字数）。既定 4。選択肢は 2/4/8。
    static var tabWidth: Int {
        get { let v = defaults.integer(forKey: tabWidthKey); return v > 0 ? v : 4 }
        set { defaults.set(newValue, forKey: tabWidthKey); postDisplayChanged() }
    }

    /// 行間。
    static var lineSpacing: LineSpacing {
        get { LineSpacing(rawValue: defaults.string(forKey: lineSpacingKey) ?? "") ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: lineSpacingKey); postDisplayChanged() }
    }

    /// キャレット行を淡い帯で強調するか。既定 true。
    static var highlightCurrentLine: Bool {
        get { defaults.object(forKey: highlightCurrentLineKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: highlightCurrentLineKey); postDisplayChanged() }
    }

    /// キャレット形状。
    static var cursorShape: CursorShape {
        get { CursorShape(rawValue: defaults.string(forKey: cursorShapeKey) ?? "") ?? .bar }
        set { defaults.set(newValue.rawValue, forKey: cursorShapeKey); postDisplayChanged() }
    }

    private static func postDisplayChanged() {
        NotificationCenter.default.post(name: .mrEditorDisplayChanged, object: nil)
    }
}

extension Notification.Name {
    /// 長い行の折り返し設定が変わったとき（開いているビューアへ反映）。
    static let mrEditorLineWrapChanged = Notification.Name("MrEditor.lineWrapChanged")
    /// 表示設定（タブ幅・行間・現在行ハイライト・カーソル形状）が変わったとき。
    static let mrEditorDisplayChanged = Notification.Name("MrEditor.displayChanged")
}
