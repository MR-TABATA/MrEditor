import XCTest
@testable import MrEditorCore

/// `RemoteFile` の、繋がずに決まる部分。**サーバーを立てずに固定できるものは全部ここで固定する。**
/// 向こうで走る文字列を間違えると、被害は「開けない」ではなく「1 バイトずれた本文を平然と出す」。
final class RemoteFileTests: XCTestCase {

    // MARK: - 宛先の割り方

    func testParsesSshPrefixedTarget() {
        XCTAssertEqual(
            RemoteFile.parse("ssh web01:/var/log/app.log"),
            RemoteFile.Target(host: "web01", path: "/var/log/app.log")
        )
    }

    func testParsesBareHostColonPath() {
        XCTAssertEqual(
            RemoteFile.parse("user@web01:/var/log/app.log"),
            RemoteFile.Target(host: "user@web01", path: "/var/log/app.log")
        )
    }

    /// 相対パスは受けない。向こうのカレントディレクトリは人に見えず、`~` の展開も
    /// シェル任せで揺れる ＝「開いたつもりの場所」と実際がズレる。
    func testRejectsRelativeRemotePath() {
        XCTAssertNil(RemoteFile.parse("web01:var/log/app.log"))
        XCTAssertNil(RemoteFile.parse("web01:~/app.log"))
    }

    /// Windows のドライブレターを遠隔だと思わない。
    func testRejectsWindowsDriveLetter() {
        XCTAssertNil(RemoteFile.parse("C:/Users/hitoshi/app.log"))
    }

    func testLocalPathIsNotRemote() {
        XCTAssertNil(RemoteFile.parse("/var/log/app.log"))
        XCTAssertNil(RemoteFile.parse("app.log"))
    }

    // MARK: - 向こうで走る文字列

    /// 包まないと、パスが命令になる。
    ///
    /// **本物のシェルに通して往復させる。** 目視で「引用符が付いている」ことを確かめても、
    /// 実際に `sh` がどう割るかは別の話なので。向こう側も POSIX sh なので、これで足りる。
    func testShellQuoteSurvivesRealShellRoundTrip() throws {
        let nasty = [
            "/tmp/a'; rm -rf /tmp/should-not-exist; echo '",
            "/var/log/my app.log",
            "/tmp/$(whoami)/x.log",
            "/tmp/`id`/x.log",
            "/tmp/a\"b\"c.log",
            "/tmp/a\\b.log",
            "/tmp/tab\tsep.log",
        ]
        for path in nasty {
            let out = try shell("printf '%s' \(RemoteFile.shellQuote(path))")
            XCTAssertEqual(out, path, "引用が壊れた: \(path)")
        }
    }

    /// 組み立てたコマンドが、向こうで**そのパスだけ**を見に行くことを実地で確かめる。
    /// ssh の向こうも sh なので、手元の sh で同じ文字列を走らせれば意味は同じ。
    func testReadCommandReadsTheRightBytesThroughRealShell() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-read-\(UUID().uuidString).log")
        let body = "0123456789abcdefghij"
        try Data(body.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try shell(RemoteFile.readCommand(url.path, offset: 0, length: 5)), "01234")
        XCTAssertEqual(try shell(RemoteFile.readCommand(url.path, offset: 10, length: 5)), "abcde")
        // 末尾を越えて要求しても、あるだけ返る（足りないと嘘をつかない）
        XCTAssertEqual(try shell(RemoteFile.readCommand(url.path, offset: 18, length: 99)), "ij")
    }

    func testSizeCommandReturnsRealByteCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-size-\(UUID().uuidString).log")
        try Data(repeating: 0x41, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(RemoteFile.parseSize(try shell(RemoteFile.sizeCommand(url.path))), 4096)
    }

    /// **BSD の `wc` は先頭を空白で詰め、末尾に改行を付ける。** GNU は詰めない。
    /// 実シェルに通して初めて出た違いなので、両方を固定しておく。
    func testParseSizeAcceptsBothBsdAndGnuFormats() {
        XCTAssertEqual(RemoteFile.parseSize("    4096\n"), 4096)   // BSD
        XCTAssertEqual(RemoteFile.parseSize("4096\n"), 4096)       // GNU
        XCTAssertEqual(RemoteFile.parseSize("4096"), 4096)
    }

    /// 読めなければ「不明」。**0 とは書かない**（取れなかったと 0 バイトは違う）。
    func testParseSizeReturnsNilRatherThanZero() {
        XCTAssertNil(RemoteFile.parseSize(""))
        XCTAssertNil(RemoteFile.parseSize("wc: /nope: No such file\n"))
        XCTAssertNil(RemoteFile.parseSize("4096 /var/log/app.log\n"))  // `<` を忘れると名前が付く
    }

    /// 向こうで走るのと同じ `/bin/sh -c`。
    private func shell(_ command: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testShellQuoteHandlesSpaces() {
        XCTAssertEqual(RemoteFile.shellQuote("/var/log/my app.log"), "'/var/log/my app.log'")
    }

    /// `tail -c +N` は 1 始まり。**ここを間違えると 1 バイトずれた本文が出る。**
    func testReadCommandOffsetIsOneBased() {
        XCTAssertEqual(
            RemoteFile.readCommand("/var/log/app.log", offset: 100, length: 4096),
            "tail -c +101 < '/var/log/app.log' | head -c 4096"
        )
    }

    /// 先頭からなら tail を挟まない（大きなファイルで数え直させない）。
    func testReadCommandFromStartSkipsTail() {
        XCTAssertEqual(
            RemoteFile.readCommand("/var/log/app.log", offset: 0, length: 65_536),
            "head -c 65536 < '/var/log/app.log'"
        )
    }

    func testSizeCommandUsesWcNotStat() {
        // stat は BSD と GNU で書式が違う。wc -c は POSIX。
        let cmd = RemoteFile.sizeCommand("/var/log/app.log")
        XCTAssertEqual(cmd, "wc -c < '/var/log/app.log'")
        XCTAssertFalse(cmd.contains("stat"))
    }

    // MARK: - 能力検出

    func testCapabilitiesParsesPresentCommands() {
        let caps = RemoteFile.Capabilities.parse("wc\nhead\ntail\ngrep\n")
        XCTAssertTrue(caps.canRead)
        XCTAssertTrue(caps.canSize)
        XCTAssertTrue(caps.canFollow)
        XCTAssertTrue(caps.canFilter)
        XCTAssertTrue(caps.degraded.isEmpty)
    }

    /// BusyBox や制限シェルで欠ける場合。**畳むが、理由を必ず出す。**
    func testCapabilitiesReportsWhatItFoldedAndWhy() {
        let caps = RemoteFile.Capabilities.parse("head\n")
        XCTAssertTrue(caps.canRead)          // 読むことはできる
        XCTAssertFalse(caps.canSize)
        XCTAssertFalse(caps.canFollow)
        XCTAssertFalse(caps.canFilter)
        XCTAssertEqual(caps.degraded.count, 3)
        XCTAssertTrue(caps.degraded.allSatisfy { $0.contains("ありません") })
    }

    /// `head` が無ければ 1 バイトも取り出せない ＝ 開けない。
    func testCapabilitiesWithoutHeadCannotRead() {
        XCTAssertFalse(RemoteFile.Capabilities.parse("wc\ntail\n").canRead)
    }

    func testCapabilityCommandAsksEverythingInOneRoundTrip() {
        let cmd = RemoteFile.capabilityCommand()
        for name in ["wc", "head", "tail", "grep"] {
            XCTAssertTrue(cmd.contains("command -v \(name)"), "\(name) を訊いていない")
        }
        XCTAssertFalse(cmd.contains("\n"), "1 回の接続で訊く（改行で分けない）")
    }

    // MARK: - ssh の引数

    /// **ソケットのパス長で死なないこと。** macOS の `sun_path` は 104 で、
    /// `NSTemporaryDirectory()`（`/var/folders/…`）＋ `%C` の展開で実際に溢れた
    /// ―― 実 ssh を通して初めて出たので、長さの条件をここに固定する。
    func testControlPathFitsInAUnixSocket() {
        let path = RemoteFile.controlPath()
        XCTAssertTrue(
            RemoteFile.controlPathFits(path),
            "ControlPath が長すぎる（\(path.utf8.count) + 展開分 > \(RemoteFile.socketPathLimit)）: \(path)"
        )
        XCTAssertFalse(path.hasPrefix("/var/folders"), "長い一時ディレクトリを使っている")
    }

    /// 長すぎる場合は多重化を諦める。**速さのための仕掛けで、無くても読める。**
    func testTooLongControlPathDisablesMultiplexingRatherThanFailing() {
        XCTAssertFalse(RemoteFile.controlPathFits(String(repeating: "x", count: 100)))
    }

    /// `ssh_config` を殺さない。足すのは多重化と「端末を要求しない」ことだけ。
    func testSshArgumentsMultiplexAndDoNotKillUserConfig() {
        let args = RemoteFile.sshArguments(host: "web01", remoteCommand: "wc -c < '/a'")
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("-T"))
        XCTAssertEqual(args.last, "wc -c < '/a'")
        XCTAssertEqual(args[args.count - 2], "web01")
        // BatchMode を付けるとパスワード認証と未知のホスト鍵で即死する（SSH_ASKPASS で訊く）
        XCTAssertFalse(args.contains { $0.contains("BatchMode") })
        // ユーザーの設定を無視しない
        XCTAssertFalse(args.contains("-F"))
    }

    // MARK: - 向こうで絞る

    /// 当たりは `:`、`-C` で付いてきた前後は `-`。
    func testParseGrepSeparatesMatchesFromContext() {
        let out = "10-before\n11:hit\n12-after\n--\n99:another\n"
        let m = RemoteFile.parseGrep(out)
        XCTAssertEqual(m.map(\.line), [10, 11, 12, 99])
        XCTAssertEqual(m.map(\.isMatch), [false, true, false, true])
        XCTAssertEqual(m[1].text, "hit")
    }

    /// **本文にも `:` は普通に入る。** 最初の区切りだけで割らないと、
    /// URL やタイムスタンプを含む行が壊れる。
    func testParseGrepSplitsOnFirstSeparatorOnly() {
        let m = RemoteFile.parseGrep("42:12:34:56 GET https://x/y?a=1\n")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].line, 42)
        XCTAssertEqual(m[0].text, "12:34:56 GET https://x/y?a=1")
    }

    func testParseGrepIgnoresGroupSeparatorsAndBlanks() {
        XCTAssertTrue(RemoteFile.parseGrep("--\n\n").isEmpty)
    }

    /// 行番号が無い出力は捨てる（`-n` を忘れた場合など、意味を作らない）。
    func testParseGrepDropsLinesWithoutNumbers() {
        XCTAssertTrue(RemoteFile.parseGrep("grep: /nope: No such file or directory\n").isEmpty)
    }

    /// 既定は固定文字列。`.` や `*` を含む語をそのまま探せる。
    func testGrepCommandDefaultsToFixedStrings() {
        let cmd = RemoteFile.grepCommand("/a.log", pattern: "a.b*c")
        XCTAssertTrue(cmd.contains(" -F "))
        XCTAssertFalse(cmd.contains(" -E "))
        XCTAssertTrue(cmd.contains("-n"))
    }

    func testGrepCommandRegexAndContextAndCase() {
        let cmd = RemoteFile.grepCommand("/a.log", pattern: "ERR(OR)?", context: 3, ignoreCase: true, regex: true)
        XCTAssertTrue(cmd.contains(" -E "))
        XCTAssertTrue(cmd.contains("-i"))
        XCTAssertTrue(cmd.contains("-C 3"))
    }

    /// 一致ゼロで grep は 1 を返す。**「無かった」は失敗ではない**ので握る。
    func testGrepCommandSwallowsNoMatchExitCode() {
        XCTAssertTrue(RemoteFile.grepCommand("/a.log", pattern: "x").hasSuffix("|| true"))
    }

    /// パターンも包む。`-e` を使うので `-v` のような語でも旗と誤解されない。
    func testGrepCommandQuotesPatternAndUsesDashE() {
        let cmd = RemoteFile.grepCommand("/a.log", pattern: "'; rm -rf /; echo '")
        XCTAssertTrue(cmd.contains("-e '"))
        XCTAssertFalse(cmd.contains("; rm -rf /; echo ") && !cmd.contains("'\\''"))
    }

    func testTailCommand() {
        XCTAssertEqual(RemoteFile.tailCommand("/a.log", bytes: 65536), "tail -c 65536 < '/a.log'")
    }


    /// **素の `tail -f` は末尾 10 行を吐いてから追い始める。**
    /// 既に末尾を出している画面に足すと同じ行が 2 回並ぶので、`-n 0` を明示する。
    func testFollowCommandEmitsNothingBeforeFollowing() {
        let cmd = RemoteFile.followCommand("/a.log", bytes: 0)
        XCTAssertTrue(cmd.contains("-n 0"), "既定の 10 行が再送される: \(cmd)")
        XCTAssertTrue(cmd.contains("-f"))
    }

    /// 直近ぶんを出してから追う形も残す（開いた直後にそのまま追う場合）。
    func testFollowCommandCanPrimeWithBytes() {
        XCTAssertTrue(RemoteFile.followCommand("/a.log", bytes: 4096).hasPrefix("tail -c 4096 -f '/a.log'"))
    }

    /// **切ったら向こうも止まること。** PTY を割り当てていないので SIGHUP は飛ばず、
    /// `tail -f` は書き込みが無い限り EPIPE にも気づかない ―― 実機で 3 つ
    /// 置き去りにした。標準入力を見張らせて、EOF で自分を殺させる。
    func testFollowCommandKillsItselfWhenTheConnectionCloses() {
        let cmd = RemoteFile.followCommand("/a.log", bytes: 0)
        XCTAssertTrue(cmd.contains("cat > /dev/null"), "標準入力を見張っていない: \(cmd)")
        XCTAssertTrue(cmd.contains("kill $p"), "見張った後に殺していない: \(cmd)")
    }
}
