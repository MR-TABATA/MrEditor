import XCTest
@testable import MrEditorCore

/// 流れてくるバイト列から完全な行だけを取り出すところ。
///
/// **チャンクの境目は行の途中に落ちる。** そのまま出すと 1 行が 2 行に割れて並び、
/// しかも追従中は「そういうログだった」と読めてしまう。境目の扱いを固定する。
final class LineAccumulatorTests: XCTestCase {

    func testCompleteLinesComeOutWhole() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.take(Data("a\nb\nc\n".utf8)), ["a", "b", "c"])
    }

    /// **改行が来るまで行にしない。**
    func testPartialTailIsHeldBack() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.take(Data("a\nb".utf8)), ["a"])
        XCTAssertEqual(acc.take(Data("cd\n".utf8)), ["bcd"])
    }

    /// 1 バイトずつ届いても、割れない。
    func testByteByByteDeliveryStillYieldsWholeLines() {
        var acc = LineAccumulator()
        var out: [String] = []
        for byte in Data("hello\nworld\n".utf8) {
            out += acc.take(Data([byte]))
        }
        XCTAssertEqual(out, ["hello", "world"])
    }

    /// 改行だけが届いた回で、空行が 1 本出る（本当に空行なので消さない）。
    func testEmptyLinesArePreserved() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.take(Data("\n\n".utf8)), ["", ""])
    }

    func testEmptyChunkYieldsNothing() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.take(Data()), [])
    }

    /// CRLF の `\r` は落とす。残ると行末に見えない文字が付き、
    /// 比較したときだけ差分が出るという分かりにくい形になる。
    func testCarriageReturnIsStripped() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.take(Data("a\r\nb\r\n".utf8)), ["a", "b"])
    }

    /// 流れが終わったら、改行で終わっていない最後の 1 行を取り出す。
    func testFlushYieldsTheUnterminatedTail() {
        var acc = LineAccumulator()
        _ = acc.take(Data("done\nhalf".utf8))
        XCTAssertEqual(acc.flush(), ["half"])
        XCTAssertEqual(acc.flush(), [], "2 回目は空（無理に 1 行を作らない）")
    }

    func testFlushOnCleanEndYieldsNothing() {
        var acc = LineAccumulator()
        _ = acc.take(Data("done\n".utf8))
        XCTAssertEqual(acc.flush(), [])
    }

    /// 改行を含まないものを延々と食わされてもメモリを持っていかれない。
    func testHugePendingWithoutNewlineIsDropped() {
        var acc = LineAccumulator()
        let chunk = Data(repeating: 0x41, count: 1 << 20)
        for _ in 0..<5 { _ = acc.take(chunk) }
        XCTAssertLessThanOrEqual(acc.flush().first?.count ?? 0, LineAccumulator.maxPending)
    }

    /// 素朴な実装と突き合わせる。**分割の仕方によらず、結果は同じでなければならない。**
    func testAnyChunkingProducesTheSameLines() {
        let text = "one\ntwo\n\nthree\nfour\r\nfive\n"
        let expected = ["one", "two", "", "three", "four", "five"]
        var rng = SystemRandomNumberGenerator()

        for _ in 0..<200 {
            var acc = LineAccumulator()
            var out: [String] = []
            let bytes = Array(text.utf8)
            var i = 0
            while i < bytes.count {
                let n = Int.random(in: 1...7, using: &rng)
                let hi = min(i + n, bytes.count)
                out += acc.take(Data(bytes[i..<hi]))
                i = hi
            }
            out += acc.flush()
            XCTAssertEqual(out, expected)
        }
    }
}
