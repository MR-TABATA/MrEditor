import XCTest
@testable import MrEditor

/// diff の入力（ファイル / メモリ上テキスト）。
/// **行が読めること**が全て。左が空のまま並ぶ diff は無価値。
final class DiffSourceTests: XCTestCase {

    private func tempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("difftest-\(UUID().uuidString).log")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// FileDiffSource はメインスレッドで作れない（索引の完了待ちで固まる）ので、背景で作る。
    private func makeFileSource(_ url: URL) throws -> FileDiffSource {
        var result: FileDiffSource?
        let done = expectation(description: "source")
        DispatchQueue.global().async {
            result = FileDiffSource(url: url)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result)
    }

    func testFileSourceReadsLines() throws {
        let url = try tempFile("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try makeFileSource(url)

        XCTAssertEqual(src.lineCount, 3)
        XCTAssertEqual(src.line(at: 0), "one")
        XCTAssertEqual(src.line(at: 1), "two")
        XCTAssertEqual(src.line(at: 2), "three")
        XCTAssertEqual(src.lineHashes().count, 3)
    }

    func testFileSourceWithJapaneseAndCRLF() throws {
        let url = try tempFile("あいう\r\nかきく\r\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try makeFileSource(url)
        XCTAssertEqual(src.line(at: 0), "あいう")   // CR が残らない
        XCTAssertEqual(src.line(at: 1), "かきく")
    }

    func testTextSourceReadsLines() {
        let src = TextDiffSource(text: "one\ntwo\nthree\n", displayName: "clip")
        XCTAssertEqual(src.lineCount, 3)
        XCTAssertEqual(src.line(at: 0), "one")
        XCTAssertEqual(src.line(at: 2), "three")
    }

    /// ファイルとクリップボードで、同じ中身が同じハッシュになる（＝差分ゼロになる）。
    /// ここがズレると「同じものを比べたのに全行が違う」と出る。
    func testFileAndTextAgreeOnIdenticalContent() throws {
        let text = "alpha\nbravo\ncharlie\n"
        let url = try tempFile(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try makeFileSource(url)
        let t = TextDiffSource(text: text, displayName: "clip")

        XCTAssertEqual(f.lineCount, t.lineCount)
        XCTAssertEqual(f.lineHashes(), t.lineHashes())

        let ops = LineDiff.compute(f.lineHashes(), t.lineHashes())
        XCTAssertEqual(ops, [.equal(left: 0, right: 0, count: 3)])
    }
}

/// アプリで左カラムが空白になった件の再現用。
/// 実ログ規模（4,000 行）で、途中の行が読めるか。
extension DiffSourceTests {
    func testFileSourceReadsMiddleLineOfLargerFile() throws {
        let lines = (0..<4000).map { "2026-06-26 12:00:00.\(String(format: "%03d", $0 % 1000)) [INFO] request_id=\($0)" }
        let url = try tempFile(lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try makeFileSource(url)

        XCTAssertEqual(src.lineCount, 4000)
        XCTAssertEqual(src.line(at: 0), lines[0])
        XCTAssertEqual(src.line(at: 117), lines[117])     // アプリで空白だったあたり
        XCTAssertEqual(src.line(at: 3999), lines[3999])
    }
}

/// URL 比較の入口。ダウンロード自体（ネットワーク）は測らず、
/// **入力を信用しない**変換と、見出しの付け方を固める。
extension DiffSourceTests {
    func testCompareURLNormalizeAcceptsHTTPS() {
        XCTAssertEqual(CompareURL.normalize("https://example.com/a.log")?.absoluteString,
                       "https://example.com/a.log")
        // 前後の空白・改行は落とす（コピペ由来）。
        XCTAssertEqual(CompareURL.normalize("  https://example.com/a.log\n")?.absoluteString,
                       "https://example.com/a.log")
    }

    func testCompareURLNormalizeRejectsNonHTTPS() {
        XCTAssertNil(CompareURL.normalize(""))
        XCTAssertNil(CompareURL.normalize("   "))
        // 平文 http は実機の ATS で弾かれる。入口で断る（実測 -1022 の再現を避ける）。
        XCTAssertNil(CompareURL.normalize("http://example.com/a.log"))
        XCTAssertNil(CompareURL.normalize("example.com/a.log"))          // スキームなし
        XCTAssertNil(CompareURL.normalize("file:///etc/passwd"))         // ローカル file は弾く
        XCTAssertNil(CompareURL.normalize("javascript:alert(1)"))
        XCTAssertNil(CompareURL.normalize("https://"))                   // ホストなし
        XCTAssertNil(CompareURL.normalize("ftp://example.com/x"))
    }

    func testCompareURLDisplayName() {
        XCTAssertEqual(CompareURL.displayName(for: URL(string: "https://example.com/logs/app.log")!),
                       "app.log")
        // パス末尾が無ければホスト名を見出しにする。
        XCTAssertEqual(CompareURL.displayName(for: URL(string: "https://example.com/")!),
                       "example.com")
        XCTAssertEqual(CompareURL.displayName(for: URL(string: "https://example.com")!),
                       "example.com")
    }

    /// URL からのソースは一時ファイル名でなく元の見出しを見せる（FileDiffSource の名前差し替え）。
    func testFileSourceHonorsDisplayNameOverride() throws {
        let url = try tempFile("a\nb\n")
        defer { try? FileManager.default.removeItem(at: url) }
        var result: FileDiffSource?
        let done = expectation(description: "source")
        DispatchQueue.global().async {
            result = FileDiffSource(url: url, displayName: "app.log")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try XCTUnwrap(result).displayName, "app.log")
    }
}
