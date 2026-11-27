import XCTest
import AppKit
@testable import MrEditorCore

/// `mreditor --wait` の、アプリ側（`MainWindowController`）の処理。
/// 実際のウィンドウとタブは出さず、開く処理を差し替えて、依頼の取り込み・解放・取り下げを確かめる。
/// 確認シート（未保存で閉じる）は画面なので、ここでは扱わない（閉じる経路は `removePane` の 1 本で同じ）。
final class EditorWaitControllerTests: XCTestCase {

    private var dir: URL!
    private var files: URL!
    private var drafts: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-wait-ctl-\(UUID().uuidString)", isDirectory: true)
        dir = base.appendingPathComponent("wait", isDirectory: true)
        files = base.appendingPathComponent("files", isDirectory: true)
        drafts = base.appendingPathComponent("drafts", isDirectory: true)
        for d in [dir!, files!, drafts!] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    // MARK: 道具

    private func makeFile(_ name: String, _ text: String = "text\n") throws -> URL {
        let url = files.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeViewer(_ url: URL, controller: MainWindowController) -> EditableViewer? {
        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v.draftStore = DraftStore(root: drafts)          // 本物の下書き置き場に触れない
        guard v.open(url: url) else { return nil }
        return v
    }

    /// 開く処理を差し替えたコントローラ。`failing` に名前のあるファイルは、開けなかったことにする。
    private func makeController(failing: Set<String> = [], opened: ((URL) -> Void)? = nil) -> MainWindowController {
        let c = MainWindowController()
        _ = c.window
        c.draftStore = DraftStore(root: drafts)
        c.waitOpener = { [unowned self, unowned c] url in
            opened?(url)
            if failing.contains(url.lastPathComponent) { return nil }
            guard let v = self.makeViewer(url, controller: c) else { return nil }
            c.viewers.append(v)
            c.activate(c.viewers.count - 1)
            return v
        }
        return c
    }

    private func request(_ id: String, _ urls: [URL]) throws {
        try EditorWait.write(.init(id: id, waiterPID: getpid(), paths: urls.map(\.path)), in: dir)
    }

    // MARK: 取り込み・失敗

    func testIngestingMarksTheRequestAsReceived() throws {
        let c = makeController()
        try request("r", [try makeFile("a.txt")])
        XCTAssertTrue(c.ingestWaitRequests(in: dir))
        XCTAssertTrue(EditorWait.isClaimed(id: "r", in: dir))
        XCTAssertEqual(c.viewers.count, 1)
        XCTAssertNil(EditorWait.readStatus(id: "r", in: dir), "まだ待っている")
    }

    func testAnUnopenablePathFailsWithAReasonAndIsNotReopened() throws {
        var opens = 0
        let c = makeController(failing: ["bad.txt"], opened: { _ in opens += 1 })
        try request("f", [files.appendingPathComponent("bad.txt")])
        XCTAssertTrue(c.ingestWaitRequests(in: dir))
        XCTAssertEqual(EditorWait.readStatus(id: "f", in: dir), EditorWait.exitFailure)
        XCTAssertTrue(EditorWait.readMessage(id: "f", in: dir).contains("bad.txt"), "何を開けなかったかを伝える")
        // 依頼ファイルは待ち手が片付けるまで残る。再走査しても、開き直さない。
        XCTAssertFalse(c.ingestWaitRequests(in: dir))
        XCTAssertEqual(opens, 1)
    }

    func testWhenTheSecondFileFailsTheWaiterGetsFailureAndTheFirstTabStaysOrdinary() throws {
        let c = makeController(failing: ["bad.txt"])
        try request("two", [try makeFile("ok.txt"), files.appendingPathComponent("bad.txt")])
        c.ingestWaitRequests(in: dir)
        XCTAssertEqual(EditorWait.readStatus(id: "two", in: dir), EditorWait.exitFailure)
        XCTAssertEqual(c.viewers.count, 1, "1 つ目のタブは開いたまま")
        // そのタブを閉じても、失敗の結果は上書きされない（待ち手はもう 1 で戻っている）。
        c.closeDocument(at: 0)
        XCTAssertEqual(EditorWait.readStatus(id: "two", in: dir), EditorWait.exitFailure)
        XCTAssertTrue(c.canReopenClosedDocument, "待ち手のいないタブは、普通のタブ")
    }

    func testARequestWithoutFilesFails() throws {
        let c = makeController()
        try request("empty", [])
        c.ingestWaitRequests(in: dir)
        XCTAssertEqual(EditorWait.readStatus(id: "empty", in: dir), EditorWait.exitFailure)
        XCTAssertFalse(EditorWait.readMessage(id: "empty", in: dir).isEmpty)
    }

    // MARK: タブを閉じる

    func testClosingTheTabReleasesTheWaiterWithZero() throws {
        let c = makeController()
        try request("c", [try makeFile("COMMIT_EDITMSG")])
        c.ingestWaitRequests(in: dir)
        XCTAssertNil(EditorWait.readStatus(id: "c", in: dir))
        c.closeDocument(at: 0)
        XCTAssertEqual(EditorWait.readStatus(id: "c", in: dir), EditorWait.exitDone)
    }

    func testAMultiFileRequestIsReleasedOnlyWhenAllTabsAreClosed() throws {
        let c = makeController()
        try request("multi", [try makeFile("a.txt"), try makeFile("b.txt")])
        c.ingestWaitRequests(in: dir)
        XCTAssertEqual(c.viewers.count, 2)
        c.closeDocument(at: 0)
        XCTAssertNil(EditorWait.readStatus(id: "multi", in: dir), "1 つ閉じただけでは戻らない")
        c.closeDocument(at: 0)
        XCTAssertEqual(EditorWait.readStatus(id: "multi", in: dir), EditorWait.exitDone)
    }

    func testClosingAnUnrelatedTabDoesNotRelease() throws {
        let c = makeController()
        let other = try makeFile("other.txt")
        let v = try XCTUnwrap(makeViewer(other, controller: c))
        c.viewers.append(v)
        c.activate(0)
        try request("w", [try makeFile("waited.txt")])
        c.ingestWaitRequests(in: dir)
        c.closeDocument(at: 0)                       // 待たれていないほう
        XCTAssertNil(EditorWait.readStatus(id: "w", in: dir))
    }

    // MARK: アプリの終了（⌘Q）

    func testQuittingReleasesEveryWaiterWithZero() throws {
        let c = makeController()
        try request("q1", [try makeFile("a.txt")])
        try request("q2", [try makeFile("b.txt")])
        c.ingestWaitRequests(in: dir)
        c.releaseAllWaiters()
        XCTAssertEqual(EditorWait.readStatus(id: "q1", in: dir), EditorWait.exitDone)
        XCTAssertEqual(EditorWait.readStatus(id: "q2", in: dir), EditorWait.exitDone)
    }

    // MARK: ⌘⇧T（閉じたタブを開き直す）

    func testAWaitedTabIsNotOfferedForReopening() throws {
        let c = makeController()
        try request("t", [try makeFile("COMMIT_EDITMSG")])
        c.ingestWaitRequests(in: dir)
        c.closeDocument(at: 0)
        XCTAssertFalse(c.canReopenClosedDocument, "一時ファイルは、開き直しの一覧に入れない")
    }

    func testAnOrdinaryTabIsOfferedForReopening() throws {
        let c = makeController()
        let v = try XCTUnwrap(makeViewer(try makeFile("plain.txt"), controller: c))
        c.viewers.append(v)
        c.activate(0)
        c.closeDocument(at: 0)
        XCTAssertTrue(c.canReopenClosedDocument)
    }

    // MARK: 見回り（Ctrl-C などで待ち手が消えた依頼の取り下げ）

    func testAbandonedRequestIsWithdrawnAndTheTabBecomesOrdinary() throws {
        let c = makeController()
        try request("gone", [try makeFile("c.txt")])
        c.ingestWaitRequests(in: dir)
        // 待ち手が Ctrl-C で、依頼ファイルを消した。
        EditorWait.cleanup(id: "gone", in: dir)
        c.pruneAbandonedWaiters()
        // 取り下げたあとは普通のタブ: 閉じても完了を書かず、開き直しの一覧に入る。
        c.closeDocument(at: 0)
        XCTAssertNil(EditorWait.readStatus(id: "gone", in: dir))
        XCTAssertTrue(c.canReopenClosedDocument)
    }

    func testPruneLeavesALiveRequestAlone() throws {
        let c = makeController()
        try request("live", [try makeFile("c.txt")])
        c.ingestWaitRequests(in: dir)
        c.pruneAbandonedWaiters()
        c.closeDocument(at: 0)
        XCTAssertEqual(EditorWait.readStatus(id: "live", in: dir), EditorWait.exitDone, "まだ待っているので、解放される")
        XCTAssertFalse(c.canReopenClosedDocument)
    }

    // MARK: 完了を書けないとき

    func testWhenTheStatusCannotBeWrittenTheRequestIsWithdrawnSoTheWaiterDoesNotHang() throws {
        let c = makeController()
        try request("blocked", [try makeFile("c.txt")])
        c.ingestWaitRequests(in: dir)
        // 書き先を「フォルダ」で塞いで、書き込みの失敗を再現する。
        try FileManager.default.createDirectory(at: EditorWait.doneURL("blocked", in: dir),
                                                withIntermediateDirectories: true)
        c.closeDocument(at: 0)
        XCTAssertFalse(EditorWait.requestExists(id: "blocked", in: dir))
        let completion = EditorWait.awaitCompletion(id: "blocked", in: dir, appAlive: EditorWaitTests.alive(), sleep: { _ in })
        XCTAssertEqual(completion, .requestGone, "待ち手は、黙って待ち続けず、失敗で戻る")
    }
}
