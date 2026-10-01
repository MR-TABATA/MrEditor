import XCTest
@testable import MrEditorCore

/// 1 行の書き換え（B12）を、**実際に ssh を通して**確かめる。
/// 鍵で入れる ssh 先がある環境でだけ走る。宛先は `MRED_SSH_TEST_HOST`（既定は localhost。
/// `~/.ssh/config` の別名でもよい）。
final class RemoteEditSessionTests: XCTestCase {

    private var fixture: URL!
    private var host: String { ProcessInfo.processInfo.environment["MRED_SSH_TEST_HOST"] ?? "localhost" }

    override func setUpWithError() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "true"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        try XCTSkipUnless(proc.terminationStatus == 0, "\(host) へ鍵で ssh できないので飛ばす")

        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-edit-\(UUID().uuidString).log")
        try "alpha\nbravo\ncharlie\n".write(to: fixture, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
        super.tearDown()
    }

    private func session() throws -> RemoteSession {
        try RemoteSession.connect(to: RemoteFile.Target(host: host, path: fixture.path))
    }

    func testSameLengthEditOverSsh() throws {
        let outcome = try session().replaceLine(2, old: "bravo", new: "BRAVO")
        XCTAssertEqual(outcome, .overwrote)
        XCTAssertEqual(try String(contentsOf: fixture, encoding: .utf8), "alpha\nBRAVO\ncharlie\n")
    }

    func testLengthChangingEditOverSsh() throws {
        let outcome = try session().replaceLine(3, old: "charlie", new: "日本語 — it's 100% $(x)")
        XCTAssertEqual(outcome, .rewrote)
        XCTAssertEqual(try String(contentsOf: fixture, encoding: .utf8), "alpha\nbravo\n日本語 — it's 100% $(x)\n")
    }

    func testConflictOverSshWritesNothing() throws {
        let s = try session()
        try "alpha\nCHANGED\ncharlie\n".write(to: fixture, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try s.replaceLine(2, old: "bravo", new: "x")) { error in
            XCTAssertEqual((error as? RemoteSession.EditFailure)?.outcome, .conflict)
        }
        XCTAssertEqual(try String(contentsOf: fixture, encoding: .utf8), "alpha\nCHANGED\ncharlie\n")
    }
}
