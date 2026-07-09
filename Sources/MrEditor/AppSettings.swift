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

/// 復元対象の 1 ドキュメント。
/// - 保存済みファイル: `path` を持ち、次回はそのファイルを開き直す。
/// - 未保存の新規ドキュメント: `text`（本文）を持ち、空タブとして本文つきで復元する。
struct SessionEntry: Codable {
    /// 保存済みファイルのパス（未保存の新規では nil）。
    var path: String?
    /// 未保存の新規ドキュメントの本文（保存済みファイルでは nil）。
    var text: String?
    /// 復元時に未保存（編集済み）として印を付けるか。
    var dirty: Bool
}

/// 前回終了時に開いていたドキュメント一覧と、アクティブだった位置。
struct SessionState: Codable {
    var entries: [SessionEntry]
    /// `entries` 内のアクティブ位置（-1＝なし）。
    var activeIndex: Int

    /// 開いているドキュメント情報からセッションを組み立てる（副作用なし・テスト可能）。
    /// - 保存済み（`url` あり）はパスのみ。未保存の新規（`url` なし）は本文つきで残すが、
    ///   **空の本文はスキップ**（復元しない）。
    /// - `activeIndex`（`docs` 内の位置）は、スキップでずれるため `entries` 内の位置へ付け替える。
    static func make(docs: [(url: URL?, text: String?, dirty: Bool)], activeIndex: Int) -> SessionState {
        var entries: [SessionEntry] = []
        var active = -1
        for (i, d) in docs.enumerated() {
            let entry: SessionEntry?
            if let url = d.url {
                entry = SessionEntry(path: url.path, text: nil, dirty: false)
            } else if let text = d.text, !text.isEmpty {
                entry = SessionEntry(path: nil, text: text, dirty: d.dirty)
            } else {
                entry = nil
            }
            if let entry {
                if i == activeIndex { active = entries.count }
                entries.append(entry)
            }
        }
        return SessionState(entries: entries, activeIndex: active)
    }
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
    private static let sessionKey = "MrEditor.session"

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

    /// 前回終了時のセッション（左サイドバーの並び順・アクティブ位置）。次回起動時に復元する。
    static var session: SessionState? {
        get {
            guard let data = defaults.data(forKey: sessionKey) else { return nil }
            return try? JSONDecoder().decode(SessionState.self, from: data)
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) {
                defaults.set(data, forKey: sessionKey)
            } else {
                defaults.removeObject(forKey: sessionKey)
            }
        }
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
