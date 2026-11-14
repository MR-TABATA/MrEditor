import Foundation

/// C3「時間分布」。**いつ増えたか**を出す。
///
/// 本命は**フィルタとの併用**——「ERROR だけ絞ってから時間分布」が障害調査の第一手。
/// なので対象の決め方（ヘッダ除外・フィルタ中は一致行だけ）は C1・C2 と同じ口
/// （`ScanEngine.scanLines`）を通る。
///
/// ## 形式はソースごとに 1 回だけ決める
///
/// 行ごとに総当たりで解釈すると、遅い上に**行ごとに解釈が変わって並びが壊れる**。
/// core の `TimestampDetector.detect(sampleLines:)` に先頭のサンプルを渡して 1 回で決め、
/// 以後はその形式のバイト走査だけを回す。年やオフセットを持たない形式（syslog）で
/// **勝手に「今年・ローカル」と決めない**ため、補い方は `Options` で外から渡す。
final class TimeHistogramRunner {

    /// バケット幅の階段（秒）。棒が 60〜200 本に収まる中でいちばん細かいものを選ぶ。
    ///
    /// 仕様 §4.2 は「1 秒 / 1 分 / 5 分 / 1 時間 / 1 日 / 1 週」だけだったが、それだと
    /// **12 日のログで 1 時間＝290 本・1 日＝12 本**となり、どちらも読めない。間を足した。
    static let bucketLadder = [1, 5, 15, 30, 60, 300, 900, 1800, 3600,
                               7200, 21600, 43200, 86400, 604800, 2_592_000]

    struct Options {
        /// 年を持たない形式（syslog）で補う年。
        var assumedYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        /// 行にオフセットが無いときに使う UTC オフセット（秒）。
        var timeZoneOffset = TimeZone.current.secondsFromGMT()
        /// 目盛りの表示に使うオフセット（秒）。既定はこの Mac のタイムゾーン。
        var displayOffset = TimeZone.current.secondsFromGMT()
        /// 棒の本数の上限。
        var maxBars = 200
    }

    struct Bucket {
        /// この棒が受け持つ時間帯の開始（epoch 秒）。
        var start: Int
        var count: Int
    }

    struct Result {
        var buckets: [Bucket] = []
        var bucketSeconds = 1
        var format: TimestampFormat?
        var minSecond = 0
        var maxSecond = 0
        /// 走査した行数（対象の行）。
        var scannedLines = 0
        /// 時刻が読めた行。
        var timedLines = 0
        /// **時刻を持たない行**（スタックトレースの継続行など）。捨てずに数える。
        var untimedLines = 0
        var elapsed: TimeInterval = 0
        /// 年を補ったか（syslog のときだけ true）。画面に「補った」と出すための印。
        var suppliedYear = false
        /// 行にオフセットが無く、こちらで補ったか。
        var suppliedOffset = false

        var peak: Bucket? { buckets.max { $0.count < $1.count } }
    }

    private let engine = ScanEngine()
    private var cancelled = false

    func cancel() {
        cancelled = true
        engine.cancel()
    }

    // MARK: - 分布を出す

    func run(document: ActiveDocument,
             options: Options = Options(),
             progress: @escaping (Double) -> Void,
             completion: @escaping (Result) -> Void) {
        cancelled = false
        guard let detector = Self.detect(document: document, options: options) else {
            var empty = Result()
            empty.scannedLines = 0
            completion(empty)                       // 形式が分からない＝時刻を持たないファイル
            return
        }

        if let text = document.text {
            runOverText(text, document: document, detector: detector, options: options,
                        completion: completion)
            return
        }
        guard let url = document.fileURL else { completion(Result()); return }

        let isUTF8 = document.encoding == .utf8
        let encoding = document.encoding.stringEncoding
        let skipsHeader = document.structuredMode == .csv || document.structuredMode == .tsv
        let merged = MergedBins()
        let t0 = Date()

        engine.scanLines(
            url: url,
            filter: document.filterMatchLines,
            skipsHeader: skipsHeader,
            makeSink: { Bins() },
            consume: { bins, bytes, _ in
                if isUTF8 {
                    bins.add(detector.epochSeconds(bytes))
                } else {
                    var line = String(data: Data(buffer: bytes), encoding: encoding)
                        ?? String(decoding: bytes, as: UTF8.self)
                    bins.add(line.withUTF8 { detector.epochSeconds($0) })
                }
            },
            // チャンクの終わりに合流させる。**全チャンクぶんの秒の辞書を最後まで抱えない**
            // （抱えると 10GB＝640 チャンクで footprint が 273MB まで膨らんだ）。
            finishChunk: { bins in merged.absorb(bins) },
            progress: progress,
            completion: { [weak self] _, _, _ in
                guard let self, !self.cancelled else { return }
                completion(Self.assemble(merged.snapshot(), detector: detector, options: options,
                                         elapsed: Date().timeIntervalSince(t0)))
            })
    }

    // MARK: - 時間帯で行を選ぶ（ドラッグ選択の受け皿）

    /// `range`（epoch 秒・上限は含まない）に入る行の**全体の行番号**（0 始まり・昇順）。
    ///
    /// 分布を出したときの棒から行番号を逆算しない。**もう一度読んで、実際に入る行だけを
    /// 集める。** 時刻が前後するログ（複数ソースを混ぜたもの）では棒と行が連続しないので、
    /// 逆算は静かに嘘になる。読み直しの代金（10GB で数秒）を払って正確を取る。
    func lines(in range: Range<Int>,
               document: ActiveDocument,
               options: Options = Options(),
               cap: Int = 1_000_000,
               progress: @escaping (Double) -> Void,
               completion: @escaping (_ lines: [Int], _ capped: Bool) -> Void) {
        cancelled = false
        guard let detector = Self.detect(document: document, options: options) else {
            completion([], false)
            return
        }

        if let text = document.text {
            let picked = Self.linesOverText(text, document: document, detector: detector, range: range)
            completion(Array(picked.prefix(cap)), picked.count > cap)
            return
        }
        guard let url = document.fileURL else { completion([], false); return }

        let isUTF8 = document.encoding == .utf8
        let encoding = document.encoding.stringEncoding
        let skipsHeader = document.structuredMode == .csv || document.structuredMode == .tsv
        let budget = Budget(cap: cap)

        engine.scanLines(
            url: url,
            filter: document.filterMatchLines,
            skipsHeader: skipsHeader,
            makeSink: { Picked() },
            consume: { picked, bytes, localLine in
                guard !picked.stopped else { return }
                let sec: Int?
                if isUTF8 {
                    sec = detector.epochSeconds(bytes)
                } else {
                    var line = String(data: Data(buffer: bytes), encoding: encoding)
                        ?? String(decoding: bytes, as: UTF8.self)
                    sec = line.withUTF8 { detector.epochSeconds($0) }
                }
                guard let sec, range.contains(sec) else { return }
                picked.lines.append(localLine)
                // 上限は全チャンクの合計で見る（1 チャンクずつ上限まで貯めると、
                // 全体では上限の数百倍のメモリを使うことになる）。
                if picked.lines.count % 4096 == 0, budget.exceeded(by: 4096) {
                    picked.stopped = true
                }
            },
            progress: progress,
            completion: { [weak self] sinks, counts, _ in
                guard let self, !self.cancelled else { return }
                var offsets = [Int](repeating: 0, count: counts.count)
                var running = 0
                for (i, n) in counts.enumerated() { offsets[i] = running; running += n }
                var out: [Int] = []
                for (chunk, picked) in sinks.enumerated() where chunk < offsets.count {
                    let base = offsets[chunk]
                    for line in picked.lines { out.append(base + line) }
                }
                out.sort()
                completion(Array(out.prefix(cap)), out.count > cap)
            })
    }

    // MARK: - 形式の判定

    /// 先頭のサンプルから形式を決める。**全体は読まない。**
    static func detect(document: ActiveDocument, options: Options) -> TimestampDetector? {
        let sample = sampleLines(document: document)
        guard !sample.isEmpty else { return nil }
        return TimestampDetector.detect(sampleLines: sample,
                                        timeZoneOffset: options.timeZoneOffset,
                                        assumedYear: options.assumedYear)
    }

    private static func sampleLines(document: ActiveDocument,
                                    limitBytes: Int = 256 << 10,
                                    limitLines: Int = 1000) -> [String] {
        var sample: String
        if let text = document.text {
            sample = String(text.prefix(limitBytes))
        } else if let url = document.fileURL,
                  let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: limitBytes)) ?? Data()
            sample = String(data: data, encoding: document.encoding.stringEncoding)
                ?? String(decoding: data, as: UTF8.self)
        } else {
            return []
        }
        var lines = sample.components(separatedBy: "\n")
        if lines.count > 1 { lines.removeLast() }
        return Array(lines.prefix(limitLines))
    }

    // MARK: - 小ファイル（本文が手元にある経路）

    private func runOverText(_ text: String,
                             document: ActiveDocument,
                             detector: TimestampDetector,
                             options: Options,
                             completion: @escaping (Result) -> Void) {
        let filter = document.filterMatchLines.map { Set($0) }
        let skipsHeader = document.structuredMode == .csv || document.structuredMode == .tsv
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = Date()
            let bins = Bins()
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            for (i, line) in lines.enumerated() {
                if skipsHeader && i == 0 { continue }
                if let filter, !filter.contains(i) { continue }
                var line = line
                bins.add(line.withUTF8 { detector.epochSeconds($0) })
            }
            let result = Self.assemble([bins], detector: detector, options: options,
                                       elapsed: Date().timeIntervalSince(t0))
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                completion(result)
            }
        }
    }

    private static func linesOverText(_ text: String,
                                      document: ActiveDocument,
                                      detector: TimestampDetector,
                                      range: Range<Int>) -> [Int] {
        let filter = document.filterMatchLines.map { Set($0) }
        let skipsHeader = document.structuredMode == .csv || document.structuredMode == .tsv
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var out: [Int] = []
        for (i, line) in lines.enumerated() {
            if skipsHeader && i == 0 { continue }
            if let filter, !filter.contains(i) { continue }
            var line = line
            guard let sec = line.withUTF8({ detector.epochSeconds($0) }), range.contains(sec) else { continue }
            out.append(i)
        }
        return out
    }

    // MARK: - 合流とバケット分け

    private static func assemble(_ sinks: [Bins],
                                 detector: TimestampDetector,
                                 options: Options,
                                 elapsed: TimeInterval) -> Result {
        var counts: [Int: Int] = [:]
        var timed = 0
        var untimed = 0
        for sink in sinks {
            timed += sink.timed
            untimed += sink.untimed
            for (second, n) in sink.counts { counts[second, default: 0] += n }
        }

        var result = Result()
        result.format = detector.format
        result.elapsed = elapsed
        result.timedLines = timed
        result.untimedLines = untimed
        result.scannedLines = timed + untimed
        result.suppliedYear = (detector.format == .syslog)
        result.suppliedOffset = (detector.format == .syslog || detector.format == .apache
                                 || detector.format == .iso8601)
        guard let minSecond = counts.keys.min(), let maxSecond = counts.keys.max() else {
            return result
        }
        result.minSecond = minSecond
        result.maxSecond = maxSecond

        let width = bucketWidth(span: maxSecond - minSecond, maxBars: options.maxBars)
        result.bucketSeconds = width
        // 目盛りは表示のオフセットで切る（日本のログなら日付の境目は日本の 0 時）。
        let origin = floorTo(minSecond, width: width, offset: options.displayOffset)
        let barCount = (maxSecond - origin) / width + 1
        var bars = [Int](repeating: 0, count: max(1, barCount))
        for (second, n) in counts {
            let index = (second - origin) / width
            if index >= 0 && index < bars.count { bars[index] += n }
        }
        result.buckets = bars.enumerated().map { Bucket(start: origin + $0.offset * width, count: $0.element) }
        return result
    }

    /// 棒が `maxBars` 本に収まる中でいちばん細かい幅。
    static func bucketWidth(span: Int, maxBars: Int) -> Int {
        guard span > 0 else { return bucketLadder[0] }
        for width in bucketLadder where span / width + 1 <= maxBars { return width }
        return bucketLadder[bucketLadder.count - 1]
    }

    /// `width` の倍数へ切り下げる（表示のオフセットを効かせた上で）。
    static func floorTo(_ second: Int, width: Int, offset: Int) -> Int {
        let shifted = second + offset
        let floored = Int((Double(shifted) / Double(width)).rounded(.down)) * width
        return floored - offset
    }

    // MARK: - チャンクごとの受け皿

    /// 全チャンクぶんを 1 つに合わせる箱（チャンクの終わりに 1 回だけ触る）。
    final class MergedBins {
        private let lock = NSLock()
        private let bins = Bins()

        func absorb(_ other: Bins) {
            lock.lock()
            bins.timed += other.timed
            bins.untimed += other.untimed
            for (second, n) in other.counts { bins.counts[second, default: 0] += n }
            lock.unlock()
            other.counts.removeAll(keepingCapacity: true)
            other.timed = 0
            other.untimed = 0
        }

        func snapshot() -> [Bins] {
            lock.lock()
            defer { lock.unlock() }
            return [bins]
        }
    }

    /// 秒ごとの件数。**class なのは、1 行ごとに struct を書き戻す費用を避けるため。**
    final class Bins {
        var counts: [Int: Int] = [:]
        var timed = 0
        var untimed = 0

        init() { counts.reserveCapacity(1024) }

        func add(_ second: Int?) {
            guard let second else { untimed += 1; return }
            timed += 1
            counts[second, default: 0] += 1
        }
    }

    /// 範囲選択で拾った行（そのチャンクの中での番号）。
    final class Picked {
        var lines: [Int] = []
        var stopped = false
    }

    /// 全チャンク合計の上限を見る箱。
    final class Budget {
        private let lock = NSLock()
        private let cap: Int
        private var used = 0

        init(cap: Int) { self.cap = cap }

        func exceeded(by n: Int) -> Bool {
            lock.lock()
            used += n
            let over = used >= cap
            lock.unlock()
            return over
        }
    }
}