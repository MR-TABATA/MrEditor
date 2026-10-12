import XCTest
@testable import MrEditorCore

/// 伸びていくファイル（`tail -f`）の続きだけを走査して、絞り込みに足す。
final class SearchEngineResumeTests: XCTestCase {

    private func run(_ engine: SearchEngine, resume: SearchEngine.Result? = nil) -> SearchEngine.Result {
        let done = expectation(description: "search")
        var out = SearchEngine.Result()
        engine.search(.terms(["ERROR"]), resume: resume, progress: { _, _ in }, completion: { res in
            out = res; done.fulfill()
        })
        wait(for: [done], timeout: 5)
        return out
    }

    func testResumeAddsOnlyTheGrownPartAndRecountsTheUnterminatedTail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-\(UUID().uuidString).log")
        // 末尾の行は改行が無い（まだ書きかけ）。ERROR を含む。
        try "ok\nERROR a\nok\nERROR b".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try XCTUnwrap(FileBuffer(url: url))
        let engine = SearchEngine(buffer: buffer, encoding: .utf8)

        let first = run(engine)
        XCTAssertEqual(first.lines, [1, 3])          // 書きかけの行も一度は数える
        XCTAssertEqual(first.resumeLine, 3)           // が、再開点は改行で終わった行まで

        // 書きかけの行が完成し、さらに 2 行増える。
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(" more\nok\nERROR c\n".utf8))
        try h.close()
        XCTAssertNotNil(buffer.remapIfGrownTry())

        let second = run(engine, resume: first)
        XCTAssertEqual(second.lines, [1, 3, 5])       // 3 を二重に数えない
        XCTAssertEqual(second.lineCount, 3)
        XCTAssertEqual(second.resumeLine, 6)
    }
}
