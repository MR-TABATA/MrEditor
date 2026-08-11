import Foundation

/// ログ1行から時刻を取り出す純ロジック（UI 非依存）。
///
/// 設計の要点は3つ。
///
/// 1. **形式は行ごとでなくソースごとに1回だけ決める**（`detect(sampleLines:)` →
///    `parse`）。`TabularFormatter` の `build`/`format` と同じ型。行ごとに総当たり
///    すると遅い上に、同じファイルの中で行によって解釈が変わって並びが壊れる。
/// 2. **`DateFormatter` も `NSRegularExpression` も使わない**。数百万行を通すので
///    手書きで UTF-8 を走査し、暦計算も自前（`daysFromCivil`）で秒に落とす。
/// 3. **年やタイムゾーンが「無い」形式がある**ことを型で認めている。syslog には年が
///    無く、ISO でもオフセット無しの行がある。無いものは `Components` で `nil` の
///    まま持ち上げ、補い方（`assumedYear` / `timeZoneOffset`）は呼び出し側の設定に
///    する。ここで勝手に「今年・ローカル時刻」と決め打つと、去年のログを開いた瞬間に
///    静かに間違う。
enum TimestampFormat: String, CaseIterable {
    /// `2026-07-30T12:34:56.789Z` / `2026-07-30 12:34:56,789` / オフセット有無どちらも。
    case iso8601
    /// `Jul 30 12:34:56`（RFC3164）。**年が無い。**
    case syslog
    /// `[30/Jul/2026:12:34:56 +0900]`（Apache/nginx の common log）。
    case apache
    /// `1754000000` / `1754000000.123`（10桁＝秒）。
    case epochSeconds
    /// `1754000000123`（13桁＝ミリ秒）。
    case epochMillis
}

struct TimestampDetector {
    /// 行から読み取れた「生の」時刻要素。埋まっていない欄は `nil` のまま持ち上げる。
    struct Components: Equatable {
        var year: Int?              // syslog は年を持たない
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var second: Int
        var fraction: Double        // 秒未満（0.0〜1.0 未満）
        var utcOffset: Int?         // 行に明示されていた場合のみ（秒）
    }

    let format: TimestampFormat
    /// 行にオフセットが書かれていないときに使う UTC オフセット（秒）。既定はローカル。
    let timeZoneOffset: Int
    /// 年を持たない形式（syslog）で使う年。
    let assumedYear: Int

    init(format: TimestampFormat,
         timeZoneOffset: Int = TimeZone.current.secondsFromGMT(),
         assumedYear: Int = Calendar(identifier: .gregorian)
            .component(.year, from: Date())) {
        self.format = format
        self.timeZoneOffset = timeZoneOffset
        self.assumedYear = assumedYear
    }

    // MARK: - 形式の判定

    /// サンプル行から形式を決める。どれも当たらなければ `nil`（＝時刻を持たない
    /// ファイルとして扱う）。命中数が最大の形式を採る。
    ///
    /// **1行でも当たれば候補にする**（`minimumHits` の既定は 1）。スタックトレース
    /// のように時刻を持たない行が大半を占めるログが現実にあり、割合でしきいを切ると
    /// そういうファイルだけ時刻無しに落ちてしまうため。日付形の3形式（ISO/syslog/
    /// Apache）はパターンが十分に具体的なので、偶然当たることはまず無い。
    ///
    /// 危ないのは**エポックだけ**。「13桁の数字＋区切り」で始まる行は世の中にいくらでも
    /// ある（国税庁の法人番号 CSV `1000012010001,01,…` が実例）。そこで**エポック系
    /// にだけ追加の条件**を課す: 命中が3件以上あり、かつ**時刻がほぼ単調に増えている**
    /// こと。ログの時刻は増え続けるが、ID の列は増えたり減ったりする。ここが両者を
    /// 分ける唯一の実用的な差。
    static func detect(sampleLines: [String],
                       timeZoneOffset: Int = TimeZone.current.secondsFromGMT(),
                       assumedYear: Int = Calendar(identifier: .gregorian)
                        .component(.year, from: Date()),
                       minimumHits: Int = 1) -> TimestampDetector? {
        let rows = sampleLines.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }

        var best: (format: TimestampFormat, hits: Int)?
        for f in TimestampFormat.allCases {
            let d = TimestampDetector(format: f, timeZoneOffset: timeZoneOffset, assumedYear: assumedYear)
            let parsed = rows.compactMap { d.parse($0) }
            guard parsed.count >= max(1, minimumHits) else { continue }

            if f == .epochSeconds || f == .epochMillis {
                guard parsed.count >= 3, monotonicRatio(parsed) >= 0.9 else { continue }
            }
            if parsed.count > (best?.hits ?? 0) {
                best = (f, parsed.count)
            }
        }
        guard let best else { return nil }
        return TimestampDetector(format: best.format, timeZoneOffset: timeZoneOffset, assumedYear: assumedYear)
    }

    /// 隣り合う値が「減っていない」割合。1.0 に近いほど時系列らしい。
    static func monotonicRatio(_ values: [Date]) -> Double {
        guard values.count >= 2 else { return 1.0 }
        var ok = 0
        for i in 1..<values.count where values[i] >= values[i - 1] { ok += 1 }
        return Double(ok) / Double(values.count - 1)
    }

    // MARK: - 1行を解釈する

    /// 1行から時刻を取り出す。取れなければ `nil`（＝継続行・見出し行など）。
    func parse(_ line: String) -> Date? {
        guard let c = parseComponents(line) else { return nil }
        return date(from: c, year: c.year ?? assumedYear)
    }

    /// 複数行をまとめて解釈する。行数は入力と必ず一致する。
    ///
    /// `parse` を単に `map` するのと違い、**年を持たない形式の年またぎを補正する**。
    /// 12月31日の次に1月1日が来ると、年を固定したままでは約11か月巻き戻って見え、
    /// 並べ替えた瞬間にログが裏返る。時刻が2日以上巻き戻ったら年が変わったとみなす
    /// （同一ソース内の行は時系列に並んでいる、という前提に依存している）。
    func parseAll(_ lines: [String]) -> [Date?] {
        var out: [Date?] = []
        out.reserveCapacity(lines.count)
        var yearShift = 0
        var previous: Date?

        for line in lines {
            guard let c = parseComponents(line) else {
                out.append(nil)
                continue
            }
            if c.year != nil {
                let d = date(from: c, year: c.year!)
                out.append(d)
                previous = d
                continue
            }
            var d = date(from: c, year: assumedYear + yearShift)
            if let prev = previous, d < prev.addingTimeInterval(-2 * 86400) {
                yearShift += 1
                d = date(from: c, year: assumedYear + yearShift)
            }
            out.append(d)
            previous = d
        }
        return out
    }

    /// `Components` と年から実際の時刻を作る。行にオフセットがあればそれを、
    /// 無ければ `timeZoneOffset` を使う。
    func date(from c: Components, year: Int) -> Date {
        let days = Self.daysFromCivil(year, c.month, c.day)
        let secs = days * 86_400 + c.hour * 3_600 + c.minute * 60 + c.second
        let offset = c.utcOffset ?? timeZoneOffset
        return Date(timeIntervalSince1970: Double(secs - offset) + c.fraction)
    }

    // MARK: - 形式ごとの走査

    /// 1行を走査して要素を取り出す。
    ///
    /// `Array(line.utf8)` を作らず `withUTF8` で既存のバッファを直接見る。行ごとの
    /// 確保は1行では些細でも、数百万行では支配的になる。
    ///
    /// 実測（2026-08-04・Mac mini M1・`swift test -Xswiftc -O`・`testdata/test_50mb_jp.log`
    /// 429,337 行）: **3.74 → 13.9 M行/s**。
    ///
    /// ⚠️ **速いのは Swift ネイティブの文字列に限る。** NSString 由来（`String(format:)`
    /// の戻り値など）は連続バッファを持たず、`withUTF8` がそのたびにコピーを作る。
    /// ここに流す行は自前のファイル読み込みから来るネイティブ文字列であること。
    func parseComponents(_ line: String) -> Components? {
        var s = line
        return s.withUTF8 { raw -> Components? in
            guard let base = raw.baseAddress, !raw.isEmpty else { return nil }
            let b = UnsafeBufferPointer(start: base, count: min(raw.count, Self.scanLimit))
            switch format {
            case .iso8601:      return Self.scanISO8601(b)
            case .syslog:       return Self.scanSyslog(b)
            case .apache:       return Self.scanApache(b)
            case .epochSeconds: return Self.scanEpoch(b, millis: false)
            case .epochMillis:  return Self.scanEpoch(b, millis: true)
            }
        }
    }

    /// 行頭から何バイトまで時刻を探すか。ログの時刻は行頭付近にあるという前提で、
    /// 長い行の全走査を避ける。Apache は IP やユーザ名が前に付くので少し余裕を持つ。
    static let scanLimit = 128

    // MARK: - スキャナ（いずれも失敗したら nil を返すだけ。例外も副作用も無い）

    /// `2026-07-30T12:34:56.789+09:00` / `2026-07-30 12:34:56,789` / 末尾 `Z`。
    static func scanISO8601(_ b: UnsafeBufferPointer<UInt8>) -> Components? {
        // 「4桁数字 + '-'」で始まる位置を探す
        var start = -1
        var i = 0
        while i + 4 < b.count {
            if isDigit(b[i]), isDigit(b[i+1]), isDigit(b[i+2]), isDigit(b[i+3]), b[i+4] == UInt8(ascii: "-") {
                start = i
                break
            }
            i += 1
        }
        guard start >= 0 else { return nil }

        var p = start
        guard let year = readInt(b, &p, 4) else { return nil }
        guard expect(b, &p, "-"), let month = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, "-"), let day = readInt(b, &p, 2) else { return nil }
        // 日付と時刻の区切りは 'T' でも ' ' でもよい
        guard p < b.count, b[p] == UInt8(ascii: "T") || b[p] == UInt8(ascii: " ") else { return nil }
        p += 1
        guard let hour = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let minute = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let second = readInt(b, &p, 2) else { return nil }

        // 秒未満は '.' でも ',' でもよい（Java 系のログは ','）
        var fraction = 0.0
        if p < b.count, b[p] == UInt8(ascii: ".") || b[p] == UInt8(ascii: ",") {
            p += 1
            var scale = 0.1
            while p < b.count, isDigit(b[p]) {
                fraction += Double(b[p] - 48) * scale
                scale /= 10
                p += 1
            }
        }

        guard valid(month: month, day: day, hour: hour, minute: minute, second: second) else { return nil }
        return Components(year: year, month: month, day: day, hour: hour, minute: minute,
                          second: second, fraction: fraction, utcOffset: readOffset(b, &p))
    }

    /// `Jul 30 12:34:56`。年もタイムゾーンも無い。日は1桁のとき空白詰め（`Jul  3`）。
    static func scanSyslog(_ b: UnsafeBufferPointer<UInt8>) -> Components? {
        var p = 0
        while p < b.count, b[p] == UInt8(ascii: " ") { p += 1 }
        guard let month = readMonthName(b, &p) else { return nil }
        while p < b.count, b[p] == UInt8(ascii: " ") { p += 1 }
        guard let day = readInt(b, &p, 2) ?? readInt(b, &p, 1) else { return nil }
        guard expect(b, &p, " ") else { return nil }
        while p < b.count, b[p] == UInt8(ascii: " ") { p += 1 }
        guard let hour = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let minute = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let second = readInt(b, &p, 2) else { return nil }
        guard valid(month: month, day: day, hour: hour, minute: minute, second: second) else { return nil }
        return Components(year: nil, month: month, day: day, hour: hour, minute: minute,
                          second: second, fraction: 0, utcOffset: nil)
    }

    /// `[30/Jul/2026:12:34:56 +0900]`。前に IP やユーザ名が付くので `[` を探す。
    static func scanApache(_ b: UnsafeBufferPointer<UInt8>) -> Components? {
        guard var p = b.firstIndex(of: UInt8(ascii: "[")) else { return nil }
        p += 1
        guard let day = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, "/"), let month = readMonthName(b, &p) else { return nil }
        guard expect(b, &p, "/"), let year = readInt(b, &p, 4) else { return nil }
        guard expect(b, &p, ":"), let hour = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let minute = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let second = readInt(b, &p, 2) else { return nil }
        guard valid(month: month, day: day, hour: hour, minute: minute, second: second) else { return nil }
        if p < b.count, b[p] == UInt8(ascii: " ") { p += 1 }
        return Components(year: year, month: month, day: day, hour: hour, minute: minute,
                          second: second, fraction: 0, utcOffset: readOffset(b, &p))
    }

    /// 行頭の `1754000000` / `1754000000.123` / `1754000000123`。
    ///
    /// 秒とミリ秒は桁数で分ける（10桁 / 13桁）。ここを緩くすると、行頭に ID を持つ
    /// ログを全部エポックとして誤読する。
    static func scanEpoch(_ b: UnsafeBufferPointer<UInt8>, millis: Bool) -> Components? {
        var p = 0
        while p < b.count, b[p] == UInt8(ascii: " ") { p += 1 }
        let head = p
        var value = 0
        while p < b.count, isDigit(b[p]) {
            value = value * 10 + Int(b[p] - 48)
            p += 1
        }
        let digits = p - head
        guard digits == (millis ? 13 : 10) else { return nil }

        var seconds = value
        var fraction = 0.0
        if millis {
            seconds = value / 1000
            fraction = Double(value % 1000) / 1000
        } else if p < b.count, b[p] == UInt8(ascii: ".") {
            p += 1
            var scale = 0.1
            while p < b.count, isDigit(b[p]) {
                fraction += Double(b[p] - 48) * scale
                scale /= 10
                p += 1
            }
        }
        // 数字の直後が英数字なら時刻ではなく ID の一部とみなす
        if p < b.count, isDigit(b[p]) || isLetter(b[p]) { return nil }

        // エポックは定義上 UTC。暦へ戻して Components に載せる。
        let days = Int(floor(Double(seconds) / 86_400))
        let rem = seconds - days * 86_400
        let (y, m, d) = civilFromDays(days)
        return Components(year: y, month: m, day: d,
                          hour: rem / 3600, minute: (rem % 3600) / 60, second: rem % 60,
                          fraction: fraction, utcOffset: 0)
    }

    // MARK: - 細かい部品

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    private static func isLetter(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    private static func expect(_ b: UnsafeBufferPointer<UInt8>, _ p: inout Int, _ ch: Character) -> Bool {
        guard p < b.count, b[p] == ch.asciiValue else { return false }
        p += 1
        return true
    }

    /// ちょうど `count` 桁の数字を読む。足りなければ位置を戻して nil。
    private static func readInt(_ b: UnsafeBufferPointer<UInt8>, _ p: inout Int, _ count: Int) -> Int? {
        guard p + count <= b.count else { return nil }
        var v = 0
        for k in 0..<count {
            guard isDigit(b[p + k]) else { return nil }
            v = v * 10 + Int(b[p + k] - 48)
        }
        p += count
        return v
    }

    private static let monthNames: [[UInt8]] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        .map { Array($0.utf8) }

    private static func readMonthName(_ b: UnsafeBufferPointer<UInt8>, _ p: inout Int) -> Int? {
        guard p + 3 <= b.count else { return nil }
        for (idx, name) in monthNames.enumerated() where b[p] == name[0] && b[p+1] == name[1] && b[p+2] == name[2] {
            p += 3
            return idx + 1
        }
        return nil
    }

    /// `Z` / `+09:00` / `-0500` / `-07` を秒で返す。無ければ nil（＝呼び出し側の既定を使う）。
    ///
    /// **分を省いた2桁だけの `-07` を必ず受けること。** macOS の
    /// `/var/log/install.log` が実際にこの形（`2025-07-18 08:15:05-07 localhost …`）。
    /// ここを取りこぼすと offset が nil になって既定のタイムゾーンに落ち、**数時間ずれた
    /// 時刻を正しい顔で返す**——複数ホストを束ねたときに最も見つけにくい壊れ方になる。
    private static func readOffset(_ b: UnsafeBufferPointer<UInt8>, _ p: inout Int) -> Int? {
        guard p < b.count else { return nil }
        if b[p] == UInt8(ascii: "Z") || b[p] == UInt8(ascii: "z") { p += 1; return 0 }
        guard b[p] == UInt8(ascii: "+") || b[p] == UInt8(ascii: "-") else { return nil }
        let sign = b[p] == UInt8(ascii: "-") ? -1 : 1
        var q = p + 1
        guard let hh = readInt(b, &q, 2) else { return nil }
        var mm = 0
        var r = q
        if r < b.count, b[r] == UInt8(ascii: ":") { r += 1 }
        if let m = readInt(b, &r, 2) { mm = m; q = r }   // 分が無ければ hh だけで確定
        p = q
        return sign * (hh * 3600 + mm * 60)
    }

    private static func valid(month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Bool {
        (1...12).contains(month) && (1...31).contains(day)
            && (0...23).contains(hour) && (0...59).contains(minute) && (0...60).contains(second)
    }

    // MARK: - 暦（Howard Hinnant の days_from_civil / civil_from_days）
    //
    // Calendar/DateComponents は1行ごとに呼ぶには重すぎるので、グレゴリオ暦の
    // 変換だけ整数演算で持つ。うるう年・世紀の例外はこの式に含まれている。

    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        var y = year
        y -= month <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                   // 0..399
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097                               // 0..146096
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)         // 0..365
        let mp = (5 * doy + 2) / 153                              // 0..11
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
}
