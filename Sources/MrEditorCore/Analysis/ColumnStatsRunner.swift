import Foundation

/// C2「列の統計」。**全部の列を 1 パスで**見る。
///
/// 列を選ばせてから数える作りにすると、「どの列を見ればいいか分からない」人の役に立たない。
/// 開いた CSV について、まず**全列の輪郭**（型・空欄・ユニーク数・最小最大・代表値）を出し、
/// 気になった行をダブルクリックしたら C1 で中身を見る、という順番にする。
final class ColumnStatsRunner {

    /// 列ごとの異なる値の上限（仕様 §3.3）。31 列 × 10 万で **RSS 2.9GB** になった実測が
    /// あるので、数える器は必ず `ShardedCounter`（値のハッシュで振り分け）を使う。
    static let defaultUniqueCap = 100_000

    /// 列の型。**勝手に決めない**ための 5 値（仕様 §3.2）。
    enum Kind: Equatable {
        /// 全行が数として読めた。
        case number
        /// 全行が同じ形式の日時として読めた。
        case datetime
        /// 数と数でないものが混ざっている。**合計は出さない。**
        case mixed
        case text
        /// 値のある行が 1 つも無い（空の列）。
        case empty
    }

    /// 合計。桁あふれを黙って握りつぶさないため、値そのものを持たない場合を型で持つ。
    enum Sum: Equatable {
        case integer(Int)
        case real(Double)
        /// Int の桁を越えた（IDのような列を足したとき）。**近い数を出すより出さない。**
        case overflow
    }

    struct ColumnStat {
        var index: Int
        var name: String
        var kind: Kind = .empty
        /// 値のあった行（空欄・欄そのものが無い行を除く）。
        var present = 0
        /// 空の値だった行。**0 でも列は出す。**
        var blank = 0
        /// その行に欄が無かった（列数より短い行）。
        var missing = 0
        /// 異なる値の数（空欄は数えない）。
        var distinct = 0
        /// 上限に達して打ち切ったか。`100,000+` と出すための印。
        var distinctTruncated = false
        var minText: String?
        var maxText: String?
        var sum: Sum?
        var average: Double?
        /// 型の内訳（`混在` のときに「数値 N / それ以外 M」と出す）。
        var numeric = 0
        var nonNumeric = 0
        /// 上位 3 件。
        var top: [(value: String, count: Int)] = []
    }

    struct Result {
        var columns: [ColumnStat] = []
        /// 走査した行数（ヘッダを除く。フィルタ中はその対象行数）。
        var scannedLines = 0
        var elapsed: TimeInterval = 0
        /// データの「嘘発見器」が検出した異常行一覧（列数不一致、型混入など）。
        var sanityIssues: [SanityIssue] = []
    }

    private let engine = ScanEngine()
    private var cancelled = false

    func cancel() {
        cancelled = true
        engine.cancel()
    }

    /// 列の統計を出す。`completion` はメインスレッド。打ち切られた場合は呼ばれない。
    ///
    /// 列は `document.columnNames`（＝画面に出ている列）で決める。構造化表示していない
    /// ファイルには列が無いので、呼ぶ側が先に弾くこと（空の結果を返す）。
    func run(document: ActiveDocument,
             cap: Int = ColumnStatsRunner.defaultUniqueCap,
             progress: @escaping (Double) -> Void,
             completion: @escaping (Result) -> Void) {
        cancelled = false
        let names = document.columnNames
        guard !names.isEmpty, let structured = document.structuredMode else {
            completion(Result())
            return
        }
        // 表示順(names)で j 番目の列が、生のどのセル位置を指すか（並べ替え・B19対応）。
        // 個数が食い違う（想定外）ときは恒等に倒す ── 列がズレるより「並べ替え前扱い」の方が安全。
        let originalIndices = document.columnOriginalIndices.count == names.count
            ? document.columnOriginalIndices : Array(names.indices)

        let expectedColumns: Int
        if structured == .csv || structured == .tsv {
            if let first = Self.readFirstLine(document: document) {
                let sep: Character = structured == .csv ? "," : "\t"
                let headerCols = TabularFormatter.splitDelimited(first, sep: sep, csvQuotes: structured == .csv).count
                expectedColumns = max(1, headerCols)
            } else {
                let namedCols = names.filter { !$0.isEmpty }.count
                expectedColumns = namedCols > 0 ? namedCols : names.count
            }
        } else {
            expectedColumns = names.count
        }

        let plan = Plan(columns: names,
                        originalIndices: originalIndices,
                        structured: structured,
                        expectedColumns: expectedColumns,
                        // 日時かどうかは**列ごとに、先頭のサンプルで 1 回だけ**決める。
                        detectors: Self.detectTimestamps(document: document, columns: names,
                                                         originalIndices: originalIndices,
                                                         structured: structured),
                        cap: cap,
                        options: ValueExtractor.Options())

        if let text = document.text {
            runOverText(text, document: document, plan: plan, completion: completion)
            return
        }
        guard let url = document.fileURL else {
            completion(Result())
            return
        }
        scanFile(url: url, document: document, plan: plan, progress: progress, completion: completion)
    }

    // MARK: - 走る前に決めておくこと

    /// 走査の前に 1 回だけ作る。**行ごとにやり直さない**（C1 で 10GB が 40 秒になった罠と同じ）。
    fileprivate struct Plan {
        let columns: [String]
        /// `columns` と同じ並びで、各列が元々どの生セル位置を指すか（B19の並べ替え対応）。
        let originalIndices: [Int]
        let structured: StructuredMode
        let expectedColumns: Int
        let detectors: [TimestampDetector?]
        let cap: Int
        let options: ValueExtractor.Options

        var count: Int { columns.count }
        var separator: UInt8 { structured == .tsv ? 0x09 : UInt8(ascii: ",") }
        var quoted: Bool { structured == .csv }
        /// バイト列のまま欄に切れるか（NDJSON は 1 行ごとに JSON を解く）。
        var byteCapable: Bool { structured == .csv || structured == .tsv }

        /// 生セル位置 → 表示スロット(`columns`のindex)。`consumeBytes`(byte経路)が使う
        /// ── そちらは生セルを位置順に流ってくるので、逆引きが要る。
        var rawToDisplaySlot: [Int] {
            var map = [Int](repeating: -1, count: count)
            for (slot, raw) in originalIndices.enumerated() where raw < count { map[raw] = slot }
            return map
        }
    }

    /// 列ごとに時刻形式を判定する。**エポック（数字だけ）の形式は日時と見なさない。**
    ///
    /// `TimestampDetector` はエポックに「3 件以上＋ほぼ単調増加」という条件を課しているが、
    /// **並べ替え済みの ID 列はこの条件を通ってしまう**（国税庁の法人番号 CSV の 13 桁の
    /// 法人番号は昇順に並んでいて、13 桁＝エポックミリ秒に見える）。列の型として
    /// 「日時」と言い切るには弱いので、C2 では日付の形をしている 3 形式だけを日時とし、
    /// 数字だけの列は**数値**として扱う（最小・最大は数として出るので順序は正しい）。
    private static func detectTimestamps(document: ActiveDocument,
                                         columns: [String],
                                         originalIndices: [Int],
                                         structured: StructuredMode) -> [TimestampDetector?] {
        let lines = sampleLines(document: document, structured: structured)
        guard !lines.isEmpty else { return Array(repeating: nil, count: columns.count) }

        var perColumn = [[String]](repeating: [], count: columns.count)
        for line in lines {
            let cells = self.cells(of: line, columns: columns, originalIndices: originalIndices, structured: structured)
            for (j, cell) in cells.enumerated() where j < columns.count {
                if !cell.isEmpty { perColumn[j].append(cell) }
            }
        }
        return perColumn.map { values in
            guard values.count >= 3,
                  let d = TimestampDetector.detect(sampleLines: values, minimumHits: 3),
                  d.format != .epochSeconds, d.format != .epochMillis else { return nil }
            // サンプルが全部読めたときだけ候補にする（半分だけ日付の列は `混在` の側）。
            return values.allSatisfy { d.parse($0) != nil } ? d : nil
        }
    }

    /// ドキュメントの先頭行（ヘッダ行）をそのまま読む。
    private static func readFirstLine(document: ActiveDocument, limitBytes: Int = 16384) -> String? {
        if let text = document.text {
            return text.components(separatedBy: "\n").first
        }
        guard let url = document.fileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limitBytes) else { return nil }
        let sample = String(data: data, encoding: document.encoding.stringEncoding)
            ?? String(decoding: data, as: UTF8.self)
        return sample.components(separatedBy: "\n").first
    }

    /// 先頭のほうを 1000 行だけ読む。**候補を出すために全体を読む理由はない。**
    private static func sampleLines(document: ActiveDocument,
                                    structured: StructuredMode,
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
        if lines.count > 1 { lines.removeLast() }      // 最後の 1 行は途中で切れている
        if structured == .csv || structured == .tsv, !lines.isEmpty { lines.removeFirst() }
        return Array(lines.prefix(limitLines))
    }

    /// **返す順序は `columns`(表示順)。** csv/tsv は生セルを割ると常にファイル順になるので、
    /// `originalIndices` で表示スロットへ引き直す(並べ替え・B19対応。core の
    /// `TabularFormatter.cells(of:)` と同じ理由・同じ形)。
    private static func cells(of line: String, columns: [String], originalIndices: [Int],
                              structured: StructuredMode) -> [String] {
        switch structured {
        case .csv, .tsv:
            let raw = TabularFormatter.splitDelimited(line,
                                                      sep: structured == .csv ? "," : "\t",
                                                      csvQuotes: structured == .csv)
            return originalIndices.map { $0 < raw.count ? raw[$0] : "" }
        case .ndjson:
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }
            return columns.map { key in
                guard let v = obj[key], !(v is NSNull) else { return "" }
                if let s = v as? String { return s }
                if let n = v as? NSNumber { return n.stringValue }
                return String(describing: v)
            }
        case .json:
            return []
        case .fixedWidth:
            // 桁の定義を受け取っていない。**呼ぶ側（ColumnStatsView）が先に弾く。**
            return []
        }
    }

    // MARK: - 大ファイル（pread 経路）

    private func scanFile(url: URL,
                          document: ActiveDocument,
                          plan: Plan,
                          progress: @escaping (Double) -> Void,
                          completion: @escaping (Result) -> Void) {
        let counters = (0..<plan.count).map { _ in ShardedCounter(cap: plan.cap) }
        let merged = MergedAccumulators(count: plan.count)
        let isUTF8 = document.encoding == .utf8
        let encoding = document.encoding.stringEncoding
        let skipsHeader = plan.structured == .csv || plan.structured == .tsv
        let t0 = Date()

        engine.scanLines(
            url: url,
            filter: document.filterMatchLines,
            skipsHeader: skipsHeader,
            makeSink: { chunk in Sink(chunkIndex: chunk, plan: plan, counters: counters, merged: merged) },
            consume: { sink, bytes, localLine in
                if isUTF8 && plan.byteCapable {
                    sink.consumeBytes(bytes, localLine: localLine)
                } else {
                    // 非 UTF-8 はバイトのまま切れない（SJIS の 2 バイト目に区切りと同じ値が出る）。
                    let line = String(data: Data(buffer: bytes), encoding: encoding)
                        ?? String(decoding: bytes, as: UTF8.self)
                    sink.consumeString(line, localLine: localLine)
                }
            },
            finishChunk: { sink in sink.flush() },
            progress: progress,
            completion: { [weak self] _, counts, _ in
                guard let self, !self.cancelled else { return }
                completion(merged.result(plan: plan, counters: counters, counts: counts, skipsHeader: skipsHeader,
                                         elapsed: Date().timeIntervalSince(t0)))
            })
    }

    // MARK: - 小ファイル（本文が手元にある経路）

    private func runOverText(_ text: String,
                             document: ActiveDocument,
                             plan: Plan,
                             completion: @escaping (Result) -> Void) {
        let counters = (0..<plan.count).map { _ in ShardedCounter(cap: plan.cap) }
        let merged = MergedAccumulators(count: plan.count)
        let filter = document.filterMatchLines.map { Set($0) }
        let skipsHeader = plan.structured == .csv || plan.structured == .tsv

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = Date()
            let sink = Sink(chunkIndex: 0, plan: plan, counters: counters, merged: merged)
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }     // 末尾改行の余り（幻の空行を作らない）
            for (i, line) in lines.enumerated() {
                if skipsHeader && i == 0 { continue }
                if let filter, !filter.contains(i) { continue }
                sink.consumeString(line, localLine: i)
            }
            sink.flush()
            let result = merged.result(plan: plan, counters: counters, counts: [lines.count], skipsHeader: skipsHeader,
                                       elapsed: Date().timeIntervalSince(t0))
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                completion(result)
            }
        }
    }

    // MARK: - データの「嘘発見器」の生レコード

    struct RawSanityIssue {
        let chunkIndex: Int
        let localLine: Int
        let kind: SanityIssue.Kind
        let columnIndex: Int?
        let expected: String
        let actual: String
        let preview: String
    }

    // MARK: - チャンクごとの受け皿

    /// チャンク内では**ロックを取らずに**溜め、チャンクの終わりに 1 回だけ共有の器へ流す。
    ///
    /// struct ではなく class なのは、1 行を切りながら（＝クロージャの中から）自分の
    /// 集計を書き換えるため。struct だと `self` への重なった書き込みになる。
    private final class Sink {
        /// ローカルに溜める異なる値の上限（全列の合計）。超えたら流す。
        static let localCap = 20_000
        /// 1 チャンクで集める異常行の最大数。
        static let maxRawIssuesPerSink = 200

        let chunkIndex: Int
        let plan: Plan
        let counters: [ShardedCounter]
        let merged: MergedAccumulators
        var accs: [Accumulator]
        var localEntries = 0
        var lines = 0
        /// 生セル位置 → 表示スロット。チャンクごとに 1 回だけ作る（行ごとに作り直さない）。
        let rawToDisplaySlot: [Int]
        /// この行でどの表示スロットへ値が来たか（`missing` 判定の使い回しスクラッチ）。
        var seenSlots: [Bool]
        var rawIssues: [RawSanityIssue] = []

        init(chunkIndex: Int = 0, plan: Plan, counters: [ShardedCounter], merged: MergedAccumulators) {
            self.chunkIndex = chunkIndex
            self.plan = plan
            self.counters = counters
            self.merged = merged
            self.accs = (0..<plan.count).map { Accumulator(detector: plan.detectors[$0]) }
            self.rawToDisplaySlot = plan.rawToDisplaySlot
            self.seenSlots = [Bool](repeating: false, count: plan.count)
        }

        /// UTF-8 の CSV/TSV。**これが本線**（1 行を 1 回だけ走る）。
        ///
        /// 生セルは常にファイル順で来るので、`rawToDisplaySlot` で表示スロットへ引き直す
        /// （並べ替え・B19対応。これをせず生位置のまま `add(text, to: j)` すると、並べ替え後は
        /// 列名と値がズレる ── 実機で踏んだ core 側と同じ罠、2026-09-25）。
        func consumeBytes(_ line: UnsafeBufferPointer<UInt8>, localLine: Int) {
            lines += 1
            for i in 0..<seenSlots.count { seenSlots[i] = false }
            let fieldCount = CSVRowScanner.forEachField(in: line, separator: plan.separator,
                                                        quoted: plan.quoted, limit: plan.count) { j, range in
                guard j < rawToDisplaySlot.count, rawToDisplaySlot[j] >= 0 else { return }
                let slot = rawToDisplaySlot[j]
                seenSlots[slot] = true
                let text = CSVFieldScanner.decode(line, range: trimmed(line, range), unquote: plan.quoted)
                add(text, to: slot, chunkIndex: chunkIndex, localLine: localLine)
            }
            if fieldCount != plan.expectedColumns, rawIssues.count < Self.maxRawIssuesPerSink {
                let previewLen = min(line.count, 60)
                let preview = line.baseAddress != nil
                    ? String(decoding: UnsafeBufferPointer(start: line.baseAddress, count: previewLen), as: UTF8.self)
                    : ""
                rawIssues.append(RawSanityIssue(chunkIndex: chunkIndex,
                                                localLine: localLine,
                                                kind: .columnMismatch,
                                                columnIndex: nil,
                                                expected: "\(plan.expectedColumns)",
                                                actual: "\(fieldCount)",
                                                preview: preview))
            }
            for slot in 0..<plan.count where !seenSlots[slot] { accs[slot].missing += 1 }
        }

        /// 非 UTF-8 の行・小ファイルの本文・NDJSON。
        func consumeString(_ line: String, localLine: Int) {
            lines += 1
            if plan.structured == .csv || plan.structured == .tsv {
                let sep: Character = plan.structured == .csv ? "," : "\t"
                let rawCount = TabularFormatter.splitDelimited(line, sep: sep, csvQuotes: plan.structured == .csv).count
                if rawCount != plan.expectedColumns, rawIssues.count < Self.maxRawIssuesPerSink {
                    rawIssues.append(RawSanityIssue(chunkIndex: chunkIndex,
                                                    localLine: localLine,
                                                    kind: .columnMismatch,
                                                    columnIndex: nil,
                                                    expected: "\(plan.expectedColumns)",
                                                    actual: "\(rawCount)",
                                                    preview: String(line.prefix(60))))
                }
            }
            let cells = ColumnStatsRunner.cells(of: line, columns: plan.columns,
                                                originalIndices: plan.originalIndices, structured: plan.structured)
            for j in 0..<plan.count {
                if j < cells.count {
                    add(cells[j].trimmingCharacters(in: .whitespaces), to: j, chunkIndex: chunkIndex, localLine: localLine)
                } else {
                    accs[j].missing += 1
                }
            }
        }

        private func trimmed(_ line: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Range<Int> {
            var lo = range.lowerBound
            var hi = range.upperBound
            while lo < hi, line[lo] == 0x20 || line[lo] == 0x09 { lo += 1 }
            while hi > lo, line[hi - 1] == 0x20 || line[hi - 1] == 0x09 { hi -= 1 }
            return lo..<hi
        }

        private func add(_ text: String, to column: Int, chunkIndex: Int, localLine: Int) {
            guard !text.isEmpty else {
                accs[column].blank += 1
                return
            }
            accs[column].observe(text, chunkIndex: chunkIndex, localLine: localLine)
            let before = accs[column].local.count
            accs[column].local[text, default: 0] += 1
            if accs[column].local.count != before {
                localEntries += 1
                if localEntries >= Self.localCap { flushLocals() }
            }
        }

        /// チャンクの終わりに呼ぶ。**ここで流さないと、溜めた辞書がチャンク数ぶん残る。**
        func flush() {
            flushLocals()
            merged.merge(accs, lines: lines, issues: rawIssues)
            lines = 0
            rawIssues.removeAll(keepingCapacity: true)
            for j in 0..<accs.count { accs[j] = Accumulator(detector: plan.detectors[j]) }
        }

        private func flushLocals() {
            for j in 0..<accs.count {
                counters[j].add(contentsOf: accs[j].local)
                accs[j].local.removeAll(keepingCapacity: true)
            }
            localEntries = 0
        }
    }

    /// 1 列ぶんの数え上げ。**値そのものは持たない**（中央値とパーセンタイルが v1 に無いのは
    /// 全値を持たないためで、持たないのは 8,642 万行を通すため）。
    struct Accumulator {
        var present = 0
        var blank = 0
        var missing = 0
        var numeric = 0
        var nonNumeric = 0
        /// 型混入の検出用サンプル（最大10件）
        var nonNumericSamples: [(chunkIndex: Int, localLine: Int, text: String)] = []

        /// 整数だけで来ている間の合計。桁あふれたら諦める（近い数を出さない）。
        var intSum = 0
        var intOverflow = false
        var hasReal = false
        var realSum = 0.0

        var minNumber: Double?
        var maxNumber: Double?
        /// 最小・最大は**元の文字列のまま**出す（`1000012160153` を丸めた数で見せない）。
        var minNumberText = ""
        var maxNumberText = ""

        var minText: String?
        var maxText: String?

        var detector: TimestampDetector?
        var dateOK = 0
        var dateNG = 0
        var minDate: Date?
        var maxDate: Date?
        var minDateText = ""
        var maxDateText = ""

        var local: [String: Int] = [:]

        init(detector: TimestampDetector? = nil) {
            self.detector = detector
            local.reserveCapacity(256)
        }

        mutating func observe(_ text: String, chunkIndex: Int = 0, localLine: Int = 0) {
            present += 1

            if let n = NumericField.parse(text) {
                numeric += 1
                switch n {
                case .integer(let v):
                    let (sum, overflow) = intSum.addingReportingOverflow(v)
                    if overflow { intOverflow = true } else { intSum = sum }
                    realSum += Double(v)
                case .real(let d):
                    hasReal = true
                    realSum += d
                }
                let d = n.double
                if minNumber == nil || d < minNumber! { minNumber = d; minNumberText = text }
                if maxNumber == nil || d > maxNumber! { maxNumber = d; maxNumberText = text }
            } else {
                nonNumeric += 1
                if nonNumericSamples.count < 10 {
                    nonNumericSamples.append((chunkIndex: chunkIndex, localLine: localLine, text: text))
                }
            }

            if let detector {
                if let date = detector.parse(text) {
                    dateOK += 1
                    if minDate == nil || date < minDate! { minDate = date; minDateText = text }
                    if maxDate == nil || date > maxDate! { maxDate = date; maxDateText = text }
                } else {
                    dateNG += 1
                }
            }

            if minText == nil || text < minText! { minText = text }
            if maxText == nil || text > maxText! { maxText = text }
        }

        mutating func absorb(_ other: Accumulator) {
            present += other.present
            blank += other.blank
            missing += other.missing
            numeric += other.numeric
            nonNumeric += other.nonNumeric
            if nonNumericSamples.count < 20 {
                nonNumericSamples.append(contentsOf: other.nonNumericSamples.prefix(20 - nonNumericSamples.count))
            }

            let (sum, overflow) = intSum.addingReportingOverflow(other.intSum)
            if overflow || other.intOverflow { intOverflow = true } else { intSum = sum }
            hasReal = hasReal || other.hasReal
            realSum += other.realSum

            if let m = other.minNumber, minNumber == nil || m < minNumber! {
                minNumber = m; minNumberText = other.minNumberText
            }
            if let m = other.maxNumber, maxNumber == nil || m > maxNumber! {
                maxNumber = m; maxNumberText = other.maxNumberText
            }
            if let t = other.minText, minText == nil || t < minText! { minText = t }
            if let t = other.maxText, maxText == nil || t > maxText! { maxText = t }

            dateOK += other.dateOK
            dateNG += other.dateNG
            if let d = other.minDate, minDate == nil || d < minDate! {
                minDate = d; minDateText = other.minDateText
            }
            if let d = other.maxDate, maxDate == nil || d > maxDate! {
                maxDate = d; maxDateText = other.maxDateText
            }
        }

        /// 型を決める（仕様 §3.2）。**閾値は使わない。**
        var kind: Kind {
            guard present > 0 else { return .empty }
            if detector != nil, dateNG == 0, dateOK == present { return .datetime }
            if nonNumeric == 0 { return .number }
            if numeric > 0 { return .mixed }
            return .text
        }
    }

    /// 全チャンクぶんを 1 つに合わせる箱（チャンクの終わりに 1 回だけ触る）。
    final class MergedAccumulators {
        private let lock = NSLock()
        private var accs: [Accumulator]
        private var lines = 0
        private var rawIssues: [RawSanityIssue] = []

        init(count: Int) {
            accs = (0..<count).map { _ in Accumulator() }
        }

        func merge(_ others: [Accumulator], lines: Int, issues: [RawSanityIssue] = []) {
            lock.lock()
            self.lines += lines
            for (j, other) in others.enumerated() where j < accs.count {
                // 判定器は列ごとに固定なので、合流のときに引き継ぐ。
                if accs[j].detector == nil { accs[j].detector = other.detector }
                accs[j].absorb(other)
            }
            if rawIssues.count < 1000 {
                rawIssues.append(contentsOf: issues.prefix(1000 - rawIssues.count))
            }
            lock.unlock()
        }

        fileprivate func result(plan: Plan,
                                counters: [ShardedCounter],
                                counts: [Int] = [],
                                skipsHeader: Bool = true,
                                elapsed: TimeInterval) -> Result {
            lock.lock()
            let snapshot = accs
            let scanned = lines
            let issuesSnapshot = rawIssues
            lock.unlock()

            // チャンクごとの累積行数を計算
            var cumulative = [0]
            for c in counts { cumulative.append(cumulative.last! + c) }

            var resolvedIssues: [SanityIssue] = []

            // 1. 列数不一致の解決
            for raw in issuesSnapshot {
                let chunkStart = raw.chunkIndex < cumulative.count ? cumulative[raw.chunkIndex] : 0
                let fileLine = chunkStart + raw.localLine + 1
                resolvedIssues.append(SanityIssue(
                    line: fileLine,
                    kind: raw.kind,
                    columnIndex: raw.columnIndex,
                    columnName: raw.columnIndex.map { plan.columns[$0] },
                    expected: "\(raw.expected) 列",
                    actual: "\(raw.actual) 列",
                    preview: raw.preview
                ))
            }

            // 2. 型混入（本来数値列なのに一部文字列がある列）のサンプリング
            for (j, acc) in snapshot.enumerated() {
                if acc.kind == .mixed, acc.numeric >= acc.nonNumeric {
                    let colName = plan.columns[j]
                    for sample in acc.nonNumericSamples {
                        let chunkStart = sample.chunkIndex < cumulative.count ? cumulative[sample.chunkIndex] : 0
                        let fileLine = chunkStart + sample.localLine + 1
                        resolvedIssues.append(SanityIssue(
                            line: fileLine,
                            kind: .typeContamination,
                            columnIndex: j,
                            columnName: colName,
                            expected: "数値",
                            actual: "'\(sample.text)'",
                            preview: "列 [\(colName)]: '\(sample.text)'"
                        ))
                    }
                }
            }

            resolvedIssues.sort { $0.line < $1.line }

            var out = Result()
            out.elapsed = elapsed
            out.scannedLines = scanned
            out.sanityIssues = resolvedIssues

            for (j, acc) in snapshot.enumerated() {
                var stat = ColumnStat(index: j, name: plan.columns[j])
                stat.kind = acc.kind
                stat.present = acc.present
                stat.blank = acc.blank
                stat.missing = acc.missing
                stat.numeric = acc.numeric
                stat.nonNumeric = acc.nonNumeric
                stat.distinct = counters[j].distinctCount
                stat.distinctTruncated = counters[j].didTruncate

                switch stat.kind {
                case .number:
                    stat.minText = acc.minNumberText
                    stat.maxText = acc.maxNumberText
                    if acc.hasReal {
                        stat.sum = .real(acc.realSum)
                    } else {
                        stat.sum = acc.intOverflow ? .overflow : .integer(acc.intSum)
                    }
                    if acc.present > 0 {
                        let total = (!acc.hasReal && !acc.intOverflow) ? Double(acc.intSum) : acc.realSum
                        stat.average = total / Double(acc.present)
                    }
                case .datetime:
                    stat.minText = acc.minDateText
                    stat.maxText = acc.maxDateText
                default:
                    stat.minText = acc.minText
                    stat.maxText = acc.maxText
                }

                stat.top = counters[j].topRows(3)
                out.columns.append(stat)
            }
            return out
        }
    }
}