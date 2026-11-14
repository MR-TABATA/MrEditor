import Foundation

/// C1「値の集計」の中身。走査（`ScanEngine`）と取り出し（`ValueExtractor`）と
/// 数える器（`ShardedCounter`）を繋ぐ。**UI を知らない**ので単体で試験できる。
final class AggregateRunner {

    struct Result {
        var rows: [(value: String, count: Int)] = []
        /// 走査した行数（フィルタ中はその対象行数）。
        var scannedLines = 0
        /// 値が取り出せた行数（`(該当なし)` を除く）。
        var matchedLines = 0
        var distinctCount = 0
        /// 上限を超えてまとめた行数。0 なら打ち切っていない。
        var truncatedRows = 0
        var elapsed: TimeInterval = 0
    }

    private let engine = ScanEngine()
    private var cancelled = false

    func cancel() {
        cancelled = true
        engine.cancel()
    }

    /// 集計する。`completion` はメインスレッド。打ち切られた場合は呼ばれない。
    func run(document: ActiveDocument,
             mode: ValueExtractor.Mode,
             options: ValueExtractor.Options,
             cap: Int = ShardedCounter.defaultCap,
             progress: @escaping (Double) -> Void,
             completion: @escaping (Result) -> Void) {
        cancelled = false

        // 小ファイル（編集ペイン）は本文がもう手元にある。読み直さない。
        if let text = document.text {
            runOverText(text, document: document, mode: mode, options: options, cap: cap,
                        completion: completion)
            return
        }
        guard let url = document.fileURL else { return }
        scanFile(url: url, document: document, mode: mode, options: options, cap: cap,
                 progress: progress, completion: completion)
    }

    // MARK: - 大ファイル

    private func scanFile(url: URL,
                          document: ActiveDocument,
                          mode: ValueExtractor.Mode,
                          options: ValueExtractor.Options,
                          cap: Int,
                          progress: @escaping (Double) -> Void,
                          completion: @escaping (Result) -> Void) {
        let counter = ShardedCounter(cap: cap)
        let stats = RunStats()
        let isUTF8 = document.encoding == .utf8
        let encoding = document.encoding.stringEncoding
        // **取り出し器は走査の前に 1 回だけ作る。** 行ごとに作ると 10GB で 40 秒かかった
        // （準備を 1 回にして 3 秒台に戻る）。
        let extractor = ValueExtractor.Compiled(mode: mode, options: options)
        // 構造化 CSV/TSV の 1 行目は列名なので数えない（画面もヘッダとして扱っている）。
        let skipsHeader = document.structuredMode == .csv || document.structuredMode == .tsv
        let t0 = Date()

        engine.scanLines(
            url: url,
            filter: document.filterMatchLines,
            skipsHeader: skipsHeader,
            makeSink: { Sink(counter: counter, stats: stats) },
            consume: { sink, bytes, _ in
                let value: String
                if isUTF8 {
                    value = extractor.value(from: bytes)
                } else {
                    // 非 UTF-8 はバイトのまま切れない（SJIS の 2 バイト目に区切りと同じ値が出る）。
                    let line = String(data: Data(buffer: bytes), encoding: encoding)
                        ?? String(decoding: bytes, as: UTF8.self)
                    value = extractor.value(fromString: line)
                }
                sink.add(value)
            },
            // 溜めたぶんはチャンクの終わりで流す（最後まで抱えるとチャンク数に比例して太る）。
            finishChunk: { sink in sink.flush() },
            progress: progress,
            completion: { [weak self] sinks, _, scanStats in
                guard let self, !self.cancelled else { return }
                _ = sinks
                var result = Result()
                result.rows = counter.sortedRows()
                result.scannedLines = stats.consideredLines
                result.matchedLines = stats.matchedLines
                result.distinctCount = counter.distinctCount
                result.truncatedRows = counter.truncatedRows
                result.elapsed = Date().timeIntervalSince(t0)
                _ = scanStats
                completion(result)
            })
    }

    // MARK: - 小ファイル

    private func runOverText(_ text: String,
                             document: ActiveDocument,
                             mode: ValueExtractor.Mode,
                             options: ValueExtractor.Options,
                             cap: Int,
                             completion: @escaping (Result) -> Void) {
        let counter = ShardedCounter(cap: cap)
        let filter = document.filterMatchLines.map { Set($0) }
        let skipsHeader = document.structuredMode == .csv || document.structuredMode == .tsv
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = Date()
            let extractor = ValueExtractor.Compiled(mode: mode, options: options)
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }     // 末尾改行の余り（幻の空行を作らない）
            var considered = 0
            var matched = 0
            for (i, line) in lines.enumerated() {
                if skipsHeader && i == 0 { continue }
                if let filter, !filter.contains(i) { continue }
                considered += 1
                let v = extractor.value(fromString: line)
                if v != ValueExtractor.missing { matched += 1 }
                counter.add(v)
            }
            var result = Result()
            result.rows = counter.sortedRows()
            result.scannedLines = considered
            result.matchedLines = matched
            result.distinctCount = counter.distinctCount
            result.truncatedRows = counter.truncatedRows
            result.elapsed = Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                completion(result)
            }
        }
    }

    // MARK: - チャンクごとの受け皿

    /// チャンク内では**ロックを取らずに**ローカル辞書へ溜め、一定量でまとめて共有の器へ流す。
    /// 溜めっぱなしにすると同じ値が並列度ぶん重複してメモリを食うので、上限で必ず流す。
    private struct Sink {
        /// ローカルに溜める上限。64 スレッド × 2 万 × 約 110 バイト ≒ 140MB が最悪値。
        static let localCap = 20_000

        let counter: ShardedCounter
        let stats: RunStats
        var local: [String: Int] = [:]
        var considered = 0
        var matched = 0

        init(counter: ShardedCounter, stats: RunStats) {
            self.counter = counter
            self.stats = stats
            local.reserveCapacity(1024)
        }

        mutating func add(_ value: String) {
            considered += 1
            if value != ValueExtractor.missing { matched += 1 }
            local[value, default: 0] += 1
            if local.count >= Self.localCap { flushLocal() }
        }

        mutating func flush() {
            flushLocal()
            stats.add(considered: considered, matched: matched)
            considered = 0
            matched = 0
        }

        private mutating func flushLocal() {
            counter.add(contentsOf: local)
            local.removeAll(keepingCapacity: true)
        }
    }

    /// 行数の集計だけを共有する小さな箱（チャンクの終わりに 1 回だけ触る）。
    private final class RunStats {
        private let lock = NSLock()
        private(set) var consideredLines = 0
        private(set) var matchedLines = 0

        func add(considered: Int, matched: Int) {
            lock.lock()
            consideredLines += considered
            matchedLines += matched
            lock.unlock()
        }
    }
}