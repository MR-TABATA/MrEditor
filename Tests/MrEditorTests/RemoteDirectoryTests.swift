import XCTest
@testable import MrEditorCore

/// 遠隔のフォルダ（種類の判定・一覧・名前検索）。向こうで走る文字列を、
/// **本物の `/bin/sh` に通して**確かめる（向こうも POSIX sh）。
final class RemoteDirectoryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func sh(_ command: String) throws -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    private func touch(_ rel: String, _ body: String = "x\n") throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 種類

    func testKindDistinguishesFileFolderMissingAndUnreadable() throws {
        try touch("a.log")
        try touch("sub/b.log")
        let unreadable = dir.appendingPathComponent("secret.log")
        try "s".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

        func kind(_ path: String) throws -> RemoteFile.Kind? {
            RemoteFile.parseKind(try sh(RemoteFile.kindCommand(path)).out)
        }
        XCTAssertEqual(try kind(dir.appendingPathComponent("a.log").path), .file)
        XCTAssertEqual(try kind(dir.appendingPathComponent("sub").path), .directory)
        XCTAssertEqual(try kind(dir.appendingPathComponent("nope.log").path), .missing)
        if getuid() != 0 {
            XCTAssertEqual(try kind(unreadable.path), .unreadable)
        }
        XCTAssertEqual(try kind("/dev/null"), .special)
    }

    /// 能力の出力に種類の行が混ざっても、能力の読みは変わらない。
    func testCapabilitiesIgnoreKindLine() {
        let caps = RemoteFile.Capabilities.parse("wc\nhead\ntail\ngrep\nkind:file\n")
        XCTAssertTrue(caps.canRead && caps.canSize && caps.canFollow && caps.canFilter)
    }

    func testParseKindReturnsNilWhenAbsent() {
        XCTAssertNil(RemoteFile.parseKind("wc\nhead\n"))
    }

    func testKindCommandSurvivesHostilePath() throws {
        XCTAssertEqual(
            RemoteFile.parseKind(try sh(RemoteFile.kindCommand("/tmp/x'; echo kind:dir; echo '")).out),
            .missing,
            "パスが命令にならない"
        )
    }

    // MARK: - 一覧

    func testListMarksFoldersAndIncludesHiddenFilesAndSymlinkedFolders() throws {
        try touch("plain.txt")
        try touch(".hidden")
        try touch("dir one/inner.txt")           // 空白を含む名前
        try touch("-dash.txt")                   // 先頭が - の名前
        try touch("back\\slash.txt")
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link-to-dir"),
            withDestinationURL: dir.appendingPathComponent("dir one")
        )
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("dangling"),
            withDestinationURL: dir.appendingPathComponent("gone")
        )

        let r = RemoteFile.parseList(try sh(RemoteFile.listCommand(dir.path)).out)
        let byName = Dictionary(uniqueKeysWithValues: r.entries.map { ($0.name, $0.isDirectory) })

        XCTAssertEqual(byName["plain.txt"], false)
        XCTAssertEqual(byName[".hidden"], false)
        XCTAssertEqual(byName["dir one"], true)
        XCTAssertEqual(byName["-dash.txt"], false)
        XCTAssertEqual(byName["back\\slash.txt"], false, "echo のように \\ を解釈しない")
        XCTAssertEqual(byName["link-to-dir"], true, "フォルダへのリンクはフォルダとして歩ける")
        XCTAssertEqual(byName["dangling"], false, "壊れたリンクも一覧には出す")
        XCTAssertFalse(r.truncated)
    }

    func testListOfEmptyFolderIsEmptyNotAnError() throws {
        let (out, status) = try sh(RemoteFile.listCommand(dir.path))
        XCTAssertEqual(status, 0)
        XCTAssertEqual(RemoteFile.parseList(out).entries, [])
    }

    func testListFailsOutsideTheFolder() throws {
        XCTAssertNotEqual(try sh(RemoteFile.listCommand(dir.appendingPathComponent("nope").path)).status, 0)
    }

    func testListTruncatesAndSaysSo() throws {
        let many = dir.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<(RemoteFile.listLimit + 5) {
            FileManager.default.createFile(atPath: many.appendingPathComponent("f\(i)").path, contents: nil)
        }
        let r = RemoteFile.parseList(try sh(RemoteFile.listCommand(many.path)).out)
        XCTAssertEqual(r.entries.count, RemoteFile.listLimit)
        XCTAssertTrue(r.truncated)
    }

    // MARK: - 名前検索

    func testFindMatchesNamesCaseInsensitivelyAndReturnsRelativePaths() throws {
        try touch("app.log")
        try touch("sub/APP-error.log")
        try touch("sub/deep/other.txt")
        let r = RemoteFile.parseFind(try sh(RemoteFile.findCommand(dir.path, term: "app")).out)
        XCTAssertEqual(Set(r.paths), ["app.log", "sub/APP-error.log"])
        XCTAssertFalse(r.truncated)
    }

    /// 打った語は「この文字を含む名前」であって、パターンではない。
    func testFindTreatsWildcardCharactersLiterally() throws {
        try touch("a*b.txt")
        try touch("axb.txt")
        try touch("q?.txt")
        try touch("qz.txt")
        XCTAssertEqual(Set(RemoteFile.parseFind(try sh(RemoteFile.findCommand(dir.path, term: "a*b")).out).paths), ["a*b.txt"])
        XCTAssertEqual(Set(RemoteFile.parseFind(try sh(RemoteFile.findCommand(dir.path, term: "q?")).out).paths), ["q?.txt"])
    }

    func testFindDoesNotReturnFolders() throws {
        try touch("logs/x.txt")
        let r = RemoteFile.parseFind(try sh(RemoteFile.findCommand(dir.path, term: "logs")).out)
        XCTAssertEqual(r.paths, [], "フォルダ名には当たらない（ファイルを開くための検索）")
    }

    func testFindTruncatesAtLimit() {
        let out = (0..<(RemoteFile.findLimit + 1)).map { "./f\($0)" }.joined(separator: "\n")
        let r = RemoteFile.parseFind(out)
        XCTAssertEqual(r.paths.count, RemoteFile.findLimit)
        XCTAssertTrue(r.truncated)
    }

    func testFindCommandSurvivesHostileRootAndTerm() throws {
        try touch("ok.txt")
        let r = try sh(RemoteFile.findCommand(dir.path, term: "'; echo pwned; echo '"))
        XCTAssertFalse(r.out.contains("pwned"))
    }

    func testEscapeGlob() {
        XCTAssertEqual(RemoteFile.escapeGlob("a*b?[c]\\"), "a\\*b\\?\\[c]\\\\")
    }
}

/// 手元のフォルダ（`LocalDirectoryProvider`）。
final class LocalDirectoryProviderTests: XCTestCase {

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func touch(_ rel: String) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }

    func testListPutsFoldersFirstAndSortsNaturally() throws {
        try touch("file10.txt"); try touch("file2.txt"); try touch("zdir/a.txt"); try touch(".hidden")
        let names = try LocalDirectoryProvider().list(dir.path).nodes.map(\.name)
        XCTAssertEqual(names, ["zdir", ".hidden", "file2.txt", "file10.txt"])
    }

    func testSearchFindsByNameAndSkipsGitFolder() throws {
        try touch("src/Main.swift"); try touch("src/util/main_test.swift"); try touch(".git/objects/main-pack")
        try touch("README.md")
        let r = try LocalDirectoryProvider().search(root: dir.path, term: "MAIN")
        XCTAssertEqual(r.nodes.map(\.name), ["src/Main.swift", "src/util/main_test.swift"])
        XCTAssertFalse(r.truncated)
    }

    func testListOfMissingFolderThrows() {
        XCTAssertThrowsError(try LocalDirectoryProvider().list(dir.appendingPathComponent("nope").path))
    }
}
