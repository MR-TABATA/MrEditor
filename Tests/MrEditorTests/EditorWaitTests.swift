import XCTest
@testable import MrEditorCore

/// `mreditor --wait`（`$EDITOR` 対応）。画面に触れない部分だけを確かめる。
final class EditorWaitTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-wait-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `n` 回までは「アプリは生きている」、それを過ぎたら「いない」。
    /// **無限に待つテストにしない** —— 実装が壊れて完了が来なくなっても、ハングせず、失敗として落ちる。
    static func alive(_ n: Int = 200) -> () -> Bool {
        var calls = 0
        return { calls += 1; return calls <= n }
    }

    // MARK: 引数

    func testNoFlagIsNormalLaunch() {
        XCTAssertEqual(EditorWait.parse([]), .normal)
        XCTAssertEqual(EditorWait.parse(["a.txt"]), .normal)
    }

    func testWaitFlagsAreRecognized() {
        XCTAssertEqual(EditorWait.parse(["--wait", "a.txt"]), .wait(paths: ["a.txt"]))
        XCTAssertEqual(EditorWait.parse(["-w", "a.txt", "b.txt"]), .wait(paths: ["a.txt", "b.txt"]))
        // git は `mreditor --wait COMMIT_EDITMSG` と、フラグを先に渡す。後ろに付く形も受ける。
        XCTAssertEqual(EditorWait.parse(["a.txt", "--wait"]), .wait(paths: ["a.txt"]))
    }

    func testOtherFlagsAreDroppedAndDoubleDashMakesTheRestPaths() {
        XCTAssertEqual(EditorWait.parse(["--wait", "--foo", "a.txt"]), .wait(paths: ["a.txt"]))
        XCTAssertEqual(EditorWait.parse(["--wait", "--", "-odd-name.txt"]), .wait(paths: ["-odd-name.txt"]))
    }

    func testWaitWithoutPathsKeepsAnEmptyList() {
        XCTAssertEqual(EditorWait.parse(["--wait"]), .wait(paths: []))
    }

    // MARK: パスの検査

    func testValidateAcceptsPlainTextAndMakesPathsAbsolute() throws {
        let f = dir.appendingPathComponent("COMMIT_EDITMSG")
        try "msg".write(to: f, atomically: true, encoding: .utf8)
        let r = EditorWait.validate([f.path])
        XCTAssertTrue(r.problems.isEmpty)
        XCTAssertEqual(r.urls.map(\.path), [f.standardizedFileURL.path])
    }

    func testValidateReportsMissingDirectoryAndCompressed() throws {
        let gz = dir.appendingPathComponent("a.log")
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: gz)         // gzip の魔法の数（拡張子は嘘をつく）
        let zip = dir.appendingPathComponent("b.txt")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: zip)
        let missing = dir.appendingPathComponent("none.txt").path

        let r = EditorWait.validate([missing, dir.path, gz.path, zip.path])
        XCTAssertTrue(r.urls.isEmpty)
        XCTAssertEqual(r.problems, [.missing(missing), .directory(dir.path),
                                    .compressed(gz.path), .compressed(zip.path)])
    }

    func testAProblemInAnyPathIsReportedEvenIfOthersAreFine() throws {
        let ok = dir.appendingPathComponent("ok.txt")
        try "x".write(to: ok, atomically: true, encoding: .utf8)
        let r = EditorWait.validate([ok.path, dir.appendingPathComponent("no").path])
        XCTAssertEqual(r.urls.count, 1)
        XCTAssertEqual(r.problems.count, 1)
    }

    // MARK: 依頼ファイル

    func testRequestRoundTrip() throws {
        let req = EditorWait.Request(id: "abc", waiterPID: 4242, paths: ["/x/a.txt"])
        try EditorWait.write(req, in: dir)
        let got = EditorWait.pending(in: dir, isAlive: { _ in true })
        XCTAssertEqual(got, [req])
        // 書きかけの一時ファイルは残らない。
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".wait-abc.tmp").path))
    }

    func testRequestFilesAreOwnerOnly() throws {
        try EditorWait.write(.init(id: "p", waiterPID: 1, paths: ["/x"]), in: dir)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: EditorWait.requestURL("p", in: dir).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStaleRequestOfADeadWaiterIsRemovedAndNotReturned() throws {
        try EditorWait.write(.init(id: "dead", waiterPID: 99999, paths: ["/x"]), in: dir)
        XCTAssertEqual(EditorWait.pending(in: dir, isAlive: { _ in false }), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: EditorWait.requestURL("dead", in: dir).path))
    }

    func testRequestOwnedBySomeoneElseIsIgnored() throws {
        try EditorWait.write(.init(id: "other", waiterPID: 1, paths: ["/etc/passwd"]), in: dir)
        // 持ち主が自分でないものとして読む（別のユーザーが置いた依頼を再現）。
        let got = EditorWait.pending(in: dir, ownerID: getuid() &+ 1, isAlive: { _ in true })
        XCTAssertEqual(got, [])
        // 他人のものは、消しもしない。
        XCTAssertTrue(FileManager.default.fileExists(atPath: EditorWait.requestURL("other", in: dir).path))
    }

    func testRequestWhoseNameAndIdDisagreeIsIgnored() throws {
        let data = try JSONEncoder().encode(EditorWait.Request(id: "real", waiterPID: 1, paths: ["/x"]))
        try data.write(to: dir.appendingPathComponent("wait-fake.json"))
        XCTAssertEqual(EditorWait.pending(in: dir, isAlive: { _ in true }), [])
    }

    func testGarbageFileIsIgnored() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("wait-x.json"))
        XCTAssertEqual(EditorWait.pending(in: dir, isAlive: { _ in true }), [])
    }

    // MARK: 完了

    func testCompleteWritesTheStatusForTheWaiter() throws {
        try EditorWait.write(.init(id: "a", waiterPID: 1, paths: ["/x"]), in: dir)
        XCTAssertTrue(EditorWait.complete(id: "a", status: 0, in: dir))
        XCTAssertEqual(EditorWait.readStatus(id: "a", in: dir), 0)
    }

    func testCompleteDoesNothingWhenTheRequestIsGone() {
        // 待ち手が Ctrl-C で依頼を消したあとに、タブが閉じられた場合。
        XCTAssertFalse(EditorWait.complete(id: "gone", status: 0, in: dir))
        XCTAssertNil(EditorWait.readStatus(id: "gone", in: dir))
    }

    func testUnreadableStatusCountsAsFailureNotSuccess() throws {
        try Data("???".utf8).write(to: EditorWait.doneURL("g", in: dir))
        XCTAssertEqual(EditorWait.readStatus(id: "g", in: dir), EditorWait.exitFailure)
    }

    func testCleanupRemovesBothFiles() throws {
        try EditorWait.write(.init(id: "c", waiterPID: 1, paths: ["/x"]), in: dir)
        EditorWait.complete(id: "c", status: 0, in: dir)
        EditorWait.cleanup(id: "c", in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EditorWait.requestURL("c", in: dir).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: EditorWait.doneURL("c", in: dir).path))
    }

    // MARK: 待つ

    func testAwaitReturnsTheStatusOnceItAppears() throws {
        try EditorWait.write(.init(id: "w", waiterPID: 1, paths: ["/x"]), in: dir)
        var polls = 0
        let result = EditorWait.awaitCompletion(
            id: "w", in: dir, appAlive: Self.alive(), sleep: { _ in
                polls += 1
                if polls == 3 { EditorWait.complete(id: "w", status: 0, in: self.dir) }
            })
        XCTAssertEqual(result, .done(0))
        XCTAssertEqual(polls, 3)
    }

    func testAwaitReportsAppGoneOnlyAfterRepeatedMisses() throws {
        try EditorWait.write(.init(id: "none", waiterPID: 1, paths: ["/x"]), in: dir)
        var alive = [true, false, false, false]
        var sleeps = 0
        let result = EditorWait.awaitCompletion(
            id: "none", in: dir, appAlive: { alive.isEmpty ? false : alive.removeFirst() },
            deadLimit: 3, sleep: { _ in sleeps += 1 })
        XCTAssertEqual(result, .appGone)
        XCTAssertEqual(sleeps, 3)
    }

    func testASingleMissIsNotEnoughToGiveUp() throws {
        // 起動の直後は、アプリがまだ見えないことがある。
        try EditorWait.write(.init(id: "s", waiterPID: 1, paths: ["/x"]), in: dir)
        var seen = [false, true, true]
        var polls = 0
        let result = EditorWait.awaitCompletion(
            id: "s", in: dir, appAlive: { seen.isEmpty ? true : seen.removeFirst() },
            deadLimit: 3, sleep: { _ in
                polls += 1
                if polls == 4 { EditorWait.complete(id: "s", status: 0, in: self.dir) }
            })
        XCTAssertEqual(result, .done(0))
    }

    func testStatusWrittenJustBeforeTheAppDiesIsNotLost() throws {
        try EditorWait.write(.init(id: "r", waiterPID: 1, paths: ["/x"]), in: dir)
        var calls = 0
        let result = EditorWait.awaitCompletion(
            id: "r", in: dir, appAlive: {
                calls += 1
                // 3 回目の「いない」を数えた時点で、完了が書かれる（入れ違い）。
                if calls == 3 { EditorWait.complete(id: "r", status: 0, in: self.dir) }
                return false
            }, deadLimit: 3, sleep: { _ in })
        XCTAssertEqual(result, .done(0))
    }

    /// アプリが強制終了されて、完了の合図が無いまま、アプリが見えなくなり続ける → `.appGone`、終了コード 1。
    func testAppGoneWithoutAnyStatusEndsAsFailureWithAMessage() throws {
        try EditorWait.write(.init(id: "k", waiterPID: 1, paths: ["/x"]), in: dir)
        EditorWait.claim(id: "k", in: dir)
        let completion = EditorWait.awaitCompletion(id: "k", in: dir, appAlive: { false }, sleep: { _ in })
        XCTAssertEqual(completion, .appGone)
        let out = EditorWait.outcome(of: completion, id: "k", in: dir)
        XCTAssertEqual(out.status, EditorWait.exitFailure)
        XCTAssertNotNil(out.stderr)
    }

    /// 完了の合図を書けず、アプリが依頼を取り下げたとき、待ち手は黙って待ち続けず、1 で戻る。
    func testAwaitReturnsRequestGoneWhenTheRequestVanishesWithoutAStatus() throws {
        try EditorWait.write(.init(id: "g", waiterPID: 1, paths: ["/x"]), in: dir)
        var polls = 0
        let completion = EditorWait.awaitCompletion(id: "g", in: dir, appAlive: Self.alive(), sleep: { _ in
            polls += 1
            if polls == 2 { EditorWait.cleanup(id: "g", in: self.dir) }
        })
        XCTAssertEqual(completion, .requestGone)
        XCTAssertEqual(EditorWait.outcome(of: completion, id: "g", in: dir).status, EditorWait.exitFailure)
    }

    /// アプリが生きていても、依頼を受け取らないまま上限を過ぎたら、失敗で戻る（端末が固まって見えない）。
    func testAwaitGivesUpWhenTheAppNeverPicksTheRequestUp() throws {
        try EditorWait.write(.init(id: "u", waiterPID: 1, paths: ["/x"]), in: dir)
        var slept: TimeInterval = 0
        let completion = EditorWait.awaitCompletion(
            id: "u", in: dir, appAlive: Self.alive(), claimTimeout: 1, interval: 0.25,
            sleep: { slept += $0 })
        XCTAssertEqual(completion, .notPickedUp)
        XCTAssertEqual(slept, 1, accuracy: 0.001)
        XCTAssertEqual(EditorWait.outcome(of: completion, id: "u", in: dir).status, EditorWait.exitFailure)
    }

    /// 受け取られたあとは、いくら待っても、時間切れにしない（編集に使える時間の上限ではない）。
    func testAClaimedRequestIsNeverTimedOut() throws {
        try EditorWait.write(.init(id: "c", waiterPID: 1, paths: ["/x"]), in: dir)
        EditorWait.claim(id: "c", in: dir)
        var polls = 0
        let completion = EditorWait.awaitCompletion(
            id: "c", in: dir, appAlive: Self.alive(1000), claimTimeout: 1, interval: 0.25,
            sleep: { _ in
                polls += 1
                if polls == 100 { EditorWait.complete(id: "c", status: 0, in: self.dir) }
            })
        XCTAssertEqual(completion, .done(0))
        XCTAssertEqual(polls, 100)
    }

    // MARK: 完了の書き込み（失敗・文言）

    func testFinishWritesTheStatusAndAMessageForTheWaiter() throws {
        try EditorWait.write(.init(id: "m", waiterPID: 1, paths: ["/x"]), in: dir)
        XCTAssertTrue(EditorWait.finish(id: "m", status: 1, message: "mreditor: 開けません: /x", in: dir))
        XCTAssertEqual(EditorWait.readStatus(id: "m", in: dir), 1)
        XCTAssertEqual(EditorWait.readMessage(id: "m", in: dir), "mreditor: 開けません: /x")
        let out = EditorWait.outcome(of: .done(1), id: "m", in: dir)
        XCTAssertEqual(out.status, 1)
        XCTAssertEqual(out.stderr, "mreditor: 開けません: /x")
    }

    func testASuccessHasNoMessage() throws {
        try EditorWait.write(.init(id: "ok", waiterPID: 1, paths: ["/x"]), in: dir)
        EditorWait.finish(id: "ok", status: 0, in: dir)
        XCTAssertEqual(EditorWait.readStatus(id: "ok", in: dir), 0)
        XCTAssertEqual(EditorWait.readMessage(id: "ok", in: dir), "")
        XCTAssertNil(EditorWait.outcome(of: .done(0), id: "ok", in: dir).stderr)
    }

    /// 完了の合図を書けないとき（ここでは、書き先を「フォルダ」で塞いで再現）、待ち手を黙って待たせ続けず、
    /// 依頼を取り下げる。待ち手は `.requestGone` で、1 で戻る。
    func testFinishWithdrawsTheRequestWhenTheStatusCannotBeWritten() throws {
        try EditorWait.write(.init(id: "w", waiterPID: 1, paths: ["/x"]), in: dir)
        try FileManager.default.createDirectory(at: EditorWait.doneURL("w", in: dir), withIntermediateDirectories: true)
        XCTAssertFalse(EditorWait.finish(id: "w", status: 0, in: dir))
        XCTAssertFalse(EditorWait.requestExists(id: "w", in: dir), "書けなかったら、依頼を取り下げる")
        let completion = EditorWait.awaitCompletion(id: "w", in: dir, appAlive: Self.alive(), sleep: { _ in })
        XCTAssertEqual(completion, .requestGone)
    }

    func testFinishDoesNothingWhenTheWaiterIsAlreadyGone() {
        XCTAssertFalse(EditorWait.finish(id: "nobody", status: 0, in: dir))
        XCTAssertNil(EditorWait.readStatus(id: "nobody", in: dir))
    }

    // MARK: 受け取りの印・後片付け

    func testClaimMarksTheRequestAndCleanupRemovesEverything() throws {
        try EditorWait.write(.init(id: "z", waiterPID: 1, paths: ["/x"]), in: dir)
        XCTAssertFalse(EditorWait.isClaimed(id: "z", in: dir))
        EditorWait.claim(id: "z", in: dir)
        XCTAssertTrue(EditorWait.isClaimed(id: "z", in: dir))
        EditorWait.complete(id: "z", status: 0, in: dir)
        XCTAssertTrue(EditorWait.cleanup(id: "z", in: dir))
        for url in [EditorWait.requestURL("z", in: dir), EditorWait.doneURL("z", in: dir),
                    EditorWait.claimedURL("z", in: dir)] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
    }

    func testCleanupOfMissingFilesIsNotAFailure() {
        XCTAssertTrue(EditorWait.cleanup(id: "never-existed", in: dir))
    }

    // MARK: パスの検査（読めないもの・空のもの）

    func testAnUnreadableFileIsReportedNotWavedThrough() throws {
        try XCTSkipIf(getuid() == 0, "root は権限を無視して読める")
        let f = dir.appendingPathComponent("secret.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path) }
        let r = EditorWait.validate([f.path])
        XCTAssertTrue(r.urls.isEmpty)
        XCTAssertEqual(r.problems, [.unreadable(f.path)])
    }

    func testAnEmptyFileIsFine() throws {
        // 空の COMMIT_EDITMSG はあり得る。読めているので、問題にしない。
        let f = dir.appendingPathComponent("COMMIT_EDITMSG")
        FileManager.default.createFile(atPath: f.path, contents: Data())
        let r = EditorWait.validate([f.path])
        XCTAssertEqual(r.urls.count, 1)
        XCTAssertTrue(r.problems.isEmpty)
    }

    // MARK: 入口（`--wait` の引数の誤り）

    private func pendingRequestFiles() -> [String] {
        let d = EditorWait.defaultDirectory()
        return ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [])
            .filter { $0.hasPrefix("wait-") }.sorted()
    }

    func testEntryReturnsNilWithoutTheWaitFlag() {
        XCTAssertNil(EditorWait.runIfRequested(args: []))
        XCTAssertNil(EditorWait.runIfRequested(args: ["a.txt"]))
    }

    func testEntryFailsWithoutAnyFile() {
        let before = pendingRequestFiles()
        XCTAssertEqual(EditorWait.runIfRequested(args: ["--wait"]), EditorWait.exitFailure)
        XCTAssertEqual(pendingRequestFiles(), before, "依頼ファイルを作らない")
    }

    func testEntryFailsForAMissingPathAndLeavesNoRequest() {
        let before = pendingRequestFiles()
        let missing = dir.appendingPathComponent("nope.txt").path
        XCTAssertEqual(EditorWait.runIfRequested(args: ["--wait", missing]), EditorWait.exitFailure)
        XCTAssertEqual(pendingRequestFiles(), before, "依頼ファイルを作らない")
    }

    func testEntryFailsIfAnyOfSeveralPathsIsBad() throws {
        let ok = dir.appendingPathComponent("ok.txt")
        try "x".write(to: ok, atomically: true, encoding: .utf8)
        let before = pendingRequestFiles()
        let status = EditorWait.runIfRequested(args: ["-w", ok.path, dir.appendingPathComponent("no").path])
        XCTAssertEqual(status, EditorWait.exitFailure)
        XCTAssertEqual(pendingRequestFiles(), before)
    }

    // MARK: 終了時の判定（⌘Q）

    /// 確認で「キャンセル」されて終了しないときは、待ち手を解放しない。
    func testTerminateCancelledDoesNotReleaseWaiters() {
        var released = false
        let reply = AppDelegate.terminateReply(confirm: { false }, releaseWaiters: { released = true })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertFalse(released)
    }

    /// 終了すると決まったら、待ち手を解放してから終了する。
    func testTerminateConfirmedReleasesWaitersThenTerminates() {
        var order: [String] = []
        let reply = AppDelegate.terminateReply(confirm: { order.append("confirm"); return true },
                                               releaseWaiters: { order.append("release") })
        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(order, ["confirm", "release"])
    }

    // MARK: アプリの場所

    func testAppBundleIsFoundFromTheExecutable() {
        let exe = URL(fileURLWithPath: "/Applications/MrEditor.app/Contents/MacOS/MrEditor")
        XCTAssertEqual(EditorWait.appBundle(forExecutable: exe)?.path, "/Applications/MrEditor.app")
    }

    func testNoBundleForABareDevelopmentBinary() {
        XCTAssertNil(EditorWait.appBundle(forExecutable: URL(fileURLWithPath: "/tmp/x/.build/debug/MrEditor")))
    }

    // MARK: セッション復元

    func testWaitedTabsAreLeftOutOfTheSavedSessionAndTheActiveIndexFollows() {
        let docs: [(url: URL?, text: String?, draftID: String?, dirty: Bool)] = [
            (URL(fileURLWithPath: "/work/a.txt"), nil, nil, false),
            (URL(fileURLWithPath: "/work/.git/COMMIT_EDITMSG"), nil, nil, false),   // 待ち手のいるタブ
            (URL(fileURLWithPath: "/work/b.txt"), nil, nil, false),
        ]
        let s = SessionState.make(docs: docs, activeIndex: 2, excluded: [1])
        XCTAssertEqual(s.entries.map(\.path), ["/work/a.txt", "/work/b.txt"])
        XCTAssertEqual(s.activeIndex, 1)   // 除いたぶん、添字が 1 つずれる
    }

    func testTheActiveWaitedTabLeavesNoActiveIndex() {
        let docs: [(url: URL?, text: String?, draftID: String?, dirty: Bool)] = [
            (URL(fileURLWithPath: "/work/.git/COMMIT_EDITMSG"), nil, nil, false),
        ]
        let s = SessionState.make(docs: docs, activeIndex: 0, excluded: [0])
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertEqual(s.activeIndex, -1)
    }

    func testNothingIsExcludedByDefault() {
        let docs: [(url: URL?, text: String?, draftID: String?, dirty: Bool)] = [
            (URL(fileURLWithPath: "/work/a.txt"), nil, nil, false),
        ]
        XCTAssertEqual(SessionState.make(docs: docs, activeIndex: 0).entries.count, 1)
    }

    // MARK: 帳簿（アプリ側）

    func testBookReleasesWhenTheOnlyPaneCloses() {
        var book = WaitBook()
        let p = NSObject()
        XCTAssertTrue(book.register(request: "r1", panes: [ObjectIdentifier(p)]))
        XCTAssertTrue(book.isWaited(ObjectIdentifier(p)))
        XCTAssertEqual(book.paneClosed(ObjectIdentifier(p)), ["r1"])
        XCTAssertFalse(book.isWaited(ObjectIdentifier(p)))
        XCTAssertFalse(book.hasRequest("r1"))
    }

    func testBookReleasesMultiFileRequestOnlyWhenAllAreClosed() {
        var book = WaitBook()
        let a = NSObject(), b = NSObject()
        book.register(request: "r", panes: [ObjectIdentifier(a), ObjectIdentifier(b)])
        XCTAssertEqual(book.paneClosed(ObjectIdentifier(a)), [])
        XCTAssertTrue(book.hasRequest("r"))
        XCTAssertEqual(book.paneClosed(ObjectIdentifier(b)), ["r"])
    }

    func testBookSharesATabBetweenRequestsAndReleasesAll() {
        var book = WaitBook()
        let p = NSObject()
        book.register(request: "x", panes: [ObjectIdentifier(p)])
        book.register(request: "y", panes: [ObjectIdentifier(p)])
        XCTAssertEqual(book.paneClosed(ObjectIdentifier(p)), ["x", "y"])
    }

    func testBookIgnoresDuplicateRegistrationAndEmptyRequests() {
        var book = WaitBook()
        let p = NSObject()
        XCTAssertTrue(book.register(request: "d", panes: [ObjectIdentifier(p)]))
        XCTAssertFalse(book.register(request: "d", panes: [ObjectIdentifier(p)]))
        XCTAssertFalse(book.register(request: "e", panes: []))
        XCTAssertFalse(book.hasRequest("e"))
    }

    func testACompletedRequestIsNotRegisteredAgainWhileItsFileLingers() {
        // 依頼ファイルは待ち手が片付けるまで残る。そのあいだに通知で再走査されても、開き直さない。
        var book = WaitBook()
        let p = NSObject()
        book.register(request: "once", panes: [ObjectIdentifier(p)])
        XCTAssertEqual(book.paneClosed(ObjectIdentifier(p)), ["once"])
        XCTAssertTrue(book.isKnown("once"))
        XCTAssertFalse(book.register(request: "once", panes: [ObjectIdentifier(p)]))
        XCTAssertFalse(book.isWaited(ObjectIdentifier(p)))
    }

    func testAFailedRequestIsKnownSoItIsNotReopened() {
        var book = WaitBook()
        XCTAssertFalse(book.isKnown("bad"))
        book.markFailed(request: "bad")
        XCTAssertTrue(book.isKnown("bad"))
        XCTAssertFalse(book.register(request: "bad", panes: [ObjectIdentifier(NSObject())]))
    }

    func testClosingAnUnrelatedPaneReleasesNothing() {
        var book = WaitBook()
        // 両方を保持する（一時オブジェクトだと、解放されたアドレスが再利用されて同一視される）。
        let waited = NSObject(), other = NSObject()
        book.register(request: "r", panes: [ObjectIdentifier(waited)])
        XCTAssertEqual(book.paneClosed(ObjectIdentifier(other)), [])
        XCTAssertTrue(book.hasRequest("r"))
    }

    func testPendingIDsListOnlyRequestsStillWaiting() {
        var book = WaitBook()
        let a = NSObject(), b = NSObject()
        book.register(request: "r2", panes: [ObjectIdentifier(b)])
        book.register(request: "r1", panes: [ObjectIdentifier(a)])
        XCTAssertEqual(book.pendingIDs, ["r1", "r2"])
        book.paneClosed(ObjectIdentifier(a))
        XCTAssertEqual(book.pendingIDs, ["r2"])
    }

    func testAnAbandonedRequestCanBeForgottenAndItsTabBecomesOrdinaryAgain() {
        // Ctrl-C で依頼ファイルが消えたあと、アプリ側が取り下げる。
        var book = WaitBook()
        let p = NSObject()
        book.register(request: "gone", panes: [ObjectIdentifier(p)])
        book.forget(request: "gone")
        XCTAssertEqual(book.pendingIDs, [])
        XCTAssertFalse(book.isWaited(ObjectIdentifier(p)))       // 帯が消え、セッションにも残る
        XCTAssertTrue(book.isKnown("gone"))                      // 依頼ファイルが戻っても、開き直さない
        XCTAssertEqual(book.paneClosed(ObjectIdentifier(p)), []) // 閉じても、解放する相手はいない
    }

    func testRequestExistsFollowsTheFile() throws {
        XCTAssertFalse(EditorWait.requestExists(id: "q", in: dir))
        try EditorWait.write(.init(id: "q", waiterPID: 1, paths: ["/x"]), in: dir)
        XCTAssertTrue(EditorWait.requestExists(id: "q", in: dir))
        EditorWait.cleanup(id: "q", in: dir)
        XCTAssertFalse(EditorWait.requestExists(id: "q", in: dir))
    }

    func testQuittingReleasesEveryPendingRequestAndKeepsThemKnown() {
        var book = WaitBook()
        let a = NSObject(), b = NSObject()
        book.register(request: "r1", panes: [ObjectIdentifier(a)])
        book.register(request: "r2", panes: [ObjectIdentifier(a), ObjectIdentifier(b)])
        XCTAssertEqual(book.releaseAll(), ["r1", "r2"])
        XCTAssertFalse(book.isWaited(ObjectIdentifier(a)))
        XCTAssertFalse(book.hasRequest("r1"))
        // 完了した依頼は、ファイルが残っているあいだ、開き直されない。
        XCTAssertTrue(book.isKnown("r1"))
        XCTAssertEqual(book.releaseAll(), [])
    }

    func testQuittingWithNothingPendingReleasesNothing() {
        var book = WaitBook()
        XCTAssertEqual(book.releaseAll(), [])
    }

    func testForgetDropsTheRequestAndItsPaneMarks() {
        var book = WaitBook()
        let p = NSObject()
        book.register(request: "f", panes: [ObjectIdentifier(p)])
        book.forget(request: "f")
        XCTAssertFalse(book.hasRequest("f"))
        XCTAssertFalse(book.isWaited(ObjectIdentifier(p)))
    }
}
