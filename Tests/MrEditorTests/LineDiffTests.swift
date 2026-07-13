import XCTest
@testable import MrEditor

/// 行 diff。**差分を見落とさないこと**が全て。
/// 「op を左に適用したら右になる」を不変条件として、乱択でも壊れないことを見る。
final class LineDiffTests: XCTestCase {

    private func hashes(_ lines: [String]) -> [LineHash] {
        lines.map { line in
            var h = LineHasher()
            for b in line.utf8 { h.feed(b) }
            return h.value
        }
    }

    /// ops を左の行列に適用して、右の行列を復元できるか。
    /// これが通る限り「差分の見落とし」も「作り話」も無い。
    private func apply(_ ops: [DiffOp], to left: [String], expecting right: [String]) -> [String] {
        var out: [String] = []
        for op in ops {
            switch op {
            case let .equal(l, _, c):            out.append(contentsOf: left[l..<(l + c)])
            case .delete:                        break
            case let .insert(r, c):              out.append(contentsOf: right[r..<(r + c)])
            case let .replace(_, _, r, rc):      out.append(contentsOf: right[r..<(r + rc)])
            }
        }
        return out
    }

    private func check(_ a: [String], _ b: [String], file: StaticString = #filePath, line: UInt = #line) {
        let ops = LineDiff.compute(hashes(a), hashes(b))
        XCTAssertEqual(apply(ops, to: a, expecting: b), b, "適用結果が右と一致しない", file: file, line: line)
    }

    func testIdentical() {
        let a = ["x", "y", "z"]
        let ops = LineDiff.compute(hashes(a), hashes(a))
        XCTAssertEqual(ops, [.equal(left: 0, right: 0, count: 3)])
    }

    func testInsertInMiddle() {
        check(["a", "b", "d"], ["a", "b", "c", "d"])
    }

    func testDeleteInMiddle() {
        check(["a", "b", "c", "d"], ["a", "d"])
    }

    func testReplaceIsCoalesced() {
        // 消して足した、ではなく「書き換わった」と見せる（行内差分をここに掛けるため）。
        let ops = LineDiff.compute(hashes(["a", "x", "c"]), hashes(["a", "y", "c"]))
        XCTAssertEqual(ops, [
            .equal(left: 0, right: 0, count: 1),
            .replace(left: 1, leftCount: 1, right: 1, rightCount: 1),
            .equal(left: 2, right: 2, count: 1),
        ])
    }

    func testEmptySides() {
        check([], ["a", "b"])
        check(["a", "b"], [])
        check([], [])
    }

    func testNothingInCommon() {
        check(["a", "b", "c"], ["x", "y", "z"])
    }

    /// 同じ行が大量に重複していてアンカーが取れない状況（ログでは普通に起きる）。
    func testHighlyRepetitiveLines() {
        let a = [String](repeating: "same", count: 200) + ["tail"]
        let b = ["head"] + [String](repeating: "same", count: 200)
        check(a, b)
    }

    /// 巨大な非アンカー区間は replace に畳む（諦めても、嘘はつかない＝復元はできる）。
    func testHugeUnanchoredBlockFoldsToReplace() {
        let a = (0..<3000).map { _ in "dup" }
        let b = (0..<3000).map { _ in "other" }
        let ops = LineDiff.compute(hashes(a), hashes(b))
        XCTAssertEqual(apply(ops, to: a, expecting: b), b)
        XCTAssertEqual(ops.count, 1)
        guard case .replace = ops[0] else { return XCTFail("replace に畳まれていない: \(ops)") }
    }

    /// 乱択。ログを想定して「一部の行を書き換え・挿入・削除」した右を作り、往復を見る。
    func testRandomEdits() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<200 {
            let n = Int.random(in: 0...80, using: &rng)
            let a = (0..<n).map { "line \($0 % 17)" }   // わざと重複を作る
            var b = a
            for _ in 0..<Int.random(in: 0...10, using: &rng) {
                guard !b.isEmpty else { b.append("new"); continue }
                switch Int.random(in: 0...2, using: &rng) {
                case 0: b.insert("ins \(Int.random(in: 0...99, using: &rng))", at: Int.random(in: 0...b.count, using: &rng))
                case 1: b.remove(at: Int.random(in: 0..<b.count, using: &rng))
                default: b[Int.random(in: 0..<b.count, using: &rng)] = "mod \(Int.random(in: 0...99, using: &rng))"
                }
            }
            let ops = LineDiff.compute(hashes(a), hashes(b))
            XCTAssertEqual(apply(ops, to: a, expecting: b), b, "trial \(trial): a=\(a) b=\(b) ops=\(ops)")
        }
    }

    /// CRLF と LF の違いだけで「全行が違う」と言わない。
    func testCRLFAndLFHashTheSame() {
        let lf = Array("a\nb\n".utf8)
        let crlf = Array("a\r\nb\r\n".utf8)
        let h1 = lf.withUnsafeBytes { LineHasher.hashLines($0) }
        let h2 = crlf.withUnsafeBytes { LineHasher.hashLines($0) }
        XCTAssertEqual(h1, h2)
    }
}

/// 行内の文字差分。
final class CharDiffTests: XCTestCase {

    func testSingleCharChange() {
        let (l, r) = CharDiff.ranges(left: "status=200", right: "status=500")
        XCTAssertEqual(l, [7..<8])
        XCTAssertEqual(r, [7..<8])
    }

    func testInsertionOnly() {
        let (l, r) = CharDiff.ranges(left: "abc", right: "abXc")
        XCTAssertEqual(l, [])
        XCTAssertEqual(r, [2..<3])
    }

    func testIdenticalHasNoRanges() {
        let (l, r) = CharDiff.ranges(left: "同じ行", right: "同じ行")
        XCTAssertTrue(l.isEmpty && r.isEmpty)
    }

    /// 絵文字・結合文字を割らない（Character 単位で数える）。
    func testGraphemeSafety() {
        let (l, r) = CharDiff.ranges(left: "あ👨‍👩‍👦い", right: "あ👨‍👩‍👦う")
        XCTAssertEqual(l, [2..<3])
        XCTAssertEqual(r, [2..<3])
    }

    /// 長すぎる行は行内差分を諦める（DP を回さない）。
    func testVeryLongLineFallsBack() {
        let a = String(repeating: "a", count: CharDiff.maxLineLength + 1)
        let b = String(repeating: "b", count: CharDiff.maxLineLength + 1)
        let (l, r) = CharDiff.ranges(left: a, right: b)
        XCTAssertEqual(l, [0..<a.count])
        XCTAssertEqual(r, [0..<b.count])
    }
}
