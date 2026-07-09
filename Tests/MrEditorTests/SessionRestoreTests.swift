import XCTest
import AppKit
@testable import MrEditor

/// セッション復元（前回開いていた一覧＝サイドバーの復元）の中核ロジックを検証する。
/// - `SessionState.make`: viewers → 保存データへの組み立て（空の新規スキップ・アクティブ位置付け替え）。
/// - `AppSettings.session`: UserDefaults への JSON 永続化往復。
/// - `EditableViewer.restoreUntitled` / `restorableText`: 未保存の新規の本文再現。
///
/// `AppSettings.session` は UserDefaults.standard を触るため、各テストで元の値へ復元する。
final class SessionRestoreTests: XCTestCase {

    private var savedSession: SessionState?

    override func setUp() {
        super.setUp()
        savedSession = AppSettings.session
    }

    override func tearDown() {
        AppSettings.session = savedSession
        super.tearDown()
    }

    // MARK: - SessionState.make（純粋関数）

    /// 保存済みはパス、未保存の新規は本文つき。空の新規は捨てる。アクティブ位置は entries へ付け替える。
    func testMakeSkipsEmptyUntitledAndRemapsActive() {
        let fileA = URL(fileURLWithPath: "/tmp/a.txt")
        let fileB = URL(fileURLWithPath: "/tmp/b.txt")
        let docs: [(url: URL?, text: String?, dirty: Bool)] = [
            (fileA, nil, false),          // 0: 保存済み
            (nil, "", false),             // 1: 空の新規 → スキップ
            (nil, "メモ", true),           // 2: 未保存の新規（本文あり）← アクティブ
            (fileB, nil, false),          // 3: 保存済み
        ]
        let s = SessionState.make(docs: docs, activeIndex: 2)

        // 空の新規(1)が落ちて 3 件になる。
        XCTAssertEqual(s.entries.count, 3)
        XCTAssertEqual(s.entries[0].path, fileA.path)
        XCTAssertNil(s.entries[0].text)
        XCTAssertNil(s.entries[1].path)
        XCTAssertEqual(s.entries[1].text, "メモ")
        XCTAssertTrue(s.entries[1].dirty)
        XCTAssertEqual(s.entries[2].path, fileB.path)

        // docs[2] は entries では 1 番目に付け替わる。
        XCTAssertEqual(s.activeIndex, 1)
    }

    /// アクティブが空の新規（スキップされる）を指していたら activeIndex は -1。
    func testMakeActiveOnSkippedUntitledBecomesNone() {
        let docs: [(url: URL?, text: String?, dirty: Bool)] = [
            (URL(fileURLWithPath: "/tmp/a.txt"), nil, false),
            (nil, "", false),   // アクティブだがスキップされる
        ]
        let s = SessionState.make(docs: docs, activeIndex: 1)
        XCTAssertEqual(s.entries.count, 1)
        XCTAssertEqual(s.activeIndex, -1)
    }

    /// 何も開いていなければ空のセッション。
    func testMakeEmpty() {
        let s = SessionState.make(docs: [], activeIndex: -1)
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertEqual(s.activeIndex, -1)
    }

    // MARK: - AppSettings.session（UserDefaults 永続化往復）

    /// 保存済み＋未保存の新規（本文つき）を UserDefaults へ書いて読み戻せる。
    func testAppSettingsSessionPersistRoundTrip() {
        let state = SessionState(entries: [
            SessionEntry(path: "/tmp/x.log", text: nil, dirty: false),
            SessionEntry(path: nil, text: "未保存の本文\n2行目", dirty: true),
        ], activeIndex: 1)

        AppSettings.session = state
        let read = AppSettings.session
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.entries.count, 2)
        XCTAssertEqual(read?.entries[0].path, "/tmp/x.log")
        XCTAssertEqual(read?.entries[1].text, "未保存の本文\n2行目")
        XCTAssertEqual(read?.entries[1].dirty, true)
        XCTAssertEqual(read?.activeIndex, 1)
    }

    /// nil を代入すると保存が消える（＝次回は復元しない）。
    func testAppSettingsSessionClear() {
        AppSettings.session = SessionState(entries: [SessionEntry(path: "/tmp/x", text: nil, dirty: false)], activeIndex: 0)
        XCTAssertNotNil(AppSettings.session)
        AppSettings.session = nil
        XCTAssertNil(AppSettings.session)
    }

    // MARK: - EditableViewer の未保存新規の再現

    /// 本文つきで復元でき、未保存印・パス未確定が保たれる。restorableText で本文を取り出せる。
    func testRestoreUntitledSetsTextAndDirty() {
        let v = EditableViewer()
        v.restoreUntitled(text: "ううううう", dirty: true)
        XCTAssertNil(v.fileURL)                       // パス未確定のまま
        XCTAssertTrue(v.isDirty)
        XCTAssertEqual(v._testText, "ううううう")
        XCTAssertEqual(v.restorableText, "ううううう") // 永続化で使う本文
    }

    /// dirty=false でも本文つきで復元できる（空でない新規は残る）。
    func testRestoreUntitledCleanKeepsText() {
        let v = EditableViewer()
        v.restoreUntitled(text: "clean note", dirty: false)
        XCTAssertFalse(v.isDirty)
        XCTAssertEqual(v.restorableText, "clean note")
    }

    /// 構造化表示中の restorableText は整形後の見た目ではなく元の論理本文を返す
    /// （復元しても CSV/JSON の中身が壊れないことの保証）。
    func testRestorableTextDuringStructuredReturnsOriginal() throws {
        let text = "name,age\nAlice,30\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-sr-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.setStructuredMode(.csv)
        XCTAssertNotEqual(v._testText, text)          // 表示は整形後
        XCTAssertEqual(v.restorableText, text)         // 永続化されるのは元の CSV
    }
}
