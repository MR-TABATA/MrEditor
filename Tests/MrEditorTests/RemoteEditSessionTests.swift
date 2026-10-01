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

/// フォルダの種類・一覧・名前検索を、実際に ssh を通して確かめる。
final class RemoteDirectorySessionTests: XCTestCase {

    private var dir: URL!
    private var host: String { ProcessInfo.processInfo.environment["MRED_SSH_TEST_HOST"] ?? "localhost" }

    override func setUpWithError() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "true"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
        try XCTSkipUnless(proc.terminationStatus == 0, "\(host) へ鍵で ssh できないので飛ばす")

        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mreditor-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try "x\n".write(to: dir.appendingPathComponent("logs/app.log"), atomically: true, encoding: .utf8)
        try "y\n".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    func testDirectoryIsReportedAsDirectory() throws {
        let s = try RemoteSession.connect(to: .init(host: host, path: dir.path))
        XCTAssertEqual(s.kind, .directory)
    }

    func testMissingAndFileKinds() throws {
        XCTAssertThrowsError(try RemoteSession.connect(to: .init(host: host, path: dir.appendingPathComponent("nope").path))) {
            XCTAssertEqual($0 as? RemoteSession.Failure, .missing)
        }
        let s = try RemoteSession.connect(to: .init(host: host, path: dir.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(s.kind, .file)
    }

    func testListAndFindOverSsh() throws {
        let listed = try RemoteSession.listDirectory(host: host, path: dir.path)
        XCTAssertEqual(Set(listed.entries.map(\.name)), ["logs", "notes.txt"])
        XCTAssertEqual(listed.entries.first { $0.name == "logs" }?.isDirectory, true)

        let found = try RemoteSession.findFiles(host: host, root: dir.path, term: "APP")
        XCTAssertEqual(found.paths, ["logs/app.log"])
    }
}
