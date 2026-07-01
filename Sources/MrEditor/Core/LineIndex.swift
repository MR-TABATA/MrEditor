import Foundation

/// 行頭バイトオフセットの疎な索引。
///
/// 全行のオフセットを持つと 1億行で 800MB になるため、おおよそ `stride` 行ごとに
/// 1 つだけ「(行番号, その行の先頭バイト)」を保存する。任意の行へは「最寄りの
/// 索引点から前方スキャン」で到達する（スキャン量は最大でも約 2*stride 行）。
///
/// 構築は複数コアで並列に走査する（10GB クラスで開くまでの待ち時間を短縮）。
/// 並列化のためチャンク境界ごとに独立サンプルを採るので、サンプルの行番号は
/// 一様な stride 倍数ではない。ゆえに検索は行番号／バイトの二分探索で行う。
///
/// 行分割はバイト 0x0A (`\n`) のみで行う。UTF-8 / Shift-JIS / EUC-JP の
/// いずれもマルチバイト文字の途中に 0x0A は現れないため安全。
final class LineIndex: OriginalLineLocator {
    let stride: Int

    /// 疎索引サンプル。`sampleLines[j]` 行目の先頭が `sampleOffsets[j]` バイト。
    /// どちらも昇順。先頭は常に (0, 0)。
    private var sampleLines: [Int] = [0]
    private var sampleOffsets: [Int] = [0]
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
    /// 並列走査の 1 チャンクのバイト幅。テストでは小さくして多チャンク・境界跨ぎを踏ませる。
    private let chunkSize: Int

    init(buffer: FileBuffer, stride: Int = 2000, chunkSize: Int = 16 << 20) {
        self.buffer = buffer
        self.stride = stride
        self.chunkSize = max(1, chunkSize)
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

    /// 1 チャンクの走査結果（改行数と、チャンク内 stride 倍数ごとの (チャンク内行番号, 絶対オフセット)）。
    private struct ChunkResult {
        var newlines: Int = 0
        var samples: [(localLine: Int, offset: Int)] = []
    }

    /// 全体を複数コアで並列走査して疎索引を構築する（バックグラウンド）。
    /// progress / completion はメインスレッドで呼ばれる。
    func buildInBackground(progress: @escaping (Double) -> Void,
                           completion: @escaping () -> Void) {
        let total = buffer.count
        let stride = self.stride
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard total > 0 else {
                DispatchQueue.main.async {
                    self.sampleLines = [0]; self.sampleOffsets = [0]
                    self.nlCount = 0; self.scannedBytes = 0
                    self.exactLineCount = 0; self.isComplete = true
                    progress(1.0); completion()
                }
                return
            }

            // コア数によらずチャンクを細かめに切り、負荷分散と進捗の細分化を両立させる。
            let chunkSize = self.chunkSize
            let chunkCount = (total + chunkSize - 1) / chunkSize
            var results = [ChunkResult](repeating: ChunkResult(), count: chunkCount)

            let progressLock = NSLock()
            var completedChunks = 0
            let reportEvery = max(1, chunkCount / 50)

            results.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: chunkCount) { ci in
                    let cs = ci * chunkSize
                    let ce = min(total, cs + chunkSize)
                    var nl = 0
                    var samples: [(Int, Int)] = []
                    self.buffer.withBytes(in: cs..<ce) { raw in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                        let n = raw.count
                        var i = 0
                        while i < n {
                            guard let f = memchr(base + i, 0x0A, n - i) else { break }
                            let off = UnsafeRawPointer(f) - UnsafeRawPointer(base)
                            nl += 1
                            if nl % stride == 0 {
                                // このチャンク内 nl 番目の改行の直後＝行の先頭。
                                samples.append((nl, cs + off + 1))
                            }
                            i = off + 1
                        }
                    }
                    // 異なる index への書き込みは非重複なのでロック不要。
                    buf[ci] = ChunkResult(newlines: nl, samples: samples)

                    progressLock.lock()
                    completedChunks += 1
                    let done = completedChunks
                    progressLock.unlock()
                    if done % reportEvery == 0 {
                        DispatchQueue.main.async { progress(Double(done) / Double(chunkCount)) }
                    }
                }
            }

            // チャンク結果を順に連結し、グローバル行番号へ変換。
            var lines: [Int] = [0]
            var offs: [Int] = [0]
            lines.reserveCapacity(total / (stride * 64) + chunkCount)
            offs.reserveCapacity(lines.capacity)
            var base = 0
            for r in results {
                for (localLine, offset) in r.samples {
                    lines.append(base + localLine)
                    offs.append(offset)
                }
                base += r.newlines
            }
            let nl = base
            let trailing = self.buffer.withBytes(in: (total - 1)..<total) { ($0.first ?? 0x0A) != 0x0A }

            DispatchQueue.main.async {
                self.sampleLines = lines
                self.sampleOffsets = offs
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
                    sampleLines.append(nl)                // グローバル行番号
                    sampleOffsets.append(from + off + 1)  // ファイル先頭からの絶対オフセット
                }
                i = off + 1
            }
        }
        nlCount = nl
        scannedBytes = newCount
        let trailing = buffer.withBytes(in: (newCount - 1)..<newCount) { ($0.first ?? 0x0A) != 0x0A }
        exactLineCount = nl + (trailing ? 1 : 0)
    }

    // MARK: - 疎索引の探索

    /// `sampleOffsets[j] <= x` を満たす最大の `j`（昇順・二分探索）。
    private func sampleIndex(forByte x: Int) -> Int {
        var lo = 0, hi = sampleOffsets.count - 1, best = 0
        while lo <= hi {
            let m = (lo + hi) / 2
            if sampleOffsets[m] <= x { best = m; lo = m + 1 } else { hi = m - 1 }
        }
        return best
    }

    /// `sampleLines[j] <= line` を満たす最大の `j`（昇順・二分探索）。
    private func sampleIndex(forLine line: Int) -> Int {
        var lo = 0, hi = sampleLines.count - 1, best = 0
        while lo <= hi {
            let m = (lo + hi) / 2
            if sampleLines[m] <= line { best = m; lo = m + 1 } else { hi = m - 1 }
        }
        return best
    }

    // MARK: - OriginalLineLocator

    /// 原本 `[0, x)` に含まれる改行（0x0A）の数＝バイト `x` の直前までの行数。
    /// 最寄りの疎索引点から `x` までを memchr で数えるため O(stride)。`isComplete` 後のみ有効。
    func newlineCount(upTo x: Int) -> Int {
        let target = min(max(0, x), buffer.count)
        guard target > 0 else { return 0 }
        let j = sampleIndex(forByte: target)
        let startPos = sampleOffsets[j]
        var count = sampleLines[j]
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
        let j = sampleIndex(forLine: line)
        var pos = sampleOffsets[j]
        var skip = line - sampleLines[j]
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

    // MARK: - 表示用の行範囲

    /// 行 [start, start+count) のバイト範囲を 1 回の前方スキャンで求める。
    /// 索引未構築の領域（最寄り索引点から遠すぎる）は空配列で返す。
    func lineRanges(from start: Int, count: Int) -> [Range<Int>] {
        guard count > 0, start >= 0 else { return [] }
        let j = sampleIndex(forLine: start)
        let startLine = sampleLines[j]
        // 完成索引ならサンプル間隔は約 2*stride 行以内。それを超える前方スキャンは
        // 索引未完成領域とみなして空で返す（巨大スキャンを避ける）。
        guard start - startLine <= 4 * stride else { return [] }
        let startPos = sampleOffsets[j]

        let total = buffer.count
        var result: [Range<Int>] = []
        result.reserveCapacity(count)

        buffer.withBytes(in: startPos..<total) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            // 目的の開始行まで改行を読み飛ばす。
            var skip = start - startLine
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
