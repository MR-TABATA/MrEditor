import Foundation

/// 未保存の新規ドキュメントの本文を、**1 ドキュメント＝1 ファイル**でディスクに持つ。
///
/// ## なぜセッションと器を分けるのか
/// 未保存の本文は、ユーザーがまだどこにも保存していない**唯一の写し**で、失えば戻せない。
/// 一方セッション（開いていた一覧・並び・アクティブ位置）は、壊れても作り直せる索引にすぎない。
/// この二つを同じ器（1 個の UserDefaults キー）に入れ、毎回まるごと書き直していたことが、
/// 1.0 のデータ消失バグ（起動時のオープンがセッションを上書きして未保存の本文ごと消す）と、
/// クラッシュで全消しになる穴の共通の根だった。
///
/// そこで本文はここに追い出す。守る規則は 3 つ：
/// 1. 本文は `Drafts/<id>.txt` へ **atomic 書き込み**。セッションは `id` を参照するだけ。
/// 2. **起動時はセッションではなくこのディレクトリを真実として読む**（索引に載っていない
///    孤児 draft も必ず拾う）。索引が壊れても・全消しされても本文は戻る。
/// 3. **消えるのは `discard(_:)` を通ったときだけ。** 呼ぶのは「実ファイルへの保存に成功した」
///    「ユーザーがドキュメントを閉じた（破棄を選んだ）」の 2 経路に限る。
///    セッションの書き出しからは決して消さない。
struct DraftStore {
    /// draft ファイルを置くディレクトリ（テストでは一時ディレクトリを渡す）。
    let root: URL

    static let shared = DraftStore(root: DraftStore.defaultRoot)

    /// `~/Library/Application Support/MrEditor/Drafts`
    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MrEditor/Drafts", isDirectory: true)
    }

    /// 新しい draft の識別子。ファイル名にそのまま使う。
    static func newID() -> String { UUID().uuidString }

    private func url(for id: String) -> URL {
        root.appendingPathComponent(id).appendingPathExtension("txt")
    }

    /// 本文を書き出す（atomic）。**空の本文はファイルを持たない**（新規タブを開いただけの
    /// 状態を復元しても意味が無い）。空になったら消すが、`id` は生き続けるので打ち直せば復活する。
    func write(id: String, text: String) {
        guard !text.isEmpty else { discard(id); return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url(for: id), options: .atomic)
        } catch {
            // 書けなくてもアプリは止めない（次の打鍵でまた試す）。
            NSLog("MrEditor: draft の書き出しに失敗した (%@): %@", id, error.localizedDescription)
        }
    }

    /// 本文を読む（無ければ nil）。
    func read(id: String) -> String? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 実在する draft の id を**古い順**に返す（復元したとき前回に近い並びになる）。
    func allIDs() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return names
            .filter { $0.pathExtension == "txt" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// **本文を消す唯一の入口。** 保存に成功したか、ユーザーがドキュメントを閉じたときだけ呼ぶ。
    func discard(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// 旧版（〜1.0.1）のセッションは本文をセッション自身に入れていた。
    /// その本文を draft ファイルへ移し、`draftID` を振ったセッションを返す（更新に伴う取りこぼし防止）。
    func migratingLegacyText(in state: SessionState) -> SessionState {
        var s = state
        for i in s.entries.indices {
            guard s.entries[i].path == nil, s.entries[i].draftID == nil,
                  let text = s.entries[i].text, !text.isEmpty else { continue }
            let id = DraftStore.newID()
            write(id: id, text: text)
            s.entries[i].draftID = id
            s.entries[i].text = nil
        }
        return s
    }
}
