import XCTest
@testable import MrEditorCore

/// C5「フォルダを横断して検索」の試験。
///
/// 縛るのは **①何を対象にしたか（除外の規則）②取りこぼさないこと（エンコーディング・
/// チャンク境界）③黙って減らさないこと（バイナリ・上限）**。
final class CrossFileSearchRunnerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrkpro-cross-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func write(_ text: String, _ path: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.data(using: encoding)!.write(to: url)
        return url
    }

    private func search(_ query: String,
                        options: CrossFileSearchRunner.Options = .init(),
                        folders: [URL]? = nil)
        -> (files: [CrossFileSearchRunner.FileHit], summary: CrossFileSearchRunner.Summary) {
        let runner = CrossFileSearchRunner()
        let exp = expectation(description: "cross search")
        var hits: [CrossFileSearchRunner.FileHit] = []
        var summary = CrossFileSearchRunner.Summary()
        runner.run(folders: folders ?? [root], query: query, options: options,
                   onFile: { hits.append($0) },
                   progress: { _ in },
                   completion: { summary = $0; exp.fulfill() })
        wait(for: [exp], timeout: 120)
        return (hits.sorted { $0.url.path < $1.url.path }, summary)
    }

    // MARK: - 基本

    func testFindsMatchesAcrossFolders() throws {
        try write("alpha\nbeta\ngamma\n", "a.log")
        try write("nothing here\n", "b.log")
        try write("deep beta\n", "sub/c.log")

        let (files, summary) = search("beta")
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["a.log", "c.log"])
        XCTAssertEqual(files.map(\.matchCount), [1, 1])
        XCTAssertEqual(summary.matchedLines, 2)
        XCTAssertEqual(files[0].lines.first?.line, 1, "行番号は 0 始まり")
    }

    /// 空白区切りは **AND**（検索バーと同じ規則）。
    func testSpaceSeparatedTermsAreAnded() throws {
        try write("status=200 path=/a\nstatus=500 path=/a\nstatus=500 path=/b\n", "a.log")
        let (files, _) = search("500 /b")
        XCTAssertEqual(files.first?.matchCount, 1)
        XCTAssertEqual(files.first?.lines.first?.line, 2)
    }

    /// 半角スペースだけのクエリは「語ゼロ個」ではなく、スペースそのものを探す 1 語。
    /// タブは別の文字なので当たらない。
    func testSpaceOnlyQueryFindsLinesWithSpaces() throws {
        try write("nospace\none space\n\t\ttabonly\n", "a.log")
        let (files, summary) = search(" ")
        XCTAssertEqual(files.first?.matchCount, 1)
        XCTAssertEqual(files.first?.lines.first?.text, "one space")
        XCTAssertEqual(summary.matchedLines, 1)
    }

    func testRegexMode() throws {
        try write("id=1\nid=22\nid=333\n", "a.log")
        var options = CrossFileSearchRunner.Options()
        options.regex = true
        let (files, _) = search("id=\\d{2,}", options: options)
        XCTAssertEqual(files.first?.matchCount, 2)
    }

    func testCaseSensitivity() throws {
        try write("Error\nerror\n", "a.log")
        var sensitive = CrossFileSearchRunner.Options()
        sensitive.caseSensitive = true
        XCTAssertEqual(search("Error", options: sensitive).files.first?.matchCount, 1)
        XCTAssertEqual(search("Error").files.first?.matchCount, 2, "既定は大小を区別しない")
    }

    // MARK: - 何を対象にするか

    /// **Shift-JIS のファイルも読む**（rg が素直には読めない側の値打ち）。
    func testReadsShiftJISFiles() throws {
        try write("ログの記録\nエラー発生\n", "sjis.log", encoding: .shiftJIS)
        let (files, _) = search("エラー")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.encoding, .shiftJIS)
        XCTAssertEqual(files.first?.lines.first?.text, "エラー発生")
    }

    /// バイナリは読み飛ばし、**飛ばしたことを数える**（黙って減らさない）。
    func testSkipsBinaryFilesAndSaysSo() throws {
        try write("hit\n", "a.log")
        let binary = root.appendingPathComponent("b.bin")
        try Data([0x68, 0x69, 0x00, 0x74]).write(to: binary)
        let (files, summary) = search("hi")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(summary.skippedBinary, 1)
    }

    /// 隠しフォルダ（`.git`）と `node_modules` は既定で見ない。
    func testSkipsHiddenAndNodeModules() throws {
        try write("hit\n", "a.log")
        try write("hit\n", ".git/objects/x.log")
        try write("hit\n", "node_modules/pkg/index.js")
        let (files, _) = search("hit")
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["a.log"])
    }

    /// シンボリックリンクは辿らない（ループを避けるため）。
    func testDoesNotFollowSymlinks() throws {
        try write("hit\n", "real/a.log")
        let link = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let (files, _) = search("hit")
        XCTAssertEqual(files.count, 1)
    }

    /// `.gitignore` は**既定では見ない**（ログのフォルダは git 管理外が普通）。
    func testGitignoreIsOffByDefaultAndOnWhenAsked() throws {
        try write("*.log\n", ".gitignore")
        try write("hit\n", "a.log")
        XCTAssertEqual(search("hit").files.count, 1, "既定で .gitignore を見てはいけない")

        var options = CrossFileSearchRunner.Options()
        options.respectGitignore = true
        XCTAssertEqual(search("hit", options: options).files.count, 0)
    }

    // MARK: - 前後 N 行

    func testContextLinesAreMarked() throws {
        try write("one\ntwo\nHIT\nfour\nfive\n", "a.log")
        var options = CrossFileSearchRunner.Options()
        options.context = 1
        let (files, _) = search("HIT", options: options)
        let lines = files.first!.lines
        XCTAssertEqual(lines.map(\.line), [1, 2, 3])
        XCTAssertEqual(lines.map(\.isContext), [true, false, true])
        XCTAssertEqual(files.first?.matchCount, 1, "前後 N 行を一致に数えてはいけない")
    }

    // MARK: - 上限

    func testCapStopsAndSaysSo() throws {
        var text = ""
        for i in 0..<500 { text += "hit \(i)\n" }
        try write(text, "a.log")
        var options = CrossFileSearchRunner.Options()
        options.cap = 100
        let (_, summary) = search("hit", options: options)
        XCTAssertEqual(summary.matchedLines, 100)
        XCTAssertTrue(summary.capped, "打ち切ったことを言っていない")
    }

    // MARK: - 大ファイル（チャンク並列の経路）

    /// 64MB を越えるファイルは `ScanEngine` の経路（チャンク並列）に入る。
    ///
    /// **チャンクの境目をわざと跨がせる。** 1 行を 64 バイト固定にすると、16MB の
    /// チャンク境界は 262,144 行目にちょうど来る（境界のバイトを含む行は前のチャンクの
    /// 担当なので、チャンク 1 の最初の行は 262,145）。ここに印を置いて、
    /// ①行番号がずれないこと ②前の N 行が**前のチャンクから**補われること
    /// ③後ろの N 行が**次のチャンクから**補われること、を確かめる。
    func testBigFilePathKeepsLineNumbersAndContextAcrossChunks() throws {
        let lineLength = 64                       // 改行込み
        let perChunk = (16 << 20) / lineLength    // 262,144
        let lastOfChunk0 = perChunk               // 境界のバイトを含む行＝前のチャンクの担当
        let firstOfChunk1 = perChunk + 1
        let total = perChunk * 5                  // 80MB＝大ファイル経路（64MB 超）

        var text = String()
        text.reserveCapacity(total * lineLength)
        for i in 0..<total {
            let head = "line \(String(format: "%07d", i)) "
            let mark = (i == lastOfChunk0 || i == firstOfChunk1) ? "NEEDLE" : "xxxxxx"
            let filler = String(repeating: "-", count: lineLength - 1 - head.count - mark.count)
            text += head + mark + filler + "\n"
        }
        let url = try write(text, "big.log")
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int),
                             CrossFileSearchRunner.bigFileThreshold, "大ファイル経路に入っていない")

        var options = CrossFileSearchRunner.Options()
        options.context = 2
        let (files, summary) = search("NEEDLE", options: options)
        XCTAssertEqual(summary.matchedFiles, 1)
        XCTAssertEqual(files.first?.matchCount, 2)

        let lines = files.first!.lines
        XCTAssertEqual(lines.filter { !$0.isContext }.map(\.line), [lastOfChunk0, firstOfChunk1],
                       "チャンクを跨ぐと行番号がずれる")
        // 一致 2 行 ＋ 前 2 行 ＋ 後ろ 2 行（間の 2 行は共有）＝ 6 行
        XCTAssertEqual(lines.map(\.line),
                       [lastOfChunk0 - 2, lastOfChunk0 - 1, lastOfChunk0,
                        firstOfChunk1, firstOfChunk1 + 1, firstOfChunk1 + 2],
                       "チャンクの端で前後 N 行が欠けている")
    }
}
