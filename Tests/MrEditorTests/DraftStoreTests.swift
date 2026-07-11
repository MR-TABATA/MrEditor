import XCTest
@testable import MrEditor

/// 未保存の本文の保護（[[DraftStore]] と復元プラン）を検証する。
///
/// ここで守っている不変条件は 1 つ：
/// **実在する draft は、セッションが何であっても（nil・壊れている・上書きされている）必ず復元される。**
/// 1.0 のデータ消失バグは、本文がセッションと同じ器に入っていたために起きた。
/// セッションは索引にすぎず、真実はディスク上の draft ファイルである、という構えをテストで固定する。
final class DraftStoreTests: XCTestCase {

    private var root: URL!
    private var store: DraftStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-drafts-\(UUID().uuidString)")
        store = DraftStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - DraftStore（本文の器）

    /// 書いて読める。ディレクトリが無くても作る。
    func testWriteThenRead() {
        let id = DraftStore.newID()
        store.write(id: id, text: "未保存の下書き\n2行目")
        XCTAssertEqual(store.read(id: id), "未保存の下書き\n2行目")
        XCTAssertEqual(store.allIDs(), [id])
    }

    /// 上書きできる（打鍵のたびに最新へ）。
    func testWriteOverwrites() {
        let id = DraftStore.newID()
        store.write(id: id, text: "old")
        store.write(id: id, text: "new")
        XCTAssertEqual(store.read(id: id), "new")
        XCTAssertEqual(store.allIDs().count, 1)
    }

    /// 空の本文はファイルを持たない（新規タブを開いただけの状態は復元しない）。
    func testEmptyTextRemovesFile() {
        let id = DraftStore.newID()
        store.write(id: id, text: "something")
        store.write(id: id, text: "")
        XCTAssertNil(store.read(id: id))
        XCTAssertTrue(store.allIDs().isEmpty)
    }

    /// discard が本文を消す唯一の入口。
    func testDiscardRemoves() {
        let id = DraftStore.newID()
        store.write(id: id, text: "捨てる")
        store.discard(id)
        XCTAssertNil(store.read(id: id))
        XCTAssertTrue(store.allIDs().isEmpty)
    }

    /// 存在しない draft を読んでも discard しても壊れない。
    func testMissingDraftIsHarmless() {
        XCTAssertNil(store.read(id: "no-such-id"))
        store.discard("no-such-id")   // 例外を投げない
        XCTAssertTrue(store.allIDs().isEmpty)
    }

    /// 旧版（〜1.0.1）のセッション（本文を直に持つ）は draft ファイルへ移す。更新で失わない。
    func testMigratingLegacyTextMovesBodyIntoDraftFile() throws {
        let legacy = SessionState(entries: [
            SessionEntry(path: "/tmp/a.txt", draftID: nil, dirty: false, text: nil),
            SessionEntry(path: nil, draftID: nil, dirty: true, text: "旧版の未保存の本文"),
        ], activeIndex: 1)

        let migrated = store.migratingLegacyText(in: legacy)

        let id = try XCTUnwrap(migrated.entries[1].draftID)
        XCTAssertNil(migrated.entries[1].text)                      // セッションからは本文が消える
        XCTAssertEqual(store.read(id: id), "旧版の未保存の本文")      // ファイルへ移っている
        XCTAssertEqual(migrated.entries[0].path, "/tmp/a.txt")      // 保存済みはそのまま
    }

    // MARK: - restorePlan（起動時に何を開くか）— データ保護の要

    /// 通常の起動：セッションの順どおりに開き、アクティブ位置も引き継ぐ。
    func testPlanFollowsSessionOrder() {
        let session = SessionState(entries: [
            SessionEntry(path: "/tmp/a.txt", draftID: nil, dirty: false, text: nil),
            SessionEntry(path: nil, draftID: "D1", dirty: true, text: nil),
        ], activeIndex: 1)

        let plan = SessionState.restorePlan(session: session, draftIDs: ["D1"], hasOpenDocuments: false)

        XCTAssertEqual(plan.items, [.file(path: "/tmp/a.txt"), .draft(id: "D1", dirty: true)])
        XCTAssertEqual(plan.activeIndex, 1)
    }

    /// **セッションが無くても、実在する draft は必ず開く。**（初回・設定消去・読み込み失敗）
    func testPlanWithoutSessionStillRestoresDrafts() {
        let plan = SessionState.restorePlan(session: nil, draftIDs: ["D1", "D2"], hasOpenDocuments: false)
        XCTAssertEqual(plan.items, [.draft(id: "D1", dirty: true), .draft(id: "D2", dirty: true)])
    }

    /// **セッションが別の内容に上書きされていても、draft は必ず開く。**
    /// これが 1.0 のデータ消失（起動時のオープンがセッションを潰した）の再発防止そのもの。
    func testPlanRestoresOrphanDraftsWhenSessionWasOverwritten() {
        // セッションは「small.txt だけ」に潰されている。draft への参照は残っていない。
        let clobbered = SessionState(entries: [
            SessionEntry(path: "/tmp/small.txt", draftID: nil, dirty: false, text: nil),
        ], activeIndex: 0)

        let plan = SessionState.restorePlan(session: clobbered, draftIDs: ["D1"], hasOpenDocuments: false)

        XCTAssertTrue(plan.items.contains(.draft(id: "D1", dirty: true)), "孤児 draft を拾えていない")
    }

    /// ファイルを開いて起動したとき（Finder / 引数）：前回の保存済みは開き直さないが、
    /// **未保存の draft は必ず戻す**。
    func testPlanWithOpenDocumentsKeepsDraftsAndDropsFiles() {
        let session = SessionState(entries: [
            SessionEntry(path: "/tmp/a.txt", draftID: nil, dirty: false, text: nil),
            SessionEntry(path: nil, draftID: "D1", dirty: true, text: nil),
        ], activeIndex: 0)

        let plan = SessionState.restorePlan(session: session, draftIDs: ["D1"], hasOpenDocuments: true)

        XCTAssertEqual(plan.items, [.draft(id: "D1", dirty: true)])
    }

    /// 保存済み／破棄済みの draft をセッションが指していても、本文が無いなら開かない（幽霊タブを出さない）。
    func testPlanDropsSessionEntryWhoseDraftIsGone() {
        let session = SessionState(entries: [
            SessionEntry(path: nil, draftID: "GONE", dirty: true, text: nil),
        ], activeIndex: 0)

        let plan = SessionState.restorePlan(session: session, draftIDs: [], hasOpenDocuments: false)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.activeIndex, -1)
    }

    /// **不変条件（総括）：どんなセッションを与えても、実在する draft は 1 つ残らず計画に入る。**
    func testInvariantEveryExistingDraftIsAlwaysRestored() {
        let draftIDs = ["D1", "D2", "D3"]
        let sessions: [SessionState?] = [
            nil,                                                                     // 無い
            SessionState(entries: [], activeIndex: -1),                              // 空
            SessionState(entries: [                                                  // 一部しか知らない
                SessionEntry(path: nil, draftID: "D2", dirty: false, text: nil),
            ], activeIndex: 0),
            SessionState(entries: [                                                  // 別物で上書きされた
                SessionEntry(path: "/tmp/x.txt", draftID: nil, dirty: false, text: nil),
            ], activeIndex: 0),
            SessionState(entries: [                                                  // 存在しない draft を指す
                SessionEntry(path: nil, draftID: "STALE", dirty: true, text: nil),
            ], activeIndex: 0),
        ]

        for session in sessions {
            for open in [false, true] {
                let plan = SessionState.restorePlan(session: session, draftIDs: draftIDs, hasOpenDocuments: open)
                for id in draftIDs {
                    let restored = plan.items.contains { item in
                        if case .draft(let i, _) = item { return i == id }
                        return false
                    }
                    XCTAssertTrue(restored, "draft \(id) が復元計画から漏れた（hasOpenDocuments=\(open)）")
                }
            }
        }
    }

    // MARK: - EditableViewer が draft を持つ

    /// 新規ドキュメントには draft の id が振られる（本文が空のうちはファイルを作らない）。
    func testNewDocumentGetsDraftIDButNoFileWhileEmpty() {
        let v = EditableViewer()
        v.draftStore = store
        v.newDocument()

        XCTAssertNotNil(v.draftID)
        v.flushDraft()
        XCTAssertTrue(store.allIDs().isEmpty, "空の新規でファイルを作ってはいけない")
    }

    /// 本文があれば flushDraft でディスクに残る（クラッシュしても戻せる状態）。
    func testFlushDraftWritesBody() {
        let v = EditableViewer()
        v.draftStore = store
        let id = DraftStore.newID()
        v.restoreDraft(id: id, text: "落ちても残る本文", dirty: true)

        v.flushDraft()

        XCTAssertEqual(store.read(id: id), "落ちても残る本文")
        XCTAssertEqual(v.draftID, id)
        XCTAssertTrue(v.isDirty)
    }

    /// 閉じた（破棄した）ときだけ draft が消える。
    func testDiscardDraftRemovesFileAndID() {
        let v = EditableViewer()
        v.draftStore = store
        let id = DraftStore.newID()
        v.restoreDraft(id: id, text: "捨てる本文", dirty: true)
        v.flushDraft()
        XCTAssertNotNil(store.read(id: id))

        v.discardDraft()

        XCTAssertNil(store.read(id: id))
        XCTAssertNil(v.draftID)
    }

    /// 実ファイルへ保存できたら draft は要らない（消えてよい 2 経路のうちの 1 つ）。
    func testSavingToFileDiscardsDraft() throws {
        let v = EditableViewer()
        v.draftStore = store
        let id = DraftStore.newID()
        v.restoreDraft(id: id, text: "保存する本文\n", dirty: true)
        v.flushDraft()
        XCTAssertNotNil(store.read(id: id))

        let url = root.appendingPathComponent("saved-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(v._testWrite(to: url))

        XCTAssertNil(store.read(id: id), "保存したのに draft が残っている")
        XCTAssertNil(v.draftID)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "保存する本文\n")
    }

    /// 実ファイルを開いたペインは draft を持たない（保存済みの本文を二重に持たない）。
    func testOpeningFileClearsDraftID() throws {
        let url = root.appendingPathComponent("open-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "ファイルの中身".data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        v.draftStore = store
        v.newDocument()
        XCTAssertNotNil(v.draftID)

        XCTAssertTrue(v.open(url: url))

        XCTAssertNil(v.draftID)
    }
}
