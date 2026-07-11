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
/// - 未保存の新規ドキュメント: `draftID` を持つ。**本文はここには入れない**（[[DraftStore]] のファイル）。
struct SessionEntry: Codable {
    /// 保存済みファイルのパス（未保存の新規では nil）。
    var path: String?
    /// 未保存の新規ドキュメントの本文が入った draft ファイルの id（保存済みファイルでは nil）。
    var draftID: String?
    /// 復元時に未保存（編集済み）として印を付けるか。
    var dirty: Bool

    /// 旧版（〜1.0.1）が本文をセッションに直接入れていた名残。読み込み専用（更新時の移行に使う）。
    /// `DraftStore.migratingLegacyText(in:)` が draft ファイルへ移して nil にする。
    var text: String?
}

/// 起動時に開くもの 1 件。
enum RestoreItem: Equatable {
    case file(path: String)
    case draft(id: String, dirty: Bool)
}

/// 起動時に何をどの順で開くかの計画。
struct RestorePlan: Equatable {
    var items: [RestoreItem]
    /// `items` 内のアクティブ位置（-1＝なし）。
    var activeIndex: Int
}

/// 前回終了時に開いていたドキュメント一覧と、アクティブだった位置。
/// **本文は持たない**（未保存の本文は DraftStore が持ち、ここは id を指すだけ）。
struct SessionState: Codable {
    var entries: [SessionEntry]
    /// `entries` 内のアクティブ位置（-1＝なし）。
    var activeIndex: Int

    /// 開いているドキュメント情報からセッションを組み立てる（副作用なし・テスト可能）。
    /// - 保存済み（`url` あり）はパスのみ。未保存の新規（`url` なし）は draft の id を指す。
    ///   **本文が空の新規はスキップ**（復元しない）。
    /// - `activeIndex`（`docs` 内の位置）は、スキップでずれるため `entries` 内の位置へ付け替える。
    static func make(docs: [(url: URL?, text: String?, draftID: String?, dirty: Bool)],
                     activeIndex: Int) -> SessionState {
        var entries: [SessionEntry] = []
        var active = -1
        for (i, d) in docs.enumerated() {
            let entry: SessionEntry?
            if let url = d.url {
                entry = SessionEntry(path: url.path, draftID: nil, dirty: false, text: nil)
            } else if let id = d.draftID, let text = d.text, !text.isEmpty {
                entry = SessionEntry(path: nil, draftID: id, dirty: d.dirty, text: nil)
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

    /// 起動時に何を開くかを決める（副作用なし・テスト可能）。**この関数がデータ保護の要になる。**
    ///
    /// 守る不変条件：**実在する draft（`draftIDs`）は、セッションが何であっても必ず計画に入る。**
    /// セッションが nil でも・壊れていても・別の内容で上書きされていても、未保存の本文は戻る。
    /// 索引（セッション）ではなく、ディスク上の実体（draft ファイル）が真実だという構え。
    ///
    /// - `hasOpenDocuments`＝引数や Finder からファイルを開いて起動したとき。そのファイルを
    ///   優先し、前回の**保存済み**ファイルは開き直さない（従来どおりの意図的な挙動）。
    ///   未保存の draft は、この場合でも必ず復元する。
    static func restorePlan(session: SessionState?,
                            draftIDs: [String],
                            hasOpenDocuments: Bool) -> RestorePlan {
        var items: [RestoreItem] = []
        var active = -1
        var placed = Set<String>()

        if let session {
            for (i, e) in session.entries.enumerated() {
                let item: RestoreItem?
                if let path = e.path {
                    item = hasOpenDocuments ? nil : .file(path: path)
                } else if let id = e.draftID, draftIDs.contains(id) {
                    placed.insert(id)
                    item = .draft(id: id, dirty: e.dirty)
                } else {
                    item = nil   // 本文の無い draft 参照（＝既に保存/破棄済み）は捨てる
                }
                if let item {
                    if i == session.activeIndex { active = items.count }
                    items.append(item)
                }
            }
        }

        // セッションが指していない draft（＝孤児）も必ず開く。ここが最後の砦。
        // 本文が残っている以上、ユーザーはまだ保存も破棄もしていない。
        for id in draftIDs where !placed.contains(id) {
            items.append(.draft(id: id, dirty: true))
        }
        return RestorePlan(items: items, activeIndex: active)
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
    private static let autoUpdateCheckKey = "MrEditor.automaticUpdateChecks"
    private static let lastUpdateCheckKey = "MrEditor.lastUpdateCheck"

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

    /// 起動時に新しい版が出ていないか自動で調べるか。既定 true。
    /// App Store 配布ではないため、これが無いと利用者は新版に気づけない。
    static var automaticUpdateChecks: Bool {
        get { defaults.object(forKey: autoUpdateCheckKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoUpdateCheckKey) }
    }

    /// 自動チェックを最後に行った時刻（1 日 1 回に絞るため）。
    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: lastUpdateCheckKey) as? Date }
        set { defaults.set(newValue, forKey: lastUpdateCheckKey) }
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
