import XCTest
@testable import MrEditor

/// piece table の参照実装（プレーンな `[UInt8]` を直接編集する単純モデル）。
/// fuzz テストで `PieceTable` の結果と突き合わせる正解側。
private struct NaiveDoc {
    var bytes: [UInt8] = []

    mutating func insert(_ b: [UInt8], at off: Int) {
        bytes.insert(contentsOf: b, at: min(max(0, off), bytes.count))
    }
    mutating func delete(_ r: Range<Int>) {
        let lo = max(0, r.lowerBound), hi = min(bytes.count, r.upperBound)
        if lo < hi { bytes.removeSubrange(lo..<hi) }
    }

    private var starts: [Int] {
        var s = [0]
        for (i, b) in bytes.enumerated() where b == 0x0A { s.append(i + 1) }
        return s
    }
    private var newlineCount: Int { starts.count - 1 }

    var lineCount: Int {
        guard !bytes.isEmpty else { return 0 }
        return newlineCount + (bytes.last == 0x0A ? 0 : 1)
    }

    func byteRange(ofLine line: Int) -> Range<Int> {
        let lc = lineCount
        guard line >= 0, line < lc else { return 0..<0 }
        let s = starts
        let start = s[line]
        let end = (line < newlineCount) ? s[line + 1] - 1 : bytes.count
        return start..<max(start, end)
    }

    func byteOffset(ofLineStart line: Int) -> Int {
        let lc = lineCount
        let clamped = min(max(0, line), lc)
        if clamped == 0 { return 0 }
        let s = starts
        return (clamped - 1 < newlineCount) ? s[clamped] : bytes.count
    }

    func line(ofByteOffset off: Int) -> Int {
        let t = min(max(0, off), bytes.count)
        var c = 0
        for i in 0..<t where bytes[i] == 0x0A { c += 1 }
        return c
    }
}

/// テスト用の決定的 PRNG（再現可能な fuzz のため）。
private struct LCG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class PieceTableTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: - 単体

    func testEmpty() {
        let t = PieceTable(bytes: [])
        XCTAssertEqual(t.byteCount, 0)
        XCTAssertEqual(t.lineCount, 0)
        XCTAssertEqual(t.bytes(in: 0..<0), [])
        XCTAssertEqual(t.byteRange(ofLine: 0), 0..<0)
    }

    func testInitialContent() {
        let t = PieceTable(bytes: bytes("abc\ndef\nghi"))
        XCTAssertEqual(t.byteCount, 11)
        XCTAssertEqual(t.lineCount, 3)
        XCTAssertEqual(t.bytes(in: 0..<11), bytes("abc\ndef\nghi"))
        XCTAssertEqual(t.byteRange(ofLine: 0), 0..<3)
        XCTAssertEqual(t.byteRange(ofLine: 1), 4..<7)
        XCTAssertEqual(t.byteRange(ofLine: 2), 8..<11)
    }

    func testInsertHeadMidTail() {
        let t = PieceTable(bytes: bytes("Hello"))
        t.insert(bytes(">> "), at: 0)          // head
        t.insert(bytes("-"), at: 5)            // mid: ">> He|llo"
        t.insert(bytes("!"), at: t.byteCount)  // tail
        XCTAssertEqual(t.bytes(in: 0..<t.byteCount), bytes(">> He-llo!"))
    }

    func testInsertNewlinesUpdatesLineCount() {
        let t = PieceTable(bytes: bytes("oneline"))
        XCTAssertEqual(t.lineCount, 1)
        t.insert(bytes("\ntwo\nthree"), at: t.byteCount)
        XCTAssertEqual(t.lineCount, 3)
        XCTAssertEqual(t.byteRange(ofLine: 1), 8..<11)   // "two"
    }

    func testDeleteAcrossPieces() {
        let t = PieceTable(bytes: bytes("abcdef"))
        t.insert(bytes("XYZ"), at: 3)          // "abcXYZdef"
        t.delete(2..<7)                         // remove "cXYZd" → "abef"
        XCTAssertEqual(t.bytes(in: 0..<t.byteCount), bytes("abef"))
        XCTAssertEqual(t.byteCount, 4)
    }

    func testDeleteNewlineMergesLines() {
        let t = PieceTable(bytes: bytes("a\nb\nc"))
        XCTAssertEqual(t.lineCount, 3)
        t.delete(1..<2)                         // remove first "\n" → "ab\nc"
        XCTAssertEqual(t.lineCount, 2)
        XCTAssertEqual(t.byteRange(ofLine: 0), 0..<2)   // "ab"
    }

    func testTrailingNewlineSemantics() {
        XCTAssertEqual(PieceTable(bytes: bytes("a\n")).lineCount, 1)
        XCTAssertEqual(PieceTable(bytes: bytes("a\nb")).lineCount, 2)
        XCTAssertEqual(PieceTable(bytes: bytes("a\n\n")).lineCount, 2)
    }

    func testLineOffsetRoundTrip() {
        let t = PieceTable(bytes: bytes("alpha\nbeta\ngamma\n"))
        for line in 0..<t.lineCount {
            let start = t.byteOffset(ofLineStart: line)
            XCTAssertEqual(t.line(ofByteOffset: start), line)
        }
    }

    // MARK: - fuzz（参照実装と突き合わせ）

    func testFuzzAgainstNaive() {
        let alphabet: [UInt8] = Array("ab\n".utf8)   // 改行を多めに混ぜる
        for seed in UInt64(1)...8 {
            var rng = LCG(seed: seed)
            var naive = NaiveDoc()
            // 初期コンテンツ
            let initLen = Int.random(in: 0...40, using: &rng)
            let initBytes = (0..<initLen).map { _ in alphabet.randomElement(using: &rng)! }
            naive.bytes = initBytes
            let table = PieceTable(bytes: initBytes)

            for _ in 0..<3000 {
                let n = naive.bytes.count
                if n > 0 && Int.random(in: 0...2, using: &rng) == 0 {
                    // delete
                    let lo = Int.random(in: 0..<n, using: &rng)
                    let hi = Int.random(in: lo...n, using: &rng)
                    naive.delete(lo..<hi)
                    table.delete(lo..<hi)
                } else {
                    // insert
                    let off = Int.random(in: 0...n, using: &rng)
                    let len = Int.random(in: 1...6, using: &rng)
                    let b = (0..<len).map { _ in alphabet.randomElement(using: &rng)! }
                    naive.insert(b, at: off)
                    table.insert(b, at: off)
                }

                // 構造不変条件を毎回突き合わせ
                XCTAssertEqual(table.byteCount, naive.bytes.count, "byteCount seed=\(seed)")
                XCTAssertEqual(table.bytes(in: 0..<table.byteCount), naive.bytes, "content seed=\(seed)")
                XCTAssertEqual(table.lineCount, naive.lineCount, "lineCount seed=\(seed)")
                for line in 0..<table.lineCount {
                    XCTAssertEqual(table.byteRange(ofLine: line),
                                   naive.byteRange(ofLine: line),
                                   "byteRange line=\(line) seed=\(seed)")
                }
                // ランダムなオフセットの行解決
                if naive.bytes.count > 0 {
                    let off = Int.random(in: 0...naive.bytes.count, using: &rng)
                    XCTAssertEqual(table.line(ofByteOffset: off),
                                   naive.line(ofByteOffset: off),
                                   "line(ofByteOffset:\(off)) seed=\(seed)")
                }
            }
        }
    }
}
