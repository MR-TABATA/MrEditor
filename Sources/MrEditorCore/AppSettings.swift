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
    private static let showLineNumbersKey = "MrEditor.showLineNumbers"
    private static let showInvisiblesKey = "MrEditor.showInvisibles"
    private static let cursorShapeKey = "MrEditor.cursorShape"
    private static let sessionKey = "MrEditor.session"
    private static let autoReloadKey = "MrEditor.autoReloadExternalChanges"
    private static let autoUpdateCheckKey = "MrEditor.automaticUpdateChecks"
    private static let lastUpdateCheckKey = "MrEditor.lastUpdateCheck"
    private static let columnFieldsKey = "MrEditor.columnFields"
    private static let aiProviderKey = "MrEditor.ai.provider"
    private static let aiModelKey = "MrEditor.ai.model"
    private static let aiBaseURLKey = "MrEditor.ai.baseURL"
    /// 接続テストに通ったモデル ID（プロバイダごと）。次からは一覧から選べる。
    private static func aiRememberedModelsKey(_ provider: AIProvider) -> String {
        "MrEditor.ai.remembered.\(provider.rawValue)"
    }

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

    /// 行番号（ガター）を表示するか。既定 true。
    /// 巨大ファイル側は自前ガター、小ファイル側は NSRulerView が担うが、設定は 1 つ。
    static var showLineNumbers: Bool {
        get { defaults.object(forKey: showLineNumbersKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: showLineNumbersKey); postDisplayChanged() }
    }

    /// 不可視文字（タブ・改行・全角スペース・行末の半角スペース）を記号で見せるか。既定 false。
    static var showInvisibles: Bool {
        get { defaults.bool(forKey: showInvisiblesKey) }
        set { defaults.set(newValue, forKey: showInvisiblesKey); postDisplayChanged() }
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

    // MARK: - 固定長の項目定義（ファイルごと）

    /// 覚えておくファイル数の上限。超えたら**古いものから**捨てる。
    private static let columnFieldsCapacity = 200

    /// 固定長の項目定義（境界の桁）をファイルごとに覚える。
    ///
    /// **名前を付けて別のファイルにも当てる（プロファイル）ことはしない**——それは Pro の線。
    /// ここでやるのは「さっき開いていたファイルを開き直したら、さっきの定義のまま」だけで、
    /// セッション復元と同じ性質（[[CONTRIBUTING.md]] の課金境界）。
    /// 値は `[path, 保存順の連番, 桁…]` ではなく、桁の配列と最終使用時刻を持つ小さな辞書。
    private struct ColumnFieldsEntry: Codable {
        var columns: [Int]
        var usedAt: Date
    }

    private static func columnFieldsMap() -> [String: ColumnFieldsEntry] {
        guard let data = defaults.data(forKey: columnFieldsKey),
              let map = try? JSONDecoder().decode([String: ColumnFieldsEntry].self, from: data) else { return [:] }
        return map
    }

    /// そのファイルに覚えてある項目定義（無ければ空）。
    static func columnGuides(for url: URL?) -> [Int] {
        guard let url else { return [] }
        return columnFieldsMap()[url.path]?.columns ?? []
    }

    /// そのファイルの項目定義を覚える（空配列＝忘れる）。
    static func setColumnGuides(_ columns: [Int], for url: URL?) {
        guard let url else { return }
        var map = columnFieldsMap()
        if columns.isEmpty {
            guard map.removeValue(forKey: url.path) != nil else { return }
        } else {
            let entry = ColumnFieldsEntry(columns: columns, usedAt: Date())
            if map[url.path]?.columns == columns { map[url.path]?.usedAt = entry.usedAt } else { map[url.path] = entry }
            if map.count > columnFieldsCapacity {
                for key in map.sorted(by: { $0.value.usedAt < $1.value.usedAt })
                    .prefix(map.count - columnFieldsCapacity).map(\.key) {
                    map.removeValue(forKey: key)
                }
            }
        }
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: columnFieldsKey) }
    }

    /// 他のアプリでファイルが書き換わったとき、自動で読み込み直すか。既定 true。
    /// **オフでも変更は知らせる**（本文下端のバナー）。黙って古い内容を見せ続けることはしない。
    /// 未保存の変更があるときは、オンでも自動では取り込まない（潰してしまうため）。
    static var autoReloadExternalChanges: Bool {
        get { defaults.object(forKey: autoReloadKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoReloadKey) }
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

    /// AI 連携（BYOK）の設定。**キー本体は含まない**（キーは [[Keychain]]）。
    /// プロバイダ・モデル・ベース URL 上書きだけを UserDefaults に持つ。
    static var aiConfig: AIConfig {
        get {
            let provider = AIProvider(rawValue: defaults.string(forKey: aiProviderKey) ?? "") ?? .anthropic
            let model = defaults.string(forKey: aiModelKey) ?? ""
            let base = defaults.string(forKey: aiBaseURLKey) ?? ""
            return AIConfig(provider: provider,
                            model: model.isEmpty ? provider.defaultModel : model,
                            baseURLOverride: base)
        }
        set {
            defaults.set(newValue.provider.rawValue, forKey: aiProviderKey)
            defaults.set(newValue.model, forKey: aiModelKey)
            defaults.set(newValue.baseURLOverride, forKey: aiBaseURLKey)
        }
    }

    /// 自分で確かめたモデル（新しい順）。一覧に無い ID を打ち込んだ人の「自分の一覧」。
    static func aiRememberedModels(for provider: AIProvider) -> [String] {
        defaults.stringArray(forKey: aiRememberedModelsKey(provider)) ?? []
    }

    /// 接続テストに通ったモデルを覚える。打ち間違いは通らない＝一覧が汚れない。
    /// 新しい順・重複なし・上限 8 件（設定欄の一覧が長くなりすぎないように）。
    static func rememberAIModel(_ model: String, for provider: AIProvider) {
        let m = model.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty, !provider.suggestedModels.contains(m) else { return }   // 既定の候補は覚え直さない
        var list = aiRememberedModels(for: provider).filter { $0 != m }
        list.insert(m, at: 0)
        defaults.set(Array(list.prefix(8)), forKey: aiRememberedModelsKey(provider))
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
