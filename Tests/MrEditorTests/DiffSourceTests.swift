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
