import Foundation

/// C5「フォルダを横断して検索」。**探して、開いて、直す**まで一本にする。
///
/// ## rg との関係（正直に）
///
/// **速さでは売らない。** 実測で互角（自前 3.07 秒 / rg 3.30 秒・10GB リテラル 1 語）だが、
/// 複雑な正規表現は Rust の regex が `NSRegularExpression` より確実に速い。売るのは往復と
/// 対応範囲——①結果からその行へ飛べる ②Shift-JIS / EUC を判定して読む ③絞り込み・集計と
/// 同じペインで繋がる。**rg を同梱しない**のは、エンコーディング判定・キャンセル・進捗が
/// core と一体になるのと、同梱バイナリの署名・公証・更新追従を抱えないため。
///
/// ## 並列は二段
///
/// 小さいファイルが大量にある場合と、10GB が 1 本ある場合の両方が来る。
/// **小さいファイルはファイル並列**（`concurrentPerform`）、**大きいファイルはその中を
/// チャンク並列**（`ScanEngine`）にして、両方を入れ子にしない（入れ子にするとコア数の
/// 二乗ぶんのスレッドが立って、かえって遅くなる）。
final class CrossFileSearchRunner {

    /// 大ファイルとして扱う境目。これを超えたらファイル並列から外し、中をチャンク並列で読む。
    static let bigFileThreshold = 64 << 20
    /// 一致行の上限（core の `SearchEngine.lineCap` と同じ）。
    static let defaultCap = 1_000_000
    /// 先頭のこの範囲に NUL があればバイナリと見なす。
    static let binaryProbe = 8 << 10

    struct Options {
        var caseSensitive = false
        var regex = false
        /// 前後 N 行（`grep -A/-B` 相当）。既定 0。
        var context = 0
        /// `.gitignore` を尊重するか。**既定は見ない**（ログのフォルダは git 管理外が普通で、
        /// 尊重すると逆に取りこぼす）。rg と挙動が違う点なので画面にトグルを出す。
        var respectGitignore = false
        var cap = CrossFileSearchRunner.defaultCap
    }

    struct LineHit {
        /// 0 始まりの行番号。表示は +1。
        var line: Int
        var text: String
        /// 前後 N 行として付けた行（一致した行ではない）。
        var isContext: Bool
    }

    struct FileHit {
        var url: URL
        var encoding: DetectedEncoding
        /// 一致した行数（前後 N 行は数えない）。
        var matchCount: Int
        /// 表示する行（一致行＋前後 N 行・行番号の昇順）。
        var lines: [LineHit]
    }

    struct Summary {
        var files = 0
        var matchedFiles = 0
        var matchedLines = 0
        var skippedBinary = 0
        var capped = false
        var elapsed: TimeInterval = 0
        var cancelled = false
    }

    /// 世代カウンタ（`ScanEngine`・`SearchEngine` と同じ作法）。
    private var generation = 0
    private let queue = DispatchQueue(label: "MrEditor.crossSearch", qos: .userInitiated)
    private let engine = ScanEngine()

    func cancel() {
        generation += 1
        engine.cancel()
    }

    /// フォルダを横断して検索する。
    ///
    /// `onFile` は**見つかった順に**メインスレッドで呼ぶ（全部終わるまで待たせない）。
    func run(folders: [URL],
             query: String,
             options: Options = Options(),
             onFile: @escaping (FileHit) -> Void,
             progress: @escaping (Double) -> Void,
             completion: @escaping (Summary) -> Void) {
        generation += 1
        let gen = generation

        let mode: SearchMode
        if options.regex {
            guard let rx = try? NSRegularExpression(pattern: query,
                                                    options: options.caseSensitive ? [] : [.caseInsensitive]) else {
                completion(Summary())
                return
            }
            mode = .regex(rx)
        } else {
            let terms = SearchMode.splitTerms(query)
            guard !terms.isEmpty else { completion(Summary()); return }
            mode = .terms(terms)
        }

        queue.async { [weak self] in
            guard let self else { return }
            let t0 = Date()
            let ignore = options.respectGitignore ? GitignoreRules(folders: folders) : nil
            let files = Self.collectFiles(in: folders, ignore: ignore)
            guard self.generation == gen else { return }

            var summary = Summary()
            summary.files = files.count
            let budget = Budget(cap: options.cap)
            let sink = ResultSink(onFile: onFile)
            let done = Counter()

            // ① 小さいファイルはファイル並列。
            let small = files.filter { $0.size <= Self.bigFileThreshold }
            let big = files.filter { $0.size > Self.bigFileThreshold }
            if !small.isEmpty {
                DispatchQueue.concurrentPerform(iterations: small.count) { i in
                    guard self.generation == gen, !budget.isFull else { return }
                    let file = small[i]
                    if Self.isBinary(file.url) {
                        sink.countBinary()
                    } else if let hit = Self.searchSmallFile(file.url, mode: mode,
                                                             options: options, budget: budget) {
                        sink.emit(hit)
                    }
                    let n = done.increment()
                    if n % 32 == 0 {
                        let ratio = Double(n) / Double(max(1, files.count))
                        DispatchQueue.main.async { progress(ratio) }
                    }
                }
            }

            // ② 大きいファイルは 1 本ずつ、その中をチャンク並列で。
            for file in big {
                guard self.generation == gen, !budget.isFull else { break }
                if Self.isBinary(file.url) { sink.countBinary(); continue }
                if let hit = self.searchBigFile(file.url, mode: mode, options: options, budget: budget) {
                    sink.emit(hit)
                }
                let n = done.increment()
                let ratio = Double(n) / Double(max(1, files.count))
                DispatchQueue.main.async { progress(ratio) }
            }

            guard self.generation == gen else { return }
            summary.matchedFiles = sink.matchedFiles
            summary.matchedLines = sink.matchedLines
            summary.skippedBinary = sink.binaryFiles
            summary.capped = budget.isFull
            summary.elapsed = Date().timeIntervalSince(t0)
            let final = summary
            DispatchQueue.main.async { completion(final) }
        }
    }

    // MARK: - 対象のファイルを集める

    struct Target {
        let url: URL
        let size: Int
    }

    /// 走査するファイルを集める。**除外は既定で: 隠しフォルダ（`.git` を含む）・
    /// `node_modules`・シンボリックリンク**（辿るとループする）。
    static func collectFiles(in folders: [URL], ignore: GitignoreRules?) -> [Target] {
        var out: [Target] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]

        for folder in folders {
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory != true {
                if let target = target(for: folder, ignore: ignore), seen.insert(target.url.path).inserted {
                    out.append(target)
                }
                continue
            }
            guard let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }

            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true {
                    if values?.isDirectory == true { walker.skipDescendants() }
                    continue                                  // シンボリックリンクは辿らない
                }
                if values?.isDirectory == true {
                    if url.lastPathComponent == "node_modules" { walker.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                if let ignore, ignore.isIgnored(url) { continue }
                guard seen.insert(url.path).inserted else { continue }
                out.append(Target(url: url, size: values?.fileSize ?? 0))
            }
        }
        return out
    }

    private static func target(for url: URL, ignore: GitignoreRules?) -> Target? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        if let ignore, ignore.isIgnored(url) { return nil }
        return Target(url: url, size: values.fileSize ?? 0)
    }

    /// 先頭 8KB に NUL があればバイナリ。**中身を見て決める**（拡張子では決めない）。
    static func isBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: binaryProbe)) ?? Data()
        return head.contains(0)
    }

    // MARK: - 1 本を検索する

    /// 小さいファイル。丸ごと読んで行に切る（**エンコーディングはファイルごとに判定**）。
    static func searchSmallFile(_ url: URL,
                                mode: SearchMode,
                                options: Options,
                                budget: Budget) -> FileHit? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if data.prefix(binaryProbe).contains(0) { return nil }
        let encoding = EncodingDetector.detect(data.prefix(64 << 10))
        let text = String(data: data, encoding: encoding.stringEncoding)
            ?? String(decoding: data, as: UTF8.self)
        let matcher = LineMatcher(mode: mode, caseSensitive: options.caseSensitive, encoding: encoding)

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }      // 末尾改行の余り（幻の空行を作らない）
        var hits: [Int] = []
        for (i, line) in lines.enumerated() where matcher.matches(line) {
            guard budget.take() else { break }
            hits.append(i)
        }
        guard !hits.isEmpty else { return nil }
        return FileHit(url: url, encoding: encoding, matchCount: hits.count,
                       lines: withContext(hits, in: lines, context: options.context))
    }

    /// 大きいファイル。`ScanEngine`（pread ＋ チャンク並列）で読む。
    ///
    /// 前後 N 行は**チャンクを跨いでも正しく出す**: 各チャンクが自分の先頭 N 行と末尾 N 行を
    /// 覚えておき、合流のときに隣のチャンクから足りない行を補う。ここを手抜きすると
    /// 「チャンクの境目にある一致だけ前の行が出ない」という、まず気づけない穴になる。
    private func searchBigFile(_ url: URL,
                               mode: SearchMode,
                               options: Options,
                               budget: Budget) -> FileHit? {
        let encoding = Self.detectEncoding(of: url)
        let matcher = LineMatcher(mode: mode, caseSensitive: options.caseSensitive, encoding: encoding)
        let context = options.context

        let group = DispatchGroup()
        group.enter()
        var chunks: [ChunkHits] = []
        var counts: [Int] = []
        engine.scanLines(
            url: url,
            filter: nil,
            skipsHeader: false,
            makeSink: { ChunkHits(context: context) },
            consume: { hits, bytes, localLine in
                hits.observe(bytes, line: localLine)
                guard matcher.matches(bytes) else { return }
                guard budget.take() else { hits.stopped = true; return }
                hits.add(line: localLine, bytes: bytes, encoding: encoding)
            },
            progress: { _ in },
            completion: { sinks, lineCounts, _ in
                chunks = sinks
                counts = lineCounts
                group.leave()
            })
        group.wait()
        guard !chunks.isEmpty else { return nil }

        var offsets = [Int](repeating: 0, count: counts.count)
        var running = 0
        for (i, n) in counts.enumerated() { offsets[i] = running; running += n }

        // 一致行と前後 N 行を**全体の行番号**へ直して合流する。
        // チャンクの端（先頭 N 行・末尾 N 行）は隣のチャンクから補う——ここを手抜きすると
        // 「チャンクの境目にある一致だけ前の行が出ない」という、まず気づけない穴になる。
        var matched: [Int: String] = [:]
        var contextLines = [Int: String]()
        for (index, chunk) in chunks.enumerated() where index < offsets.count {
            let base = offsets[index]
            for hit in chunk.matches { matched[base + hit.line] = hit.text }
            for (line, text) in chunk.contextLines { contextLines[base + line] = text }
            guard options.context > 0, !chunk.matches.isEmpty else { continue }

            if index > 0, let first = chunk.matches.map(\.line).min(), first < options.context {
                let need = options.context - first
                let previous = chunks[index - 1]
                let previousBase = offsets[index - 1]
                for entry in previous.tail.suffix(need) {
                    contextLines[previousBase + entry.line] = entry.text
                }
            }
            if index + 1 < chunks.count, let last = chunk.matches.map(\.line).max() {
                let remaining = options.context - (counts[index] - 1 - last)
                if remaining > 0 {
                    let next = chunks[index + 1]
                    let nextBase = offsets[index + 1]
                    for entry in next.head.prefix(remaining) {
                        contextLines[nextBase + entry.line] = entry.text
                    }
                }
            }
        }
        guard !matched.isEmpty else { return nil }

        var lines = matched.map { LineHit(line: $0.key, text: $0.value, isContext: false) }
        for (line, text) in contextLines where matched[line] == nil {
            lines.append(LineHit(line: line, text: text, isContext: true))
        }
        lines.sort { $0.line < $1.line }
        return FileHit(url: url, encoding: encoding, matchCount: matched.count, lines: lines)
    }

    static func detectEncoding(of url: URL) -> DetectedEncoding {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .utf8 }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 << 10)) ?? Data()
        return EncodingDetector.detect(head)
    }

    /// 一致行に前後 N 行を足す（重なった分はまとめる）。
    static func withContext(_ hits: [Int], in lines: [String], context: Int) -> [LineHit] {
        guard context > 0 else {
            return hits.map { LineHit(line: $0, text: lines[$0], isContext: false) }
        }
        var wanted: [Int: Bool] = [:]                 // 行番号 → 一致行か
        for hit in hits {
            wanted[hit] = true
            for offset in 1...context {
                for line in [hit - offset, hit + offset] where line >= 0 && line < lines.count {
                    if wanted[line] == nil { wanted[line] = false }
                }
            }
        }
        return wanted.keys.sorted().map {
            LineHit(line: $0, text: lines[$0], isContext: !(wanted[$0] ?? false))
        }
    }

    // MARK: - 受け皿

    /// チャンクごとの一致行。前後 N 行のために、**自分の先頭 N 行と直近 N 行**も覚えておく
    /// （チャンクの端で足りない文脈を、合流のときに隣から補うため）。
    final class ChunkHits {
        let context: Int
        var matches: [(line: Int, text: String)] = []
        /// 自分のチャンクの中で拾った前後の行（チャンク内の行番号）。
        var contextLines: [Int: String] = [:]
        /// このチャンクの先頭 N 行。
        private(set) var head: [(line: Int, text: String)] = []
        /// 直近 N 行（末尾 N 行が残る）。
        private(set) var tail: [(line: Int, text: String)] = []
        var stopped = false
        /// 一致行の後ろにあと何行足すか。
        private var after = 0

        init(context: Int) { self.context = context }

        /// **すべての行**を通す（前後 N 行のため）。一致判定より前に呼ぶ。
        func observe(_ bytes: UnsafeBufferPointer<UInt8>, line: Int) {
            guard context > 0 else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            if head.count < context { head.append((line, text)) }
            if after > 0 {
                contextLines[line] = text
                after -= 1
            }
            // **自分の行も入る**ので context+1 本まで持つ（context 本だと、一致行の
            // 直前の 1 行しか残らず、前の N 行が 1 行足りなくなる）。
            tail.append((line, text))
            if tail.count > context + 1 { tail.removeFirst() }
        }

        func add(line: Int, bytes: UnsafeBufferPointer<UInt8>, encoding: DetectedEncoding) {
            let text: String
            if encoding == .utf8 {
                text = String(decoding: bytes, as: UTF8.self)
            } else {
                text = String(data: Data(buffer: bytes), encoding: encoding.stringEncoding)
                    ?? String(decoding: bytes, as: UTF8.self)
            }
            matches.append((line, text))
            guard context > 0 else { return }
            for entry in tail where entry.line < line { contextLines[entry.line] = entry.text }
            after = context
        }
    }

    /// 一致行の上限を全体で見る箱。
    final class Budget {
        private let lock = NSLock()
        private let cap: Int
        private var used = 0

        init(cap: Int) { self.cap = cap }

        /// 1 行ぶん取る。上限に達していたら false（呼ぶ側は打ち切る）。
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard used < cap else { return false }
            used += 1
            return true
        }

        var isFull: Bool {
            lock.lock()
            defer { lock.unlock() }
            return used >= cap
        }
    }

    /// 見つかった順にメインへ流す箱。
    private final class ResultSink {
        private let lock = NSLock()
        private let onFile: (FileHit) -> Void
        private(set) var matchedFiles = 0
        private(set) var matchedLines = 0
        private(set) var binaryFiles = 0

        init(onFile: @escaping (FileHit) -> Void) { self.onFile = onFile }

        func emit(_ hit: FileHit) {
            lock.lock()
            matchedFiles += 1
            matchedLines += hit.matchCount
            lock.unlock()
            DispatchQueue.main.async { self.onFile(hit) }
        }

        func countBinary() {
            lock.lock(); binaryFiles += 1; lock.unlock()
        }
    }

    private final class Counter {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

/// `.gitignore` の規則（**既定では使わない**）。
///
/// 完全な gitignore の実装はしない（否定規則・`**` の全パターン・親を辿る解決まで入れると
/// それだけで一機能になる）。ここでは**フォルダ直下の `.gitignore` の素直な行**だけを見て、
/// 何を見ているかを画面のトグルではっきりさせる。
final class GitignoreRules {
    private var patterns: [(root: String, pattern: String)] = []

    init(folders: [URL]) {
        for folder in folders {
            // **パスは解決してから持つ。** `/var/folders/…` と `/private/var/folders/…` の
            // ように、同じ場所が別の綴りで来る（列挙が返す URL と、こちらが組み立てた URL で
            // 綴りが違い、前方一致に失敗して .gitignore が丸ごと効かなかった）。
            let root = folder.resolvingSymlinksInPath().path
            let file = folder.appendingPathComponent(".gitignore")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
                patterns.append((root, line.hasSuffix("/") ? String(line.dropLast()) : line))
            }
        }
    }

    func isIgnored(_ url: URL) -> Bool {
        guard !patterns.isEmpty else { return false }
        let path = url.resolvingSymlinksInPath().path
        for (root, pattern) in patterns {
            guard path.hasPrefix(root) else { continue }
            let relative = String(path.dropFirst(root.count).drop(while: { $0 == "/" }))
            let components = relative.components(separatedBy: "/")
            if components.contains(where: { matches(pattern: pattern, name: $0) }) { return true }
        }
        return false
    }

    private func matches(pattern: String, name: String) -> Bool {
        if pattern.contains("*") {
            return fnmatch(pattern, name, 0) == 0
        }
        return pattern == name
    }
}