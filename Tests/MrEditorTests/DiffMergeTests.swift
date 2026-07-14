import XCTest
@testable import MrEditor

/// マージの書き出し。**ここを間違えると人のファイルを壊す。**
///
/// 矢印は **→**（左の内容を右へ持っていく）。したがって **右が結果**で、
/// 適用したハンクだけ左の内容が入る。その結果を 1 バイト単位で確かめる。
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
        try model.writeMerged(left: l, right: r, applied: adopt(model), eol: lf, to: out)
        try out.close()
        defer { try? FileManager.default.removeItem(at: url) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 何も適用しなければ、**右がそのまま**出る（土台を壊さない）。
    func testApplyNothingReproducesRight() throws {
        let left = ["a", "b", "c", "d"]
        let right = ["a", "X", "d", "e"]
        let out = try merged(left, right) { _ in [] }
        XCTAssertEqual(out, "a\nX\nd\ne\n")
    }

    /// すべて適用すれば、**左がそのまま**出る（左の内容を全部右へ持っていった）。
    func testApplyEverythingReproducesLeft() throws {
        let left = ["a", "b", "c", "d"]
        let right = ["a", "X", "d", "e"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nb\nc\nd\n")
    }

    /// 変更（replace）を適用すると、右が左の内容になる。
    func testApplyReplace() throws {
        let left = ["a", "b", "c"]
        let right = ["a", "B", "c"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nb\nc\n")
    }

    /// 左にしかない行（delete）を適用すると、その行が**右へ入る**。
    func testApplyDeleteAddsTheLineToRight() throws {
        let left = ["a", "b", "c"]
        let right = ["a", "c"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nb\nc\n")
    }

    /// 右にしかない行（insert）を適用すると、その行が**右から落ちる**（左に合わせる）。
    func testApplyInsertRemovesTheLineFromRight() throws {
        let left = ["a", "c"]
        let right = ["a", "b", "c"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nc\n")
    }

    /// 適用しなければ、右にしかない行はそのまま残る。
    func testRejectInsertKeepsTheLine() throws {
        let left = ["a", "c"]
        let right = ["a", "b", "c"]
        let out = try merged(left, right) { _ in [] }
        XCTAssertEqual(out, "a\nb\nc\n")
    }

    /// ハンクを選り分ける（1 つ目だけ適用）。マージの本命の使い方。
    func testApplySomeHunksOnly() throws {
        let left  = ["h", "old", "m", "keep", "t"]
        let right = ["h", "new", "m", "t"]          // 1) old↔new  2) keep は左にしかない
        let out = try merged(left, right) { m in
            let hunks = m.hunkOpIndices
            XCTAssertEqual(hunks.count, 2)
            return [hunks[0]]                        // 1 つ目だけ適用
        }
        // old を右へ持っていく。keep は持っていかない。
        XCTAssertEqual(out, "h\nold\nm\nt\n")
    }

    /// 日本語（マルチバイト）を割らない。
    func testJapaneseLines() throws {
        let left = ["あいう", "かきく", "さしす"]
        let right = ["あいう", "KAKIKU", "さしす"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "あいう\nかきく\nさしす\n")
    }

    /// ファイル（mmap 経由）でも同じ結果になる。実運用の経路。
    func testMergeFromFileSource() throws {
        let dir = FileManager.default.temporaryDirectory
        let lURL = dir.appendingPathComponent("mL-\(UUID().uuidString).log")
        let rURL = dir.appendingPathComponent("mR-\(UUID().uuidString).log")
        try "a\nb\nc\n".write(to: lURL, atomically: true, encoding: .utf8)
        try "a\nB\nc\nd\n".write(to: rURL, atomically: true, encoding: .utf8)   // 右: B と d
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
        try model.writeMerged(left: l, right: r, applied: Set(model.hunkOpIndices), eol: lf, to: out)
        try out.close()
        defer { try? FileManager.default.removeItem(at: outURL) }

        // 全部適用＝左の内容が右へ入る（B→b、d は落ちる）。
        XCTAssertEqual(try String(contentsOf: outURL, encoding: .utf8), "a\nb\nc\n")
    }
}

/// 実機で保存結果が合わなかったケースの再現。
/// 左 a.log / 右 b.log で、1 つ目（replace）だけ適用したときの出力。
extension DiffMergeTests {
    func testRealCaseApplyFirstHunkOnly() throws {
        let left  = ["header", "old-line", "middle", "keep-me", "tail"]
        let right = ["header", "new-line", "middle", "tail", "extra"]
        // ops: equal / replace / equal / delete(keep-me) / equal / insert(extra)
        let out = try merged(left, right) { m in
            let hunks = m.hunkOpIndices
            XCTAssertEqual(hunks.count, 3, "差分は 3 箇所のはず: \(m.ops)")
            return [hunks[0]]                   // 1 つ目（replace）だけ適用
        }
        // 右が土台。replace だけ左を採る → new-line が old-line に。
        // keep-me は持っていかない（右に入らない）。extra はそのまま残る。
        XCTAssertEqual(out, "header\nold-line\nmiddle\ntail\nextra\n")
    }
}
