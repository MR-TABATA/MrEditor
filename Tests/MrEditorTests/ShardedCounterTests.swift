import XCTest
@testable import MrEditorCore

/// 数える器の試験。**上限の約束**（打ち切ったら打ち切ったと言う）をここで固定する。
final class ShardedCounterTests: XCTestCase {

    func testCountsAndSortsByCountDescending() {
        let c = ShardedCounter()
        for _ in 0..<3 { c.add("200") }
        c.add("500")
        for _ in 0..<2 { c.add("404") }

        XCTAssertEqual(c.distinctCount, 3)
        XCTAssertFalse(c.didTruncate)
        XCTAssertEqual(c.sortedRows().map(\.value), ["200", "404", "500"])
        XCTAssertEqual(c.sortedRows().map(\.count), [3, 2, 1])
    }

    /// 同数のときは値の昇順で安定させる（走査の並列順で表の並びが変わらないように）。
    func testTiesAreBrokenByValueAscending() {
        let c = ShardedCounter()
        for v in ["b", "a", "c"] { c.add(v) }
        XCTAssertEqual(c.sortedRows().map(\.value), ["a", "b", "c"])
    }

    func testMergesCountsFromParallelAdds() {
        let c = ShardedCounter()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for i in 0..<1000 { c.add("v\(i % 50)") }
        }
        XCTAssertEqual(c.distinctCount, 50)
        XCTAssertEqual(c.sortedRows().reduce(0) { $0 + $1.count }, 8000)
    }

    /// 上限を超えたら**それ以降に初めて出た値**だけをまとめ、印を立てる。
    /// 既に表にある値は最後まで正確に数え続ける（表の件数は嘘をつかない、という約束）。
    func testTruncatesBeyondCapButKeepsKnownValuesExact() {
        let c = ShardedCounter(cap: 640)          // 64 シャード × 10
        for i in 0..<5000 { c.add("k\(i)") }      // 上限を大きく超える種類数
        XCTAssertTrue(c.didTruncate)
        XCTAssertLessThan(c.distinctCount, 5000)

        // 表に載っている値をもう一度数えると、その件数は増え続ける。
        let known = c.sortedRows().first!.value
        let before = c.sortedRows().first(where: { $0.value == known })!.count
        for _ in 0..<10 { c.add(known) }
        let after = c.sortedRows().first(where: { $0.value == known })!.count
        XCTAssertEqual(after, before + 10)
    }

    /// 打ち切った行数を数えている（「N 行を 1 行にまとめた」と言えるように）。
    func testTruncatedRowsAreCounted() {
        let c = ShardedCounter(cap: 64)           // 1 シャードあたり 1 種類
        for i in 0..<2000 { c.add("k\(i)") }
        XCTAssertGreaterThan(c.truncatedRows, 0)
        XCTAssertEqual(c.truncatedRows + c.sortedRows().reduce(0) { $0 + $1.count }, 2000,
                       "数えた件数と打ち切った件数の合計が、入れた件数と合わない")
    }
}