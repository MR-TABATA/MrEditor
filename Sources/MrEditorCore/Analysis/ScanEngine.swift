import Foundation

/// 分析 4 機能（集計・列の統計・時間分布・横断検索）が共有する走査の土台。
///
/// ## なぜ mmap ではなく pread なのか（2026-08-11 実測）
///
/// 同じ照合コード・同じ並列度で読み方だけ変えると、10GB のリテラル検索が
/// **mmap 11.70 秒（875MB/s）→ pread ＋ 使い回しバッファ 3.07 秒（3,335MB/s）**。
/// 照合側は 3 通り試した（素朴なバイト比較／行ごと `memmem`／チャンク全体を走る rg 方式）が
/// mmap 経路ではどれも 900MB/s 前後で頭打ちだった。**律速はページフォルトであって照合ではない。**
/// `rg` が 3.30 秒なので、これで互角になる。
///
/// core の `FileBuffer`（mmap）は**表示のランダムアクセス用**にそのまま残す。用途が違う。
///
/// ## 行番号について
///
/// チャンクを並列に読むので、走査中は**各チャンクの中での行番号（0 始まり）しか分からない**。
/// 全体の行番号が要る機能（横断検索・時間分布の範囲指定）は、走査後に
/// `lineCountsByChunk` の前方累和を足して求める。合流の後なら順序は確定している。
final class ScanEngine {

    /// 1 チャンクの大きさ。行を割らないため、これに加えて末尾 4KB を余分に読む。
    static let chunkSize = 16 << 20
    private static let overlap = 4096

    struct Stats {
        var bytes = 0
        var lines = 0
        var elapsed: TimeInterval = 0
        var cancelled = false
    }

    /// 進行中の走査を打ち切る。`SearchEngine` と同じ世代カウンタ方式。
    /// （aligned Int の読みは arm64 で原子的。遅延キャンセルの良性レース。）
    private var generation = 0
    private let queue = DispatchQueue(label: "MrEditor.scan", qos: .userInitiated)

    func cancel() { generation += 1 }

    /// ファイルを丸ごと走査する。
    ///
    /// - Parameters:
    ///   - makeSink: チャンクごとに 1 つ作られる受け皿（引数はチャンク番号）。
    ///     **ロック無しで書ける**のが速さの肝。フィルタ中の分析は、先に `lineCounts` で
    ///     求めた前方累和をここで捕まえて「このチャンクの先頭は全体の何行目か」を知る。
    ///   - consume: 1 行ぶんのバイト列を受け取る。`localLine` はそのチャンク内での 0 始まりの番号。
    ///   - progress / completion: メインスレッドで呼ぶ。
    ///   - finishChunk: そのチャンクの行を配り終えた時点で 1 回だけ呼ぶ。**溜め込んだものを
    ///     ここで流す**ための口。全チャンクぶんを最後まで抱えると、メモリが並列度ではなく
    ///     チャンク数（10GB なら 640）に比例して膨らむ。
    func scan<S>(url: URL,
                 makeSink: @escaping (Int) -> S,
                 consume: @escaping (inout S, UnsafeBufferPointer<UInt8>, Int) -> Void,
                 finishChunk: @escaping (inout S) -> Void = { _ in },
                 progress: @escaping (Double) -> Void,
                 completion: @escaping ([S], [Int], Stats) -> Void) {
        generation += 1
        let gen = generation

        queue.async { [weak self] in
            guard let self else { return }
            let t0 = Date()

            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else {
                DispatchQueue.main.async { completion([], [], Stats()) }
                return
            }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                DispatchQueue.main.async { completion([], [], Stats()) }
                return
            }
            // **走査はこの瞬間の大きさまで**（追従中に伸びても数えない＝スナップショット）。
            let size = Int(st.st_size)
            let chunkCount = max(1, (size + Self.chunkSize - 1) / Self.chunkSize)

            var sinks = (0..<chunkCount).map { makeSink($0) }
            var lineCounts = [Int](repeating: 0, count: chunkCount)
            let pool = BufferPool(capacity: Self.chunkSize + Self.overlap)
            let tracker = ProgressTracker(total: size, report: progress)

            sinks.withUnsafeMutableBufferPointer { sinkBuf in
                lineCounts.withUnsafeMutableBufferPointer { lineBuf in
                    DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
                        guard self.generation == gen else { return }
                        let offset = c * Self.chunkSize
                        let want = min(Self.chunkSize + Self.overlap, size - offset)
                        guard want > 0 else { return }

                        let buf = pool.acquire()
                        defer { pool.release(buf) }
                        let got = Int(pread(fd, buf, want, off_t(offset)))
                        guard got > 0 else { return }

                        // 行を割らない:
                        //  - 先頭の欠けた行は**前のチャンクの担当**なので読み飛ばす
                        //  - 末尾の行は余分に読んだ 4KB を使って最後まで見る
                        var p = 0
                        if offset > 0 {
                            while p < got && buf[p] != 0x0A { p += 1 }
                            p = min(p + 1, got)
                        }
                        var end = min(got, max(0, min(Self.chunkSize, size - offset)))
                        if offset + end < size {
                            while end < got && buf[end] != 0x0A { end += 1 }
                        }

                        var sink = sinkBuf[c]
                        var localLine = 0
                        while p < end {
                            if localLine & 0xFFF == 0, self.generation != gen { break }
                            var e = p
                            while e < end && buf[e] != 0x0A { e += 1 }
                            // 末尾の CR を落とす（CRLF のファイルで値に \r が混じらないように）
                            var lineEnd = e
                            if lineEnd > p && buf[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                            consume(&sink, UnsafeBufferPointer(start: buf + p, count: lineEnd - p), localLine)
                            localLine += 1
                            p = e + 1
                        }
                        finishChunk(&sink)
                        sinkBuf[c] = sink
                        lineBuf[c] = localLine
                        tracker.add(end)
                    }
                }
            }

            let cancelled = self.generation != gen
            var stats = Stats()
            stats.bytes = size
            stats.lines = lineCounts.reduce(0, +)
            stats.elapsed = Date().timeIntervalSince(t0)
            stats.cancelled = cancelled
            let out = sinks
            let counts = lineCounts
            DispatchQueue.main.async {
                guard !cancelled else { return }     // 打ち切った走査の結果は捨てる
                completion(out, counts, stats)
            }
        }
    }

    /// **行を選びながら**走査する（ヘッダ行を除く／フィルタ中は一致行だけ）。
    ///
    /// C1 と C2（以降は C3 も）が同じ「何を対象にしたか」の規則を使うための口。
    /// ここを共有しないと、集計と列の統計で対象行がズレたときに**どちらが正しいのか
    /// 誰にも分からなくなる**。行番号の面倒（チャンク内の番号しか分からない）はここで閉じ、
    /// 呼ぶ側はバイト列だけを受け取る。
    ///
    /// `consume` の第 3 引数は**そのチャンクの中での行番号**（0 始まり）。全体の行番号が
    /// 要る機能（時間分布の範囲選択）は、`completion` で受け取るチャンクごとの行数の
    /// 前方累和を足して作る。合流の後なら順序は確定している。
    ///
    /// フィルタ中は**2 パス**になる（先に `lineCounts` で各チャンクの行数を求め、その前方
    /// 累和で「このチャンクの先頭は全体の何行目か」を知る）。2 回目はページキャッシュに
    /// 乗っているので、実測ほど高くはつかない。
    func scanLines<S>(url: URL,
                      filter: [Int]?,
                      skipsHeader: Bool,
                      makeSink: @escaping (Int) -> S,
                      consume: @escaping (inout S, UnsafeBufferPointer<UInt8>, Int) -> Void,
                      finishChunk: @escaping (inout S) -> Void = { _ in },
                      progress: @escaping (Double) -> Void,
                      completion: @escaping ([S], [Int], Stats) -> Void) {
        guard let filter else {
            scanScoped(url: url, filter: nil, prefix: nil, skipsHeader: skipsHeader,
                       makeSink: makeSink, consume: consume, finishChunk: finishChunk,
                       progress: progress, completion: completion)
            return
        }
        lineCounts(url: url) { [weak self] counts in
            guard let self else { return }
            var prefix = [Int](repeating: 0, count: counts.count)
            var running = 0
            for (i, n) in counts.enumerated() { prefix[i] = running; running += n }
            self.scanScoped(url: url, filter: filter, prefix: prefix, skipsHeader: skipsHeader,
                            makeSink: makeSink, consume: consume, finishChunk: finishChunk,
                            progress: progress, completion: completion)
        }
    }

    /// チャンクインデックスを必要としない呼び出し元向けの後方互換オーバーロード
    func scanLines<S>(url: URL,
                      filter: [Int]?,
                      skipsHeader: Bool,
                      makeSink: @escaping () -> S,
                      consume: @escaping (inout S, UnsafeBufferPointer<UInt8>, Int) -> Void,
                      finishChunk: @escaping (inout S) -> Void = { _ in },
                      progress: @escaping (Double) -> Void,
                      completion: @escaping ([S], [Int], Stats) -> Void) {
        scanLines(url: url, filter: filter, skipsHeader: skipsHeader,
                  makeSink: { _ in makeSink() },
                  consume: consume, finishChunk: finishChunk,
                  progress: progress, completion: completion)
    }

    private func scanScoped<S>(url: URL,
                               filter: [Int]?,
                               prefix: [Int]?,
                               skipsHeader: Bool,
                               makeSink: @escaping (Int) -> S,
                               consume: @escaping (inout S, UnsafeBufferPointer<UInt8>, Int) -> Void,
                               finishChunk: @escaping (inout S) -> Void,
                               progress: @escaping (Double) -> Void,
                               completion: @escaping ([S], [Int], Stats) -> Void) {
        scan(url: url,
             makeSink: { chunk -> Scoped<S> in
                 var scoped = Scoped(sink: makeSink(chunk))
                 if let filter, let prefix, chunk < prefix.count {
                     scoped.globalOffset = prefix[chunk]
                     scoped.filter = LineFilterCursor(lines: filter, from: prefix[chunk])
                 }
                 scoped.skipsFirstLineOfFile = skipsHeader && chunk == 0
                 return scoped
             },
             consume: { scoped, bytes, localLine in
                 if scoped.skipsFirstLineOfFile && localLine == 0 { return }
                 if scoped.filter != nil,
                    !scoped.filter!.contains(scoped.globalOffset + localLine) { return }
                 consume(&scoped.sink, bytes, localLine)
             },
             finishChunk: { scoped in finishChunk(&scoped.sink) },
             progress: progress,
             completion: { scoped, counts, stats in completion(scoped.map(\.sink), counts, stats) })
    }

    /// チャンクごとの行数だけを数える軽い走査（`\n` を数えるだけ）。
    ///
    /// **フィルタ中の分析でだけ使う。** 「一致行だけを数える」には全体の行番号が要るが、
    /// 並列走査の最中には分からないため、先にこれで各チャンクの行数を求めておく。
    /// 走査が 2 回になる（ただし 2 回目はページキャッシュに乗っているので実測ほど高くはつかない）。
    func lineCounts(url: URL, completion: @escaping ([Int]) -> Void) {
        scan(url: url,
             makeSink: { _ in 0 },
             consume: { (n: inout Int, _, _) in n += 1 },
             progress: { _ in },
             completion: { _, counts, _ in completion(counts) })
    }
}

/// `scanLines` がチャンクごとに持つ受け皿。呼ぶ側の受け皿に、行を選ぶための状態を被せる。
private struct Scoped<S> {
    var sink: S
    var globalOffset = 0
    var filter: LineFilterCursor?
    var skipsFirstLineOfFile = false
}

/// フィルタ中の一致行（昇順）を、そのチャンクの範囲だけ順に見ていく。
/// 行は必ず前から順に来るので、二分探索も集合も要らない（走査 1 行あたり定数時間）。
struct LineFilterCursor {
    private let lines: [Int]
    private var index: Int

    init(lines: [Int], from start: Int) {
        self.lines = lines
        // このチャンクの先頭行以降の最初の位置を二分探索で 1 回だけ求める。
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid] < start { lo = mid + 1 } else { hi = mid }
        }
        self.index = lo
    }

    mutating func contains(_ line: Int) -> Bool {
        while index < lines.count && lines[index] < line { index += 1 }
        guard index < lines.count, lines[index] == line else { return false }
        index += 1
        return true
    }
}

/// 16MB のバッファを使い回す。チャンクごとに確保し直すと、その確保だけで無視できない時間を食う。
private final class BufferPool {
    private var free: [UnsafeMutablePointer<UInt8>] = []
    private let lock = NSLock()
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    deinit {
        for b in free { b.deallocate() }
    }

    func acquire() -> UnsafeMutablePointer<UInt8> {
        lock.lock()
        let b = free.popLast()
        lock.unlock()
        return b ?? UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    func release(_ b: UnsafeMutablePointer<UInt8>) {
        lock.lock()
        free.append(b)
        lock.unlock()
    }
}

/// 進捗を 200ms に 1 回だけメインへ送る（毎チャンク送ると UI が詰まる）。
private final class ProgressTracker {
    private let total: Int
    private let report: (Double) -> Void
    private var done = 0
    private var lastReport = Date.distantPast
    private let lock = NSLock()

    init(total: Int, report: @escaping (Double) -> Void) {
        self.total = max(1, total)
        self.report = report
    }

    func add(_ bytes: Int) {
        lock.lock()
        done += bytes
        let now = Date()
        let should = now.timeIntervalSince(lastReport) > 0.2
        if should { lastReport = now }
        let ratio = Double(done) / Double(total)
        lock.unlock()
        if should {
            DispatchQueue.main.async { self.report(min(1.0, ratio)) }
        }
    }
}