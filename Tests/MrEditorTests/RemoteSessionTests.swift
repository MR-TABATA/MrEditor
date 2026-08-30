import XCTest
@testable import MrEditorCore

/// **実際に ssh を通す**試験。localhost へ鍵で入れる環境でだけ走り、
/// 入れなければ丸ごと skip する（CI や他人の機械で赤くしないため）。
///
/// ここで見たいのは 1 つだけ ―― **組み立てた文字列が、本物の ssh の向こうで
/// 意図どおりに動くか。** 手元の `/bin/sh` に通す試験（`RemoteFileTests`）では、
/// ssh の引数解釈・多重化・バイナリの受け渡しが確かめられない。
final class RemoteSessionTests: XCTestCase {

    private var fixture: URL!
    private var body: Data!

    override func setUpWithError() throws {
        try skipUnlessLocalSSHWorks()

        // テキストではないバイトを混ぜる。文字列に通すと化けるので、化けたら気づけるように。
        var bytes = [UInt8]()
        bytes.reserveCapacity(200_000)
        for i in 0..<200_000 {
            let v: Int = (i &* 37 &+ 11) & 0xFF
            bytes.append(UInt8(v))
        }
        body = Data(bytes)

        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-ssh-\(UUID().uuidString).bin")
        try body.write(to: fixture)
    }

    override func tearDown() {
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
        super.tearDown()
    }

    private func skipUnlessLocalSSHWorks() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "localhost", "true"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        try XCTSkipUnless(proc.terminationStatus == 0, "localhost へ鍵で ssh できないので飛ばす")
    }

    private func session() throws -> RemoteSession {
        let target = try XCTUnwrap(RemoteFile.parse("ssh localhost:\(fixture.path)"))
        return try RemoteSession.connect(to: target)
    }

    /// 繋いで、向こうに何が在るかを 1 往復で確かめる。
    func testConnectDetectsCapabilities() throws {
        let s = try session()
        XCTAssertTrue(s.capabilities.canRead)
        XCTAssertTrue(s.capabilities.canSize)
        XCTAssertTrue(s.capabilities.canFollow)
        XCTAssertTrue(s.capabilities.canFilter)
        XCTAssertTrue(s.capabilities.degraded.isEmpty)
    }

    func testSizeMatchesTheRealFile() throws {
        XCTAssertEqual(try session().size(), body.count)
    }

    /// **1 バイトもズレないこと。** `tail -c +N` の 1 始まりを間違えると、
    /// ここで初めて分かる（手元の sh では気づけても、ssh 越しは別経路）。
    func testRangeReadsAreByteExactOverSSH() throws {
        let s = try session()
        for probe in [0..<64, 1..<65, 100_000..<100_064, (body.count - 32)..<body.count] {
            let got = try XCTUnwrap(s.read(offset: probe.lowerBound, length: probe.count))
            XCTAssertEqual(got, body.subdata(in: probe), "範囲 \(probe) がズレた")
        }
    }

    /// 文字列に通していないこと。テキストでないバイトが置換文字に化けたら落ちる。
    func testBinaryBytesSurviveTheRoundTrip() throws {
        let s = try session()
        let got = try XCTUnwrap(s.read(offset: 0, length: 256))
        XCTAssertEqual(got.count, 256)
        XCTAssertEqual(got, body.subdata(in: 0..<256))
        XCTAssertTrue(got.contains(0x00) || got.contains(0xFF) || got.contains(0x80))
    }

    /// 末尾を越えて頼んでも、あるだけ返る（足りないのに埋めて返さない）。
    func testReadingPastTheEndReturnsWhatExists() throws {
        let s = try session()
        let got = try XCTUnwrap(s.read(offset: body.count - 10, length: 500))
        XCTAssertEqual(got, body.subdata(in: (body.count - 10)..<body.count))
    }

    /// 無いファイルは失敗する。**stderr をそのまま持つ**ので、人が読めば理由が分かる。
    func testMissingRemoteFileFailsLoudly() throws {
        let target = RemoteFile.Target(host: "localhost", path: "/nope/definitely/missing.log")
        let s = try RemoteSession.connect(to: target)
        XCTAssertNil(s.size())
        XCTAssertThrowsError(try RemoteSession.run(
            host: "localhost",
            command: RemoteFile.sizeCommand("/nope/definitely/missing.log"),
            timeout: 10
        )) { error in
            guard case RemoteSession.Failure.failed(_, let stderr) = error else {
                return XCTFail("failed(status:stderr:) を期待した: \(error)")
            }
            XCTAssertFalse(stderr.isEmpty, "理由を握り潰している")
        }
    }

    /// 引用符が向こうで効いていること。**空白入りのパスが 2 つの引数に割れない。**
    func testPathsWithSpacesWorkOverSSH() throws {
        let spaced = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor ssh \(UUID().uuidString).bin")
        try Data("hello world".utf8).write(to: spaced)
        defer { try? FileManager.default.removeItem(at: spaced) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: spaced.path))
        XCTAssertEqual(s.size(), 11)
        XCTAssertEqual(s.read(offset: 6, length: 5), Data("world".utf8))
    }

    // MARK: - 緩衝まで通す

    /// **端から端まで。** ssh → 範囲読み → 疎キャッシュ → mmap の全経路で、
    /// 中身が原本と 1 バイトも違わないこと。
    func testBufferOverSSHMatchesTheOriginal() throws {
        let s = try session()
        let buf = try XCTUnwrap(s.openBuffer())
        XCTAssertEqual(buf.count, body.count)

        XCTAssertEqual(buf.data(in: 0..<100), body.subdata(in: 0..<100))
        XCTAssertEqual(buf.data(in: 150_000..<150_100), body.subdata(in: 150_000..<150_100))

        // 見たぶんしか取っていない ＝ 落としていない
        XCTAssertLessThan(buf.fetchedBytes, body.count, "全部引いてしまっている")
    }

    // MARK: - 向こうで絞る（実 ssh）

    /// **これが遠隔の主目的。** 一致行と行番号が返り、本文は転送されない。
    func testGrepOverSSHReturnsLineNumbers() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-grep-\(UUID().uuidString).log")
        var text = ""
        for i in 1...5000 {
            text += (i == 1234 || i == 4321) ? "line \(i) ERROR boom\n" : "line \(i) ok\n"
        }
        try Data(text.utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: log.path))
        let hits = try XCTUnwrap(s.grep(pattern: "ERROR"))
        XCTAssertEqual(hits.filter(\.isMatch).map(\.line), [1234, 4321])
        XCTAssertTrue(hits[0].text.contains("ERROR boom"))
    }

    /// **当たりの意味は、たいてい直前の行にある。** `-C` が向こうで効くこと。
    func testGrepWithContextOverSSH() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-ctx-\(UUID().uuidString).log")
        let text = (1...20).map { $0 == 10 ? "line 10 NEEDLE\n" : "line \($0)\n" }.joined()
        try Data(text.utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: log.path))
        let hits = try XCTUnwrap(s.grep(pattern: "NEEDLE", context: 2))
        XCTAssertEqual(hits.map(\.line), [8, 9, 10, 11, 12])
        XCTAssertEqual(hits.filter(\.isMatch).map(\.line), [10])
    }

    /// 一致ゼロは「失敗」ではなく「空」。
    func testGrepWithNoMatchesIsEmptyNotFailure() throws {
        let s = try session()
        XCTAssertEqual(s.grep(pattern: "この語は絶対に無い-\(UUID().uuidString)")?.count, 0)
    }

    /// 既定は固定文字列 ―― `.` を含む語が正規表現として暴れない。
    func testGrepTreatsPatternAsFixedStringByDefault() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-fixed-\(UUID().uuidString).log")
        try Data("aXc\na.c\n".utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: log.path))
        let hits = try XCTUnwrap(s.grep(pattern: "a.c"))
        XCTAssertEqual(hits.map(\.line), [2], "固定文字列のはずが aXc にも当たった")
    }

}
