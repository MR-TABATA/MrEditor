import Foundation

/// 1 行から「数える値」を 1 つ取り出す。**集計（C1）と列の統計（C2）が共有する。**
///
/// ## 1 行あたりの仕事を増やさない
///
/// 8,642 万行を通すので、**1 行ごとの確保が 1 つ増えるだけで数秒効く**。実際、最初の実装は
/// 行ごとに `"\(key)=".utf8` の配列を作り直していて、10GB が 40.37 秒かかった（同じことを
/// する使い捨てベンチは 3.32 秒）。**準備は `Compiled` で 1 回だけ**行い、走査中は
/// バイト列を切って `String` を 1 つ作るだけにする。`TimestampDetector` が
/// 「形式は行ごとでなくソースごとに 1 回決める」としているのと同じ形。
enum ValueExtractor {

    enum Mode: Equatable {
        /// 構造化表示中の列（0 始まり）。区切りと引用符の扱いは**表示と同じ**。
        case column(index: Int, mode: StructuredMode)
        /// `key=value`（logfmt 風）。値は空白まで、`key="a b"` は引用符の中まで。
        case keyValue(key: String)
        /// 正規表現の第 1 キャプチャ群。
        case regex(NSRegularExpression)
        /// 行全体。
        case wholeLine
        /// NDJSON のキー（列番号→キー名は呼び出し側が解決する）。
        case jsonKey(String)
    }

    struct Options: Equatable {
        /// 前後の空白を落とす。
        var trim = true
        /// 大文字小文字を区別する（既定）。区別しないときは小文字に畳んで数える。
        var caseSensitive = true
    }

    /// 値が空だった行。**落とさずに数える**（空欄が何件あるかは知りたい情報）。
    static let blank = S.t("(空欄)", "(blank)")
    /// 値が取り出せなかった行（列が足りない・キーが無い・正規表現が当たらない）。
    static let missing = S.t("(該当なし)", "(no value)")

    /// 走査の前に 1 回だけ作る取り出し器。**走査中はこれしか呼ばない。**
    struct Compiled {
        let mode: Mode
        let options: Options

        /// `key=` のバイト列（`keyValue` のときだけ）。**行ごとに作り直さない。**
        private let needle: [UInt8]
        private let columnIndex: Int
        private let separator: UInt8
        private let quoted: Bool
        /// バイト列のまま切れるか（NDJSON と正規表現は文字列にしてから）。
        private let byteCapable: Bool

        init(mode: Mode, options: Options) {
            self.mode = mode
            self.options = options
            switch mode {
            case .keyValue(let key):
                needle = Array("\(key)=".utf8)
                columnIndex = 0; separator = 0; quoted = false; byteCapable = true
            case .column(let index, let structured):
                needle = []
                columnIndex = index
                separator = structured == .tsv ? 0x09 : UInt8(ascii: ",")
                quoted = structured == .csv
                byteCapable = structured == .csv || structured == .tsv
            case .wholeLine:
                needle = []; columnIndex = 0; separator = 0; quoted = false; byteCapable = true
            case .regex, .jsonKey:
                needle = []; columnIndex = 0; separator = 0; quoted = false; byteCapable = false
            }
        }

        /// UTF-8 のバイト列から。**これが本線**（10GB を通る経路）。
        func value(from line: UnsafeBufferPointer<UInt8>) -> String {
            guard byteCapable else {
                return value(fromString: String(decoding: line, as: UTF8.self))
            }
            switch mode {
            case .wholeLine:
                return finish(line, range: 0..<line.count, unquote: false)

            case .keyValue:
                guard let range = KeyValueScanner.valueRange(needle: needle, in: line) else { return missing }
                return finish(line, range: range.range, unquote: false, alreadyUnquoted: range.wasQuoted)

            case .column:
                guard let range = CSVFieldScanner.fieldRange(at: columnIndex, in: line,
                                                             separator: separator, quoted: quoted) else {
                    return missing
                }
                return finish(line, range: range, unquote: quoted)

            case .regex, .jsonKey:
                return value(fromString: String(decoding: line, as: UTF8.self))
            }
        }

        /// 文字列から（Shift-JIS / EUC-JP の行、小ファイルの本文、正規表現、NDJSON）。
        func value(fromString line: String) -> String {
            switch mode {
            case .column(let index, let structured):
                switch structured {
                case .csv, .tsv:
                    let cells = TabularFormatter.splitDelimited(line,
                                                                sep: structured == .csv ? "," : "\t",
                                                                csvQuotes: structured == .csv)
                    guard index < cells.count else { return missing }
                    return normalize(cells[index])
                case .ndjson, .json:
                    return missing          // 列番号→キー名は呼び出し側が解決して .jsonKey で来る
                case .fixedWidth:
                    // 桁の定義を受け取っていないので切れない。**呼ぶ側（AggregateView）が
                    // 先に弾く**ので普通は来ない。ここは保険で、黙って 1 列目を返さない。
                    return missing
                }

            case .jsonKey(let key):
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let v = obj[key] else { return missing }
                if v is NSNull { return blank }
                if let s = v as? String { return normalize(s) }
                if let n = v as? NSNumber { return normalize(n.stringValue) }
                return normalize(String(describing: v))

            case .keyValue(let key):
                guard let r = line.range(of: "\(key)=") else { return missing }
                let rest = line[r.upperBound...]
                if rest.first == "\"" {
                    let body = rest.dropFirst()
                    guard let close = body.firstIndex(of: "\"") else { return normalize(String(body)) }
                    return normalize(String(body[..<close]))
                }
                let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "," }) ?? rest.endIndex
                return normalize(String(rest[..<end]))

            case .regex(let rx):
                let ns = line as NSString
                guard let m = rx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                      m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return missing }
                return normalize(ns.substring(with: m.range(at: 1)))

            case .wholeLine:
                return normalize(line)
            }
        }

        // MARK: - 仕上げ

        /// バイト範囲を切り出して仕上げる。**`String` を作るのは最後の 1 回だけ**で、
        /// 前後の空白落としはバイトのまま行う（`trimmingCharacters` は文字列をもう 1 つ作る）。
        private func finish(_ line: UnsafeBufferPointer<UInt8>,
                            range: Range<Int>,
                            unquote: Bool,
                            alreadyUnquoted: Bool = false) -> String {
            var lo = range.lowerBound
            var hi = range.upperBound
            if options.trim {
                while lo < hi, line[lo] == 0x20 || line[lo] == 0x09 { lo += 1 }
                while hi > lo, line[hi - 1] == 0x20 || line[hi - 1] == 0x09 { hi -= 1 }
            }
            guard lo < hi else { return blank }
            if unquote && !alreadyUnquoted && line[lo] == UInt8(ascii: "\"") {
                let s = CSVFieldScanner.decode(line, range: lo..<hi, unquote: true)
                return s.isEmpty ? blank : (options.caseSensitive ? s : s.lowercased())
            }
            let s = String(decoding: line[lo..<hi], as: UTF8.self)
            return options.caseSensitive ? s : s.lowercased()
        }

        private func normalize(_ raw: String) -> String {
            var v = raw
            if options.trim { v = v.trimmingCharacters(in: .whitespaces) }
            if v.isEmpty { return blank }
            if !options.caseSensitive { v = v.lowercased() }
            return v
        }
    }

    // MARK: - 便利口（試験と 1 回きりの呼び出し用）

    /// **走査の中では使わない**（毎回 `Compiled` を作るため）。試験と単発の呼び出し用。
    static func value(from line: UnsafeBufferPointer<UInt8>,
                      mode: Mode,
                      options: Options) -> String {
        Compiled(mode: mode, options: options).value(from: line)
    }

    static func value(fromString line: String, mode: Mode, options: Options) -> String {
        Compiled(mode: mode, options: options).value(fromString: line)
    }
}

/// 区切り文字で N 番目の欄をバイト列のまま切り出す。
///
/// **`TabularFormatter.splitDelimited` と同じ結果でなければならない**（画面に出ている列と
/// 数えている列がズレると、誰も気づけない嘘になる）。同じであることは
/// `ValueExtractorTests` が実際に突き合わせて確かめている。
enum CSVFieldScanner {

    /// `index` 番目の欄のバイト範囲。欄が足りなければ nil。
    static func fieldRange(at index: Int,
                          in line: UnsafeBufferPointer<UInt8>,
                          separator: UInt8,
                          quoted: Bool) -> Range<Int>? {
        let quote = UInt8(ascii: "\"")
        var field = 0
        var i = 0
        var start = 0
        var inQuotes = false
        // 欄の先頭でだけ引用符が開く（`splitDelimited` の `field.isEmpty` と同じ規則）。
        var atFieldStart = true

        while i < line.count {
            let c = line[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < line.count && line[i + 1] == quote { i += 2; continue }
                    inQuotes = false
                }
                i += 1
            } else {
                if quoted && c == quote && atFieldStart {
                    inQuotes = true
                    atFieldStart = false
                    i += 1
                } else if c == separator {
                    if field == index { return start..<i }
                    field += 1
                    i += 1
                    start = i
                    atFieldStart = true
                } else {
                    atFieldStart = false
                    i += 1
                }
            }
        }
        if field == index { return start..<line.count }
        return nil
    }

    /// 範囲を文字列にする。`unquote` なら外側の引用符を外し、`""` を `"` に戻す。
    static func decode(_ line: UnsafeBufferPointer<UInt8>, range: Range<Int>, unquote: Bool) -> String {
        guard range.lowerBound < range.upperBound else { return "" }
        let quote = UInt8(ascii: "\"")
        guard unquote, line[range.lowerBound] == quote else {
            return String(decoding: line[range], as: UTF8.self)
        }
        // `""` が無ければ、外側の引用符を外した中身をそのまま文字列にする
        // （**配列を 1 つ作らない**。C2 は引用符つきの欄を 1.7 億回通る）。
        var k = range.lowerBound + 1
        var hasEscape = false
        while k < range.upperBound {
            if line[k] == quote {
                if k + 1 < range.upperBound && line[k + 1] == quote { hasEscape = true; break }
                break
            }
            k += 1
        }
        if !hasEscape {
            let end = min(k, range.upperBound)
            return String(decoding: line[(range.lowerBound + 1)..<end], as: UTF8.self)
        }

        var out = [UInt8]()
        out.reserveCapacity(range.count)
        var i = range.lowerBound + 1
        let end = range.upperBound
        while i < end {
            let c = line[i]
            if c == quote {
                if i + 1 < end && line[i + 1] == quote { out.append(quote); i += 2; continue }
                i += 1                       // 閉じの引用符
                continue
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// `key=value`（logfmt 風）をバイト列から。
enum KeyValueScanner {

    /// `key=` を**語の頭で**探し、値のバイト範囲を返す。
    ///
    /// 語の頭に限るのは、`id=` を探しているときに `request_id=42` に当たらないようにするため
    /// （区切りは行頭・空白・タブ・カンマ）。`key="a b"` は引用符の中を返す。
    static func valueRange(needle: [UInt8],
                           in line: UnsafeBufferPointer<UInt8>) -> (range: Range<Int>, wasQuoted: Bool)? {
        guard !needle.isEmpty, line.count >= needle.count else { return nil }
        let quote = UInt8(ascii: "\"")
        let first = needle[0]
        var i = 0
        let limit = line.count - needle.count

        while i <= limit {
            if line[i] == first, isBoundary(before: i, in: line), matches(needle, in: line, at: i) {
                var v = i + needle.count
                if v < line.count && line[v] == quote {
                    v += 1
                    var e = v
                    while e < line.count && line[e] != quote { e += 1 }
                    return (v..<e, true)
                }
                var e = v
                while e < line.count && !isSeparator(line[e]) { e += 1 }
                return (v..<e, false)
            }
            i += 1
        }
        return nil
    }

    private static func matches(_ needle: [UInt8], in line: UnsafeBufferPointer<UInt8>, at i: Int) -> Bool {
        for k in 1..<needle.count where line[i + k] != needle[k] { return false }
        return true
    }

    private static func isBoundary(before i: Int, in line: UnsafeBufferPointer<UInt8>) -> Bool {
        i == 0 || isSeparator(line[i - 1])
    }

    private static func isSeparator(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == UInt8(ascii: ",")
    }
}