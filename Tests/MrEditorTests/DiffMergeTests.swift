import XCTest
@testable import MrEditor

/// マージの書き出し。**ここを間違えると人のファイルを壊す。**
/// 左を土台に、採用したハンクだけ右を採る —— その結果を 1 バイト単位で確かめる。
final class DiffMergeTests: XCTestCase {

    private let lf: [UInt8] = [0x0A]

    private func hashes(_ lines: [String]) -> [LineHash] {
        lines.map { line in
            var h = LineHasher()
            for b in line.utf8 { h.feed(b) }
            return h.value
        }
    }

    /// 左右の行から diff を作り、指定のハンクを採用してマージした結果を返す。
    private func merged(_ leftLines: [String], _ rightLines: [String],
                        adopt: (DiffModel) -> Set<Int>) throws -> String {
        let l = TextDiffSource(text: leftLines.joined(separator: "\n") + "\n", displayName: "L")
        let r = TextDiffSource(text: rightLines.joined(separator: "\n") + "\n", displayName: "R")
        let model = DiffModel(ops: LineDiff.compute(hashes(leftLines), hashes(rightLines)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        try model.writeMerged(left: l, right: r, adopted: adopt(model), eol: lf, to: out)
        try out.close()
        defer { try? FileManager.default.removeItem(at: url) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 何も採用しなければ、左がそのまま出る（土台を壊さない）。
    func testAdoptNothingReproducesLeft() throws {
        let left = ["a", "b", "c", "d"]
        let right = ["a", "X", "d", "e"]
        let out = try merged(left, right) { _ in [] }
        XCTAssertEqual(out, "a\nb\nc\nd\n")
    }

    /// すべて採用すれば、右がそのまま出る。
    func testAdoptEverythingReproducesRight() throws {
        let left = ["a", "b", "c", "d"]
        let right = ["a", "X", "d", "e"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nX\nd\ne\n")
    }

    /// 変更（replace）だけ採用する。
    func testAdoptReplaceOnly() throws {
        let left = ["a", "b", "c"]
        let right = ["a", "B", "c"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nB\nc\n")
    }

    /// 追加（insert）を採用すると、右にしかない行が入る。
    func testAdoptInsert() throws {
        let left = ["a", "c"]
        let right = ["a", "b", "c"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nb\nc\n")
    }

    /// 削除（delete）を採用すると、左にしかない行が**落ちる**（右で消えたのを取り込む）。
    func testAdoptDeleteRemovesTheLine() throws {
        let left = ["a", "b", "c"]
        let right = ["a", "c"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nc\n")
    }

    /// 削除を採用しなければ、その行は残る。
    func testRejectDeleteKeepsTheLine() throws {
        let left = ["a", "b", "c"]
        let right = ["a", "c"]
        let out = try merged(left, right) { _ in [] }
        XCTAssertEqual(out, "a\nb\nc\n")
    }

    /// ハンクを選り分ける（1 つ目は採用、2 つ目は不採用）。マージの本命の使い方。
    func testAdoptSomeHunksOnly() throws {
        let left  = ["h", "old", "m", "keep", "t"]
        let right = ["h", "new", "m", "t"]          // 1) old→new  2) keep を削除
        let out = try merged(left, right) { m in
            let hunks = m.hunkOpIndices
            XCTAssertEqual(hunks.count, 2)
            return [hunks[0]]                        // 1 つ目だけ採用
        }
        // old→new は採り、keep の削除は採らない。
        XCTAssertEqual(out, "h\nnew\nm\nkeep\nt\n")
    }

    /// 日本語（マルチバイト）を割らない。
    func testJapaneseLines() throws {
        let left = ["あいう", "かきく", "さしす"]
        let right = ["あいう", "KAKIKU", "さしす"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "あいう\nKAKIKU\nさしす\n")
    }

    /// ファイル（mmap 経由）を土台にしても同じ結果になる。実運用の経路。
    func testMergeFromFileSource() throws {
        let dir = FileManager.default.temporaryDirectory
        let lURL = dir.appendingPathComponent("mL-\(UUID().uuidString).log")
        let rURL = dir.appendingPathComponent("mR-\(UUID().uuidString).log")
        try "a\nb\nc\n".write(to: lURL, atomically: true, encoding: .utf8)
        try "a\nB\nc\nd\n".write(to: rURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: lURL); try? FileManager.default.removeItem(at: rURL) }

        var srcs: (FileDiffSource, FileDiffSource)?
        let done = expectation(description: "sources")
        DispatchQueue.global().async {
            if let l = FileDiffSource(url: lURL), let r = FileDiffSource(url: rURL) { srcs = (l, r) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let (l, r) = try XCTUnwrap(srcs)

        let model = DiffModel(ops: LineDiff.compute(l.lineHashes(), r.lineHashes()))
        let outURL = dir.appendingPathComponent("mOut-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        try model.writeMerged(left: l, right: r, adopted: Set(model.hunkOpIndices), eol: lf, to: out)
        try out.close()
        defer { try? FileManager.default.removeItem(at: outURL) }

        XCTAssertEqual(try String(contentsOf: outURL, encoding: .utf8), "a\nB\nc\nd\n")
    }
}
