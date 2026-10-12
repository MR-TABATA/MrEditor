import Foundation

/// 検索モード。
/// 巨大ファイルをストリーム走査して一致行を集める検索エンジン。
///
/// 行単位（0x0A 区切り）に走査する。UTF-8 はクエリのバイト列をそのまま探索（高速）、
/// 非 UTF-8（Shift-JIS/EUC）は行をデコードして文字列照合（正確）。
/// 全文をメモリに乗せない（mmap をそのまま舐める）。一致行は上限まで保持する。
final class SearchEngine {
    struct Result {
        var lines: [Int] = []      // 一致した行番号（昇順・上限まで）
        var lineCount = 0          // 一致行の総数（上限超過も計上）
        var isComplete = false
        var capped = false
        /// 改行で終わった最後の行の次（バイト位置・行番号）。伸びたファイルの続きを
        /// 走査し直すときの再開点。改行の無い末尾の行はここに含めない（まだ伸びうる）。
        var resumeByte = 0
        var resumeLine = 0
    }

    private let buffer: ByteSource
    private let encoding: DetectedEncoding
    private let lineCap = 1_000_000
    private let queue = DispatchQueue(label: "MrEditor.search", qos: .userInitiated)

    /// 世代カウンタ。再検索/キャンセルで増やし、走査側は値の変化で打ち切る。
    /// （aligned Int の読みは arm64 で原子的。遅延キャンセルの良性レース。）
    private var generation = 0

    init(buffer: ByteSource, encoding: DetectedEncoding) {
        self.buffer = buffer
        self.encoding = encoding
    }

    /// 進行中の検索を打ち切る。
    func cancel() { generation += 1 }

    /// 指定モードで全体を走査する。progress / completion はメインスレッドで呼ぶ。
    /// `caseSensitive` は terms モードに効く（regex は compile 時に決まる）。
    ///
    /// `resume` に完了済みの結果を渡すと、再開点から先だけを走査して継ぎ足す（`tail -f` で
    /// 伸びていくファイル用）。改行の無かった末尾の行は、先の結果から外して数え直す。
    func search(_ mode: SearchMode, caseSensitive: Bool = false,
                resume: Result? = nil,
                progress: @escaping (Result, Double) -> Void,
                completion: @escaping (Result) -> Void) {
        generation += 1
        let gen = generation
        let total = buffer.count
        let cap = lineCap
        // 照合の規則は `LineMatcher` にしかない（横断検索と同じ 1 箇所を通す）。
        let matcher = LineMatcher(mode: mode, caseSensitive: caseSensitive, encoding: encoding)
        guard !matcher.isEmpty else {
            DispatchQueue.main.async { if self.generation == gen { completion(Result(isComplete: true)) } }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            var res = Result()
            var lineNo = 0
            var start = 0
            if let r = resume, r.isComplete, r.resumeByte <= total {
                res = r
                res.isComplete = false
                let kept = r.lines.filter { $0 < r.resumeLine }
                res.lineCount -= r.lines.count - kept.count
                res.lines = kept
                lineNo = r.resumeLine
                start = r.resumeByte
            }
            var reported = start

            self.buffer.withBytes(in: 0..<total) { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var i = start
                while i < total {
                    let nl = memchr(base + i, 0x0A, total - i)
                    let lineEnd = nl != nil ? (UnsafeRawPointer(nl!) - UnsafeRawPointer(base)) : total
                    let lineLen = lineEnd - i

                    if matcher.matches(base + i, lineLen) {
                        res.lineCount += 1
                        if res.lines.count < cap { res.lines.append(lineNo) } else { res.capped = true }
                    }
                    lineNo += 1
                    i = (nl != nil) ? lineEnd + 1 : total
                    if nl != nil { res.resumeByte = i; res.resumeLine = lineNo }

                    if i - reported >= (64 << 20) {        // 64MB ごとに進捗報告＆キャンセル確認
                        if self.generation != gen { return }
                        reported = i
                        let snapshot = res
                        let p = Double(i) / Double(max(total, 1))
                        DispatchQueue.main.async { if self.generation == gen { progress(snapshot, p) } }
                    }
                }
            }
            if self.generation != gen { return }
            res.isComplete = true
            let final = res
            DispatchQueue.main.async { if self.generation == gen { completion(final) } }
        }
    }

}
