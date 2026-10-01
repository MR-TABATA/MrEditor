import XCTest
@testable import MrEditorCore

/// 1 行の書き換え（B12）を、**本物の `/bin/sh` に通して**確かめる。
/// 向こう側も POSIX sh なので、サーバーを立てずに挙動を固定できる。
/// 間違えたときの被害は「保存できない」ではなく「別の行を壊す」なので、止まる側を厚くする。
final class RemoteEditTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func make(_ content: String, name: String = "app.log") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 組んだコマンドを手元で走らせ、終了コードを返す。
    @discardableResult
    private func run(_ path: String, line: Int, old: String, new: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", RemoteFile.replaceLineCommand(path, line: line, old: old, new: new)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 同じ長さ ＝ その場で上書き

    func testSameLengthOverwritesInPlaceAndKeepsInode() throws {
        let url = try make("alpha\nbravo\ncharlie\n")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        let status = try run(url.path, line: 2, old: "bravo", new: "BRAVO")

        XCTAssertEqual(status, RemoteFile.EditOutcome.overwrote.rawValue)
        XCTAssertEqual(try read(url), "alpha\nBRAVO\ncharlie\n")
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "その場の上書きなので inode は変わらない")
    }

    /// バイト長で見る。「あ」は 3 バイトなので、文字数が同じでも長さが違う。
    func testSameByteLengthWithMultibyteText() throws {
        let url = try make("あいう\nxyz\n")
        XCTAssertEqual(try run(url.path, line: 1, old: "あいう", new: "かきく"), 0)
        XCTAssertEqual(try read(url), "かきく\nxyz\n")
    }

    // MARK: - 長さが変わる ＝ 作り直し

    func testLongerReplacementRewrites() throws {
        let url = try make("alpha\nbravo\ncharlie\n")
        let status = try run(url.path, line: 2, old: "bravo", new: "bravo-and-more")
        XCTAssertEqual(status, RemoteFile.EditOutcome.rewrote.rawValue)
        XCTAssertEqual(try read(url), "alpha\nbravo-and-more\ncharlie\n")
    }

    func testShorterReplacementRewrites() throws {
        let url = try make("alpha\nbravo\ncharlie\n")
        XCTAssertEqual(try run(url.path, line: 3, old: "charlie", new: "c"), 20)
        XCTAssertEqual(try read(url), "alpha\nbravo\nc\n")
    }

    func testRewriteKeepsPermissionsAndLeavesNoTempFile() throws {
        let url = try make("a\nb\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        XCTAssertEqual(try run(url.path, line: 1, old: "a", new: "longer"), 20)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o640)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["app.log"], "一時ファイルを残さない")
    }

    func testFirstLineAndLastLineWithoutTrailingNewline() throws {
        let url = try make("first\nmiddle\nlast")
        XCTAssertEqual(try run(url.path, line: 1, old: "first", new: "1st"), 20)
        XCTAssertEqual(try read(url), "1st\nmiddle\nlast")
        XCTAssertEqual(try run(url.path, line: 3, old: "last", new: "the very last"), 20)
        XCTAssertEqual(try read(url), "1st\nmiddle\nthe very last", "末尾に改行が無いファイルに改行を足さない")
    }

    func testClearingALineKeepsTheNewline() throws {
        let url = try make("a\nbb\nc\n")
        XCTAssertEqual(try run(url.path, line: 2, old: "bb", new: ""), 20)
        XCTAssertEqual(try read(url), "a\n\nc\n")
    }

    func testFillingAnEmptyLine() throws {
        let url = try make("a\n\nc\n")
        XCTAssertEqual(try run(url.path, line: 2, old: "", new: "b"), 20)
        XCTAssertEqual(try read(url), "a\nb\nc\n")
    }

    /// 引用符・`$`・バッククォート・`%`・バックスラッシュが、命令にならず文字のまま書かれる。
    func testHostileTextIsWrittenLiterally() throws {
        let url = try make("x\nplaceholder\n")
        let nasty = "it's $(rm -rf /tmp/never) `id` 100% \\n \"q\" ; echo hi"
        XCTAssertEqual(try run(url.path, line: 2, old: "placeholder", new: nasty), 20)
        XCTAssertEqual(try read(url), "x\n\(nasty)\n")
    }

    // MARK: - 止まる（書かない）

    /// 開いてから向こうが変わっていた。別の行を壊す前に止める。
    func testConflictWhenLineDiffersFromWhatWasOpened() throws {
        let url = try make("alpha\nCHANGED\ncharlie\n")
        let status = try run(url.path, line: 2, old: "bravo", new: "x")
        XCTAssertEqual(status, RemoteFile.EditOutcome.conflict.rawValue)
        XCTAssertEqual(try read(url), "alpha\nCHANGED\ncharlie\n")
    }

    /// 行がずれた（上に 1 行足された）場合も、本文が合わなければ止まる。
    func testConflictWhenLinesShifted() throws {
        let url = try make("new first line\nalpha\nbravo\n")
        XCTAssertEqual(try run(url.path, line: 2, old: "bravo", new: "x"), 10)
        XCTAssertEqual(try read(url), "new first line\nalpha\nbravo\n")
    }

    /// 旧本文が先頭だけ合っていても通さない（前方一致で通すと、長い行の後半を壊す）。
    func testPrefixOfLongerLineIsNotAMatch() throws {
        let url = try make("abcdef\n")
        XCTAssertEqual(try run(url.path, line: 1, old: "abc", new: "xyz"), 10)
        XCTAssertEqual(try read(url), "abcdef\n")
    }

    func testMissingLineIsReported() throws {
        let url = try make("a\n")
        XCTAssertEqual(try run(url.path, line: 5, old: "", new: "x"), RemoteFile.EditOutcome.noSuchLine.rawValue)
        XCTAssertEqual(try read(url), "a\n")
    }

    func testSymlinkIsRefused() throws {
        let real = try make("a\n", name: "real.log")
        let link = dir.appendingPathComponent("link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(try run(link.path, line: 1, old: "a", new: "b"), RemoteFile.EditOutcome.notWritable.rawValue)
        XCTAssertEqual(try read(real), "a\n")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "リンクのまま残る")
    }

    func testReadOnlyFileIsRefused() throws {
        let url = try make("a\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        XCTAssertEqual(try run(url.path, line: 1, old: "a", new: "b"), RemoteFile.EditOutcome.notWritable.rawValue)
        XCTAssertEqual(try read(url), "a\n")
    }

    func testMissingFileIsRefused() throws {
        XCTAssertEqual(
            try run(dir.appendingPathComponent("nope.log").path, line: 1, old: "a", new: "b"),
            RemoteFile.EditOutcome.notWritable.rawValue
        )
    }

    /// 同じフォルダに一時ファイルを作れないとき、長さが変わる編集だけが断られ、
    /// 同じ長さの編集は通る。
    func testRewriteIsRefusedWhenDirectoryIsNotWritableButSameLengthStillWorks() throws {
        let url = try make("a\nb\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        guard !FileManager.default.isWritableFile(atPath: dir.appendingPathComponent("probe").path) else {
            throw XCTSkip("root で動いているため、フォルダの書き込み禁止が効かない")
        }

        XCTAssertEqual(try run(url.path, line: 1, old: "a", new: "longer"), RemoteFile.EditOutcome.cannotCreateTemp.rawValue)
        XCTAssertEqual(try read(url), "a\nb\n")
        XCTAssertEqual(try run(url.path, line: 1, old: "a", new: "z"), 0)
        XCTAssertEqual(try read(url), "z\nb\n")
    }

    // MARK: - 組み立て

    /// ログインシェルが fish / csh でも動くよう、全体を `sh -c` に包む。
    func testCommandIsWrappedInShC() {
        XCTAssertTrue(RemoteFile.replaceLineCommand("/a", line: 1, old: "x", new: "y").hasPrefix("sh -c '"))
    }

    func testOutcomeCodesAreStable() {
        // 向こうのスクリプトと対になる値。変えるときは両方を直す。
        XCTAssertEqual(RemoteFile.EditOutcome.conflict.rawValue, 10)
        XCTAssertEqual(RemoteFile.EditOutcome.rewrote.rawValue, 20)
    }
}
