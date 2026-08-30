import XCTest
@testable import MrEditorCore

/// **実際に ssh 越しで `tail -f` を走らせる。** localhost へ鍵で入れるときだけ。
///
/// ここでしか出ない事故が 2 つある ―― 追った行が届かないこと、
/// そして**止めたのに向こうで動き続けること。**
final class RemoteFollowerTests: XCTestCase {

    private var log: URL!

    override func setUpWithError() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "localhost", "true"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
        try XCTSkipUnless(proc.terminationStatus == 0, "localhost へ鍵で ssh できないので飛ばす")

        log = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-follow-\(UUID().uuidString).log")
        try Data("start\n".utf8).write(to: log)
    }

    override func tearDown() {
        if let log { try? FileManager.default.removeItem(at: log) }
        super.tearDown()
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// 追記した行が届く。
    func testFollowDeliversAppendedLines() throws {
        let follower = RemoteFollower(target: RemoteFile.Target(host: "localhost", path: log.path))
        let got = expectation(description: "追記が届く")
        var seen: [String] = []
        follower.onLines = { lines in
            seen += lines
            if seen.contains("appended-2") { got.fulfill() }
        }
        follower.start(fromBytes: 0)
        defer { follower.stop() }

        // tail -f が向こうで立ち上がるのを待ってから書く
        Thread.sleep(forTimeInterval: 2.0)
        try append("appended-1\nappended-2\n")

        wait(for: [got], timeout: 20)
        XCTAssertTrue(seen.contains("appended-1"))
        XCTAssertTrue(seen.contains("appended-2"))
    }

    /// **止めたら向こうも止まる。** ssh を切れば `tail -f` は道連れになる。
    func testStopEndsTheRemoteProcess() throws {
        let follower = RemoteFollower(target: RemoteFile.Target(host: "localhost", path: log.path))
        let ended = expectation(description: "終わる")
        follower.onEnd = { ended.fulfill() }
        follower.start(fromBytes: 0)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(follower.isRunning)

        follower.stop()
        wait(for: [ended], timeout: 15)
        XCTAssertFalse(follower.isRunning)
    }

    /// 二重に起動しない ―― 同じ行が 2 回並ぶ。
    func testStartingTwiceDoesNotDoubleUp() throws {
        let follower = RemoteFollower(target: RemoteFile.Target(host: "localhost", path: log.path))
        follower.start(fromBytes: 0)
        Thread.sleep(forTimeInterval: 1.5)
        follower.start(fromBytes: 0)   // 2 回目は何もしないこと
        XCTAssertTrue(follower.isRunning)
        follower.stop()
    }
}
