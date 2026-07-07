import XCTest
@testable import MrEditor

/// `LineIndex` の並列構築が、素朴な参照計算と完全一致することを検証する。
/// チャンク幅を極小にして、多チャンク＆チャンク境界が行の途中に落ちる経路を必ず踏ませる。
final class LineIndexTests: XCTestCase {

    /// 参照側：バイト列から行頭オフセット列・プレフィックス改行数を前計算し、各問い合わせを O(1) で返す。
    private struct Naive {
        let bytes: [UInt8]
        let newlineCount: Int
        /// prefixNL[i] = [0, i) の改行数（size = count+1）。
        private let prefixNL: [Int]
        /// lineStarts[line] = 行 line の先頭バイト（size = newlineCount+1、末尾は最終改行の直後）。
        private let lineStarts: [Int]

        init(bytes: [UInt8]) {
            self.bytes = bytes
            var pfx = [Int](repeating: 0, count: bytes.count + 1)
            var starts = [0]
            var nl = 0
            for (i, b) in bytes.enumerated() {
                pfx[i + 1] = pfx[i] + (b == 0x0A ? 1 : 0)
                if b == 0x0A { nl += 1; starts.append(i + 1) }
            }
            self.prefixNL = pfx
            self.lineStarts = starts
            self.newlineCount = nl
        }

        var lineCount: Int {
            guard !bytes.isEmpty else { return 0 }
            return newlineCount + (bytes.last == 0x0A ? 0 : 1)
        }
        /// 行 line（0始まり）の先頭バイト。
        func lineStart(_ line: Int) -> Int {
            line < lineStarts.count ? lineStarts[line] : bytes.count
        }
        /// [0, x) の改行数。
        func newlines(upTo x: Int) -> Int {
            prefixNL[min(max(0, x), bytes.count)]
        }
        /// 行 line の内容範囲（末尾 0x0A を除く。CRLF の CR は LineIndex 同様に除去）。
        func lineRange(_ line: Int) -> Range<Int> {
            let start = lineStart(line)
            var end = start
            while end < bytes.count && bytes[end] != 0x0A { end += 1 }
            if end > start && bytes[end - 1] == 0x0D { end -= 1 }
            return start..<end
        }
    }

    private func buildIndex(_ content: [UInt8], stride: Int, chunkSize: Int) -> LineIndex {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("lineindex-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: Data(content))
        defer { try? FileManager.default.removeItem(at: url) }

        let buffer = FileBuffer(url: url)!
        let idx = LineIndex(buffer: buffer, stride: stride, chunkSize: chunkSize)
        let done = expectation(description: "index built")
        idx.buildInBackground(progress: { _ in }, completion: { done.fulfill() })
        wait(for: [done], timeout: 5)
        return idx
    }

    private func check(_ content: [UInt8], stride: Int, chunkSize: Int) {
        let naive = Naive(bytes: content)
        let idx = buildIndex(content, stride: stride, chunkSize: chunkSize)
        let label = "len=\(content.count) stride=\(stride) chunk=\(chunkSize)"

        XCTAssertTrue(idx.isComplete, label)
        XCTAssertEqual(idx.exactLineCount, naive.lineCount, "lineCount \(label)")
        XCTAssertEqual(idx.originalNewlines, naive.newlineCount, "newlines \(label)")

        // 行頭オフセット（全行）。
        for line in 0...naive.lineCount {
            XCTAssertEqual(idx.byteOffset(ofLineStart: line), naive.lineStart(line),
                           "lineStart(\(line)) \(label)")
        }
        // 各バイト境界の改行数（＝行番号）。
        for x in 0...content.count {
            XCTAssertEqual(idx.newlineCount(upTo: x), naive.newlines(upTo: x),
                           "newlineCount(upTo:\(x)) \(label)")
        }
        // 表示用の行範囲（連続ウィンドウ）。
        let ranges = idx.lineRanges(from: 0, count: max(1, naive.lineCount))
        XCTAssertEqual(ranges.count, naive.lineCount, "lineRanges count \(label)")
        for (line, r) in ranges.enumerated() {
            XCTAssertEqual(r, naive.lineRange(line), "lineRange(\(line)) \(label)")
        }
    }

    func testParallelIndexMatchesNaive() {
        // 改行の入り方・末尾改行有無・CRLF・空行を混ぜる（小入力に極小チャンクで境界跨ぎを網羅）。
        let smallVariants: [[UInt8]] = [
            Array("".utf8),
            Array("no newline".utf8),
            Array("a\nb\nc\n".utf8),
            Array("a\nb\nc".utf8),
            Array("\n\n\n".utf8),
            Array("crlf\r\nmixed\nlf\r\n".utf8),
        ]
        for v in smallVariants {
            for chunk in [1, 2, 3, 7, 64] {
                for stride in [1, 3, 8] {
                    check(v, stride: stride, chunkSize: chunk)
                }
            }
        }

        // 多チャンク・マージ経路は中規模入力で（チャンクは行より大きめにしてチャンク数を抑える）。
        let big1 = Array((0..<400).map { "line \($0) の内容テスト\n" }.joined().utf8)
        let big2 = Array((0..<400).map { $0 % 5 == 0 ? "x\r\n" : "yy\n" }.joined().utf8)
        for v in [big1, big2] {
            for chunk in [16, 64, 256] {
                for stride in [1, 7] {
                    check(v, stride: stride, chunkSize: chunk)
                }
            }
        }
    }
}
