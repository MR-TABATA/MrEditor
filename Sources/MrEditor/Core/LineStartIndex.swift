import Foundation

/// 文字列内の位置（UTF-16）から「何行目・何桁目」を引くための行頭索引。
///
/// 小ファイル編集ペイン（`NSTextView`）が、ステータスバーのキャレット位置表示と
/// 行番号ガターの描画に使う。行頭オフセットを一度だけ数えて配列に持ち、以降は
/// 二分探索で引く（本文が変わったら作り直す）。
///
/// 巨大ファイル側は `LineIndex`（mmap の疎索引）が同じ役目を担う。こちらは
/// 全文をメモリに持つ小ファイル専用で、8MB＝数十万行でも配列 1 本に収まる。
struct LineStartIndex {
    /// 各行の先頭 UTF-16 オフセット。空文字列でも 1 要素（0）持つ＝「1 行目がある」。
    private let lineStarts: [Int]

    init(_ text: NSString) {
        var starts = [0]
        let length = text.length
        var i = 0
        while i < length {
            if text.character(at: i) == 0x000A { starts.append(i + 1) }
            i += 1
        }
        lineStarts = starts
    }

    init(_ text: String) { self.init(text as NSString) }

    /// 行数（末尾が改行なら、その後ろの空行も 1 行と数える＝キャレットが置ける行）。
    var lineCount: Int { lineStarts.count }

    /// UTF-16 位置 `location` を含む行の 0 始まり行番号。
    func lineIndex(at location: Int) -> Int {
        guard location > 0 else { return 0 }
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// 0 始まり行番号 `line` の先頭 UTF-16 オフセット。
    func start(ofLine line: Int) -> Int {
        lineStarts[min(max(0, line), lineStarts.count - 1)]
    }

    /// UTF-16 位置 `location` の (行, 桁)。ともに 1 始まり。
    /// 桁は行頭からの**文字数**（サロゲートペアや結合文字を 1 と数える）＋1。
    func position(at location: Int, in text: NSString) -> (line: Int, column: Int) {
        let loc = min(max(0, location), text.length)
        let line = lineIndex(at: loc)
        let head = start(ofLine: line)
        let column = head < loc ? text.substring(with: NSRange(location: head, length: loc - head)).count : 0
        return (line + 1, column + 1)
    }
}
