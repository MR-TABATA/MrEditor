import XCTest
@testable import MrEditorCore

/// 入口 —— パイプと圧縮。
///
/// 「巨大なログを見る」道具なのに、そのログは素のファイルとして転がっていないことが
/// 多い。ここが塞がっていると、中の機能はどれも届かない。
final class IntakeTests: XCTestCase {

    // MARK: 標準入力がパイプかどうか

    func testAPipeIsAccepted() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertTrue(Intake.stdinIsPiped(fds[0]))
    }

    func testARedirectedFileIsAccepted() throws {
        // `mreditor < app.log` も受ける。パイプと同じく「渡された」なので。
        let url = Intake.scratchURL(named: "intake-test-\(UUID().uuidString)")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY)
        defer { close(fd) }
        XCTAssertTrue(Intake.stdinIsPiped(fd))
    }

    func testDevNullIsNotAPipe() throws {
        // **これが本題。** Finder や Dock から起動すると標準入力は /dev/null で、
        // 端末ではないので isatty だけでは真になる。受け取ってしまうと、毎回の起動で
        // 空のタブが増える。
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        XCTAssertFalse(Intake.stdinIsPiped(fd))
    }

    // MARK: gzip の判定は中身で

    func testGzipIsDetectedByItsMagicNumber() {
        XCTAssertTrue(Intake.isGzip([0x1f, 0x8b, 0x08, 0x00]))
    }

    func testExtensionsAreNotTrusted() {
        // `.gz` なのに素のテキスト（展開済みなのに名前だけ残っている）は実際にある。
        // 中身で見るので、そういうファイルはそのまま開く。
        XCTAssertFalse(Intake.isGzip(Array("2026-08-28 ERROR".utf8)))
        XCTAssertFalse(Intake.isGzip([0x1f]))          // 1 バイトしか読めなかった
        XCTAssertFalse(Intake.isGzip([]))              // 空ファイル
    }

    // MARK: 展開

    func testGunzipExpandsAndKeepsTheOriginalName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plain = dir.appendingPathComponent("app.log")
        try "2026-08-28 ERROR boom\n".write(to: plain, atomically: true, encoding: .utf8)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = [plain.path]
        try gzip.run(); gzip.waitUntilExit()

        let expanded = try XCTUnwrap(Intake.gunzip(dir.appendingPathComponent("app.log.gz")))
        defer { try? FileManager.default.removeItem(at: expanded) }
        XCTAssertEqual(try String(contentsOf: expanded, encoding: .utf8), "2026-08-28 ERROR boom\n")
        // タブに出る名前は元のまま。一時ファイルの乱数名だと何を見ているか分からない。
        XCTAssertEqual(expanded.lastPathComponent, "app.log")
    }

    func testGunzipReturnsNilForSomethingThatIsNotGzip() throws {
        let url = Intake.scratchURL(named: "not-gzip-\(UUID().uuidString).gz")
        try "plain text".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(Intake.gunzip(url))
    }
}
