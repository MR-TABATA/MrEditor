import XCTest
@testable import MrEditorCore

/// `FetchedRanges` の検証。
///
/// ここが間違うと、被害は「開けない」ではなく **「本文の一部が静かにゼロで埋まる」**。
/// 疎ファイルの穴は mmap でゼロとして読めてしまうので、素朴な実装との一致を
/// 乱択で突き合わせる（境界・隣接・包含の組み合わせは手で並べきれない）。
final class FetchedRangesTests: XCTestCase {

    /// 参照側：バイトごとに取得済みかを持つだけの、疑いようのない実装。
    private struct Naive {
        var have: Set<Int> = []
        mutating func insert(_ r: Range<Int>) { for i in r { have.insert(i) } }
        func missing(in r: Range<Int>) -> [Range<Int>] {
            var out: [Range<Int>] = []
            var run: Int? = nil
            for i in r {
                if have.contains(i) {
                    if let s = run { out.append(s..<i); run = nil }
                } else if run == nil {
                    run = i
                }
            }
            if let s = run { out.append(s..<r.upperBound) }
            return out
        }
    }

    // MARK: - 基本

    func testEmptyHasEverythingMissing() {
        XCTAssertEqual(FetchedRanges().missing(in: 0..<100), [0..<100])
        XCTAssertFalse(FetchedRanges().contains(0..<1))
    }

    func testInsertThenContains() {
        var f = FetchedRanges()
        f.insert(10..<20)
        XCTAssertTrue(f.contains(10..<20))
        XCTAssertTrue(f.contains(12..<15))
        XCTAssertFalse(f.contains(9..<20))
        XCTAssertFalse(f.contains(10..<21))
    }

    func testMissingReportsGapsOnly() {
        var f = FetchedRanges()
        f.insert(10..<20)
        f.insert(30..<40)
        XCTAssertEqual(f.missing(in: 0..<50), [0..<10, 20..<30, 40..<50])
        XCTAssertEqual(f.missing(in: 15..<35), [20..<30])
        XCTAssertEqual(f.missing(in: 10..<20), [])
    }

    /// 隣接は連結する。4KB ずつ埋めていくと区間が数万に増え、探索が線形に効いてくる。
    func testAdjacentRangesAreCoalesced() {
        var f = FetchedRanges()
        f.insert(0..<10)
        f.insert(10..<20)
        f.insert(20..<30)
        XCTAssertEqual(f.ranges, [0..<30])
    }

    func testOverlappingRangesAreMerged() {
        var f = FetchedRanges()
        f.insert(0..<10)
        f.insert(5..<25)
        f.insert(20..<30)
        XCTAssertEqual(f.ranges, [0..<30])
    }

    /// 順不同で入れても同じ形になる（先読みは前後どちらへも伸びる）。
    func testInsertionOrderDoesNotMatter() {
        var a = FetchedRanges()
        for r in [(30..<40), (0..<10), (10..<20)] { a.insert(r) }
        var b = FetchedRanges()
        for r in [(10..<20), (30..<40), (0..<10)] { b.insert(r) }
        XCTAssertEqual(a.ranges, b.ranges)
        XCTAssertEqual(a.ranges, [0..<20, 30..<40])
    }

    func testEmptyRangeIsIgnored() {
        var f = FetchedRanges()
        f.insert(10..<10)
        XCTAssertTrue(f.ranges.isEmpty)
        XCTAssertEqual(f.missing(in: 5..<5), [])
    }

    func testFetchedBytes() {
        var f = FetchedRanges()
        f.insert(0..<10)
        f.insert(100..<130)
        XCTAssertEqual(f.fetchedBytes, 40)
        f.insert(5..<105)          // 全部つながる
        XCTAssertEqual(f.fetchedBytes, 130)
    }

    func testRemoveAll() {
        var f = FetchedRanges([0..<10])
        f.removeAll()
        XCTAssertEqual(f.missing(in: 0..<10), [0..<10])
    }

    // MARK: - 乱択で素朴な実装と突き合わせる

    /// 境界・隣接・包含の組み合わせは手で並べきれない。**穴を 1 バイトでも見落とすと
    /// そこがゼロで表示される**ので、バイト単位の素朴な実装と一致するまで確かめる。
    func testMatchesNaiveImplementationUnderRandomInserts() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<200 {
            var fast = FetchedRanges()
            var slow = Naive()

            for _ in 0..<12 {
                let lo = Int.random(in: 0..<80, using: &rng)
                let len = Int.random(in: 0..<20, using: &rng)
                fast.insert(lo..<(lo + len))
                slow.insert(lo..<(lo + len))
            }

            for _ in 0..<12 {
                let lo = Int.random(in: 0..<80, using: &rng)
                let len = Int.random(in: 0..<30, using: &rng)
                let query = lo..<(lo + len)
                XCTAssertEqual(
                    fast.missing(in: query), slow.missing(in: query),
                    "trial \(trial) query \(query) ranges \(fast.ranges)"
                )
            }

            // 正規化の不変条件：昇順・重なりなし・隣接なし・空でない
            for r in fast.ranges { XCTAssertFalse(r.isEmpty) }
            for (a, b) in zip(fast.ranges, fast.ranges.dropFirst()) {
                XCTAssertLessThan(a.upperBound, b.lowerBound, "隣接か重なりが残っている")
            }
        }
    }
}
