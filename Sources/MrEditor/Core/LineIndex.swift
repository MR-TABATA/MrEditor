import Foundation

/// 行頭バイトオフセットの疎な索引。
///
/// 全行のオフセットを持つと 1億行で 800MB になるため、`stride` 行ごとに
/// 1 つだけ保存する。任意の行へは「最寄りの索引点から前方スキャン」で到達する。
/// 行分割はバイト 0x0A (`\n`) のみで行う。UTF-8 / Shift-JIS / EUC-JP の
/// いずれもマルチバイト文字の途中に 0x0A は現れないため安全。
final class LineIndex: OriginalLineLocator {
    let stride: Int

    /// offsets[k] = 行番号 k*stride の先頭バイトオフセット。offsets[0] は常に 0。
    private(set) var offsets: [Int] = [0]
    /// 全索引完了後の確定行数。
    private(set) var exactLineCount: Int = 0
    /// 先頭サンプルから求めた推定行数（索引完了前の表示用）。
    private(set) var estimatedLineCount: Int = 1
    /// 全索引が完了したか。
    private(set) var isComplete: Bool = false

    /// 走査済みのバイト数（増分拡張＝tail -f の起点）。
    private var scannedBytes = 0
    /// これまでに数えた改行（0x0A）の数。
    private var nlCount = 0

    private let buffer: FileBuffer

    init(buffer: FileBuffer, stride: Int = 2000) {
        self.buffer = buffer
        self.stride = stride
    }

    /// 表示に使う現在の最良行数（確定 > 推定）。
    var displayLineCount: Int {
        isComplete ? exactLineCount : estimatedLineCount
    }

    /// 原本に含まれる改行（0x0A）の数（全索引完了後に確定）。
    /// PieceTable 初期化時の原本全スキャンを省くために渡す（`isComplete` 後のみ有効）。
    var originalNewlines: Int { nlCount }

    /// 先頭サンプルから行数を推定する（即時表示用、同期・高速）。
    func estimatePrefix() {
        let sample = min(buffer.count, 1 << 20) // 先頭 1MB
        guard sample > 0 else {
            estimatedLineCount = 0
            return
        }
        var newlines = 0
        buffer.withBytes(in: 0..<sample) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            while i < n {
                if let found = memchr(base + i, 0x0A, n - i) {
                    let off = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                    newlines += 1
                    i = off + 1
                } else {
                    break
                }
            }
        }
        let avg = newlines > 0 ? Double(sample) / Double(newlines) : 80.0
        estimatedLineCount = max(1, Int(Double(buffer.count) / avg))
    }

    /// 全体を走査して疎索引を構築する（バックグラウンド）。
    /// progress / completion はメインスレッドで呼ばれる。
    func buildInBackground(progress: @escaping (Double) -> Void,
                           completion: @escaping () -> Void) {
        let total = buffer.count
        let stride = self.stride
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var newOffsets: [Int] = [0]
            newOffsets.reserveCapacity(1 << 20)
            var lineNo = 0
            var lastReport = 0

            self.buffer.withBytes(in: 0..<total) { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var i = 0
                while i < total {
                    guard let found = memchr(base + i, 0x0A, total - i) else { break }
                    let off = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                    lineNo += 1
                    if lineNo % stride == 0 {
                        newOffsets.append(off + 1) // 次の行（行番号 lineNo）の先頭
                    }
                    i = off + 1
                    if i - lastReport >= (64 << 20) { // 64MB ごとに進捗報告
                        lastReport = i
                        let p = Double(i) / Double(total)
                        DispatchQueue.main.async { progress(p) }
                    }
                }
            }
            // nlCount（改行数）と末尾の不完全行を分けて保持する（増分拡張のため）。
            let nl = lineNo
            let trailing = (total > 0) && self.buffer.withBytes(in: (total - 1)..<total) { ($0.first ?? 0x0A) != 0x0A }

            DispatchQueue.main.async {
                self.offsets = newOffsets
                self.nlCount = nl
                self.scannedBytes = total
                self.exactLineCount = nl + (trailing ? 1 : 0)
                self.isComplete = true
                progress(1.0)
                completion()
            }
        }
    }

    /// ファイルが伸びたぶんを索引に継ぎ足す（tail -f）。メインスレッドで呼ぶ。
    /// `newCount` は新しいファイルサイズ。`buffer` は既に再マップ済みであること。
    func extend(toByte newCount: Int) {
        guard isComplete, newCount > scannedBytes else { return }
        let from = scannedBytes
        let stride = self.stride
        var nl = nlCount

        buffer.withBytes(in: from..<newCount) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            while i < n {
                guard let found = memchr(base + i, 0x0A, n - i) else { break }
                let off = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                nl += 1
                if nl % stride == 0 {
                    offsets.append(from + off + 1)   // ファイル先頭からの絶対オフセット
                }
                i = off + 1
            }
        }
        nlCount = nl
        scannedBytes = newCount
        let trailing = buffer.withBytes(in: (newCount - 1)..<newCount) { ($0.first ?? 0x0A) != 0x0A }
        exactLineCount = nl + (trailing ? 1 : 0)
    }

    /// 原本 `[0, x)` に含まれる改行（0x0A）の数＝バイト `x` の直前までの行数。
    /// 最寄りの疎索引点から `x` までを memchr で数えるため O(stride)。`isComplete` 後のみ有効。
    func newlineCount(upTo x: Int) -> Int {
        let target = min(max(0, x), buffer.count)
        guard target > 0 else { return 0 }
        // offsets[block] <= target を満たす最大の block を二分探索。
        var lo = 0, hi = offsets.count - 1, block = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if offsets[mid] <= target { block = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let startPos = offsets[block]
        var count = block * stride     // offsets[block] は行 block*stride の先頭＝改行 block*stride 個の後。
        if startPos < target {
            buffer.withBytes(in: startPos..<target) { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let n = raw.count
                var i = 0
                while i < n {
                    guard let f = memchr(base + i, 0x0A, n - i) else { break }
                    count += 1
                    i = (UnsafeRawPointer(f) - UnsafeRawPointer(base)) + 1
                }
            }
        }
        return count
    }

    /// 行 `line`（0始まり）の先頭バイトオフセット。最寄りの疎索引点から前方スキャンで求める（O(stride)）。
    func byteOffset(ofLineStart line: Int) -> Int {
        guard line > 0 else { return 0 }
        let total = buffer.count
        let block = min(line / stride, offsets.count - 1)
        var pos = offsets[block]
        var skip = line - block * stride
        guard skip > 0 else { return pos }
        buffer.withBytes(in: pos..<total) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            while skip > 0 && i < n {
                guard let f = memchr(base + i, 0x0A, n - i) else { i = n; break }
                i = (UnsafeRawPointer(f) - UnsafeRawPointer(base)) + 1
                skip -= 1
            }
            pos += i
        }
        return pos
    }

    /// 原本で `m` 番目（0始まり）の 0x0A のバイトオフセット。行 `m+1` はその直後から始まる。
    func newlineOffset(ordinal m: Int) -> Int {
        byteOffset(ofLineStart: m + 1) - 1
    }

    /// 行 [start, start+count) のバイト範囲を 1 回の前方スキャンで求める。
    /// 索引未構築の領域（block 範囲外）は空配列で返す。
    func lineRanges(from start: Int, count: Int) -> [Range<Int>] {
        guard count > 0, start >= 0 else { return [] }
        let block = start / stride
        guard block < offsets.count else { return [] }

        let total = buffer.count
        let startPos = offsets[block]
        var result: [Range<Int>] = []
        result.reserveCapacity(count)

        buffer.withBytes(in: startPos..<total) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            // 目的の開始行まで改行を読み飛ばす。
            var skip = start - block * stride
            while skip > 0 && i < n {
                if let found = memchr(base + i, 0x0A, n - i) {
                    i = (UnsafeRawPointer(found) - UnsafeRawPointer(base)) + 1
                    skip -= 1
                } else {
                    i = n
                    break
                }
            }
            if skip > 0 { return } // そこまで行が無い

            var produced = 0
            while produced < count && i < n {
                let lineStartByte = startPos + i
                if let found = memchr(base + i, 0x0A, n - i) {
                    let off = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                    var end = startPos + off
                    if end > lineStartByte, base[off - 1] == 0x0D { // CRLF の CR を除去
                        end -= 1
                    }
                    result.append(lineStartByte..<end)
                    i = off + 1
                } else {
                    // 改行で終わらない最終行
                    result.append(lineStartByte..<(startPos + n))
                    produced += 1
                    break
                }
                produced += 1
            }
        }
        return result
    }
}
