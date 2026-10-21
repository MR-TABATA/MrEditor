import Foundation

/// 編集ツールボックスの純粋なテキスト変換（String→String）。
/// バックエンド（NSTextView / PieceTable）に依存せず、両ペインから同じロジックを使う。
/// 行操作系は「選択されたテキストをそのまま分割して処理」する（フィルタ ⌥⌘R と同じ考え方）。
enum TextTransform: Int, CaseIterable {
    // ケース変換
    case uppercase
    case lowercase
    case titlecase
    case togglecase
    // エンコード／デコード
    case urlEncode
    case urlDecode
    case base64Encode
    case base64Decode
    case htmlEncode
    case htmlDecode
    // 行操作
    case sortAscending
    case sortDescending
    case uniqueLines
    case duplicateLinesOnly
    case removeEmptyLines
    case reverseLines
    case numberLines
    case joinLines
    case indent
    case outdent
    case tabsToSpaces
    case spacesToTabs
    // 日時・時刻変換
    case unixTimestampToDate
    case dateToUnixTimestamp

    /// ケース変換グループ（書式メニューの第1グループ）。
    static let caseGroup: [TextTransform] = [.uppercase, .lowercase, .titlecase, .togglecase]
    /// エンコード／デコードグループ（第2グループ）。
    static let encodingGroup: [TextTransform] = [.urlEncode, .urlDecode, .base64Encode, .base64Decode, .htmlEncode, .htmlDecode]
    /// 日時・時刻変換グループ（第3グループ）。
    static let dateTimeGroup: [TextTransform] = [.unixTimestampToDate, .dateToUnixTimestamp]
    /// 行操作グループ（第4グループ）。連番はパラメータを取るのでメニューでは
    /// ダイアログ付きの別項目（`LineNumberer`）にしてあり、ここには並べない。
    static let lineGroup: [TextTransform] = [
        .sortAscending, .sortDescending,
        .uniqueLines, .duplicateLinesOnly, .removeEmptyLines,
        .reverseLines, .joinLines,
        .indent, .outdent, .tabsToSpaces, .spacesToTabs,
    ]

    /// 字下げ／字上げの単位（タブ1つ。字上げはこの単位ぶんの先頭タブ、または同幅の先頭スペースを1段はがす）。
    static let indentUnit = "\t"
    /// 字上げでタブが無い行から剥がす先頭スペースの上限（一般的なタブ幅）。
    static let outdentSpaceWidth = 4

    /// メニュー項目のローカライズキー。
    var localizationKey: String {
        switch self {
        case .uppercase:           return "menu.format.uppercase"
        case .lowercase:           return "menu.format.lowercase"
        case .titlecase:           return "menu.format.titlecase"
        case .togglecase:          return "menu.format.togglecase"
        case .urlEncode:           return "menu.format.urlEncode"
        case .urlDecode:           return "menu.format.urlDecode"
        case .base64Encode:        return "menu.format.base64Encode"
        case .base64Decode:        return "menu.format.base64Decode"
        case .htmlEncode:          return "menu.format.htmlEncode"
        case .htmlDecode:          return "menu.format.htmlDecode"
        case .sortAscending:       return "menu.format.sortAscending"
        case .sortDescending:      return "menu.format.sortDescending"
        case .uniqueLines:         return "menu.format.uniqueLines"
        case .duplicateLinesOnly:  return "menu.format.duplicateLinesOnly"
        case .removeEmptyLines:    return "menu.format.removeEmptyLines"
        case .reverseLines:        return "menu.format.reverseLines"
        case .numberLines:         return "menu.format.numberLines"
        case .joinLines:           return "menu.format.joinLines"
        case .indent:              return "menu.format.indent"
        case .outdent:             return "menu.format.outdent"
        case .tabsToSpaces:        return "menu.format.tabsToSpaces"
        case .spacesToTabs:        return "menu.format.spacesToTabs"
        case .unixTimestampToDate: return "menu.format.unixTimestampToDate"
        case .dateToUnixTimestamp: return "menu.format.dateToUnixTimestamp"
        }
    }

    /// 選択文字列に変換を適用して返す。`nil` は変換不能（不正な入力など）＝呼び出し側はビープして本文を変えない。
    func apply(_ s: String) -> String? {
        switch self {
        case .uppercase:  return s.uppercased()
        case .lowercase:  return s.lowercased()
        case .titlecase:  return s.capitalized
        case .togglecase: return String(s.map { c in
            c.isUppercase ? Character(c.lowercased()) :
            c.isLowercase ? Character(c.uppercased()) : c
        })
        case .urlEncode:  return s.addingPercentEncoding(withAllowedCharacters: Self.urlUnreserved)
        case .urlDecode:  return s.removingPercentEncoding
        case .base64Encode: return Data(s.utf8).base64EncodedString()
        case .base64Decode:
            // 改行入りの折り返し Base64 も通す（不明文字は無視）。復号後が UTF-8 でなければ nil。
            guard let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        case .htmlEncode: return Self.htmlEncode(s)
        case .htmlDecode: return Self.htmlDecode(s)
        case .sortAscending:      return Self.sortLines(s, by: <)
        case .sortDescending:     return Self.sortLines(s, by: >)
        case .uniqueLines:        return Self.uniqueLines(s)
        case .duplicateLinesOnly: return Self.duplicateLinesOnly(s)
        case .removeEmptyLines:   return Self.removeEmptyLines(s)
        case .reverseLines:       return Self.mapLines(s) { Array($0.reversed()) }
        case .numberLines:        return Self.numberLines(s)
        case .joinLines:          return Self.joinLines(s)
        case .indent:             return Self.indent(s)
        case .outdent:            return Self.outdent(s)
        case .tabsToSpaces:       return Self.tabsToSpaces(s)
        case .spacesToTabs:       return Self.spacesToTabs(s)
        case .unixTimestampToDate: return Self.unixTimestampToDate(s)
        case .dateToUnixTimestamp: return Self.dateToUnixTimestamp(s)
        }
    }

    /// RFC 3986 の unreserved（これ以外を % エンコードする）。
    private static let urlUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: - HTML エンティティ

    private static func htmlEncode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            default:   out.append(ch)
            }
        }
        return out
    }

    /// 数値参照（10 進 / 16 進）と主要な名前付きエンティティを1パスで復号する。
    /// 未知のエンティティはそのまま残す（壊さない）。
    private static func htmlDecode(_ s: String) -> String {
        let ns = s as NSString
        let matches = htmlEntityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))   // & と ; を除いた中身
            out += decodeEntityBody(body) ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return out
    }

    private static func decodeEntityBody(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let num = body.dropFirst()
            let scalar: UInt32? = (num.first == "x" || num.first == "X")
                ? UInt32(num.dropFirst(), radix: 16) : UInt32(num, radix: 10)
            guard let value = scalar, let u = Unicode.Scalar(value) else { return nil }
            return String(u)
        }
        return htmlNamed[body].map(String.init)
    }

    private static let htmlEntityRegex =
        try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);")

    private static let htmlNamed: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "hellip": "\u{2026}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "middot": "\u{00B7}", "bull": "\u{2022}",
    ]

    // MARK: - 行操作

    /// 末尾改行を保ったまま行に分割する（分割で生じる末尾の空要素を落とす）。
    private static func splitLines(_ s: String) -> (lines: [String], trailingNewline: Bool) {
        let hasTrailing = s.hasSuffix("\n")
        var lines = s.components(separatedBy: "\n")
        if hasTrailing { lines.removeLast() }
        return (lines, hasTrailing)
    }

    private static func joinLines(_ lines: [String], trailingNewline: Bool) -> String {
        lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    private static func sortLines(_ s: String, by areInIncreasingOrder: (String, String) -> Bool) -> String {
        let (lines, trailing) = splitLines(s)
        return joinLines(lines.sorted(by: areInIncreasingOrder), trailingNewline: trailing)
    }

    /// 重複行を削除（初出の順序を保つ）。
    private static func uniqueLines(_ s: String) -> String {
        let (lines, trailing) = splitLines(s)
        var seen = Set<String>()
        let unique = lines.filter { seen.insert($0).inserted }
        return joinLines(unique, trailingNewline: trailing)
    }

    private static func mapLines(_ s: String, _ transform: ([String]) -> [String]) -> String {
        let (lines, trailing) = splitLines(s)
        return joinLines(transform(lines), trailingNewline: trailing)
    }

    /// 各行の先頭に 1 始まりの連番＋タブを付ける（既定パラメータの `LineNumberer` そのもの）。
    private static func numberLines(_ s: String) -> String {
        LineNumberer.number(s, options: .init())
    }

    /// 複数行を1行に連結する（改行を1つのスペースに畳み、各行の前後空白を除く）。
    /// 空行は落とす。末尾改行は保つ（連結後の1行に付く）。
    private static func joinLines(_ s: String) -> String {
        let (lines, trailing) = splitLines(s)
        let joined = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joinLines([joined], trailingNewline: trailing)
    }

    /// 各行の先頭に字下げ単位（タブ）を1段挿入する。空行は字下げしない（余分な空白を残さない）。
    private static func indent(_ s: String) -> String {
        mapLines(s) { lines in
            lines.map { $0.isEmpty ? $0 : indentUnit + $0 }
        }
    }

    /// 各行の先頭の字下げを1段はがす。タブ1つ、無ければ先頭スペースを最大 `outdentSpaceWidth` 個まで削る。
    private static func outdent(_ s: String) -> String {
        mapLines(s) { lines in
            lines.map { line in
                if line.hasPrefix(indentUnit) { return String(line.dropFirst(indentUnit.count)) }
                var dropped = 0
                var idx = line.startIndex
                while dropped < outdentSpaceWidth, idx < line.endIndex, line[idx] == " " {
                    idx = line.index(after: idx); dropped += 1
                }
                return String(line[idx...])
            }
        }
    }

    /// 2回以上現れた重複行だけを初出の順序で1行ずつ抽出する（重複削除の補集合）。
    private static func duplicateLinesOnly(_ s: String) -> String {
        let (lines, trailing) = splitLines(s)
        var counts: [String: Int] = [:]
        for line in lines { counts[line, default: 0] += 1 }
        var seen = Set<String>()
        var duplicates: [String] = []
        for line in lines {
            if (counts[line] ?? 0) >= 2 && seen.insert(line).inserted {
                duplicates.append(line)
            }
        }
        return joinLines(duplicates, trailingNewline: trailing && !duplicates.isEmpty)
    }

    /// 空行（空白文字のみの行を含む）を一括削除する。
    private static func removeEmptyLines(_ s: String) -> String {
        let (lines, trailing) = splitLines(s)
        let nonEmpties = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return joinLines(nonEmpties, trailingNewline: trailing && !nonEmpties.isEmpty)
    }

    /// タブ文字を半角スペース（`outdentSpaceWidth` 個＝既定 4 つ）に置換する。
    private static func tabsToSpaces(_ s: String) -> String {
        let spaces = String(repeating: " ", count: outdentSpaceWidth)
        return s.replacingOccurrences(of: "\t", with: spaces)
    }

    /// 各行の先頭の連続スペース（`outdentSpaceWidth` 個単位）をタブに変換する。
    private static func spacesToTabs(_ s: String) -> String {
        let unitSpaces = String(repeating: " ", count: outdentSpaceWidth)
        return mapLines(s) { lines in
            lines.map { line in
                var res = ""
                var idx = line.startIndex
                while idx < line.endIndex {
                    if line[idx...].hasPrefix(unitSpaces) {
                        res.append("\t")
                        idx = line.index(idx, offsetBy: outdentSpaceWidth)
                    } else if line[idx] == "\t" {
                        res.append("\t")
                        idx = line.index(after: idx)
                    } else {
                        res.append(contentsOf: line[idx...])
                        break
                    }
                }
                return res
            }
        }
    }

    // MARK: - 日時・時刻変換

    /// UNIX タイムスタンプ（秒またはミリ秒の整数）をローカルの日時文字列（yyyy-MM-dd HH:mm:ss）へ変換する。
    private static func unixTimestampToDate(_ s: String) -> String? {
        let (lines, trailing) = splitLines(s)
        guard !lines.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var convertedCount = 0
        let result = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let val = Double(trimmed), val > 0 else { return line }
            let date: Date
            if val > 1_000_000_000_000 {
                // 13 桁ミリ秒
                date = Date(timeIntervalSince1970: val / 1000.0)
            } else if val > 100_000_000 {
                // 9〜11 桁秒
                date = Date(timeIntervalSince1970: val)
            } else {
                return line
            }
            convertedCount += 1
            return formatter.string(from: date)
        }
        guard convertedCount > 0 else { return nil }
        return joinLines(result, trailingNewline: trailing)
    }

    /// 日時文字列（ISO8601、yyyy-MM-dd HH:mm:ss、syslog、Apache等）を UNIX タイムスタンプ秒に変換する。
    private static func dateToUnixTimestamp(_ s: String) -> String? {
        let (lines, trailing) = splitLines(s)
        guard !lines.isEmpty else { return nil }

        guard let detector = TimestampDetector.detect(sampleLines: lines) else { return nil }

        var convertedCount = 0
        let result = lines.map { line -> String in
            if let date = detector.parse(line) {
                convertedCount += 1
                return String(Int64(date.timeIntervalSince1970))
            }
            return line
        }
        guard convertedCount > 0 else { return nil }
        return joinLines(result, trailingNewline: trailing)
    }
}

/// 行の分割（`TextTransform` の連結の逆操作）。区切り文字というパラメータを取るため
/// 引数なしの `TextTransform` には載せず、ダイアログで設定を受け取ってここを呼ぶ。
enum LineSplitter {
    /// 分割の設定（ダイアログの各項目に 1 対 1 で対応する）。
    struct Options: Equatable {
        /// 区切り文字（`\t` `\n` `\\` のエスケープを解いてから使う）。
        var delimiter: String
        /// 分割した各要素の前後の空白を取り除く。
        var trimEach: Bool
        /// 空になった要素を捨てる（`a,,b` → 2 行）。
        var dropEmpty: Bool

        init(delimiter: String, trimEach: Bool = false, dropEmpty: Bool = false) {
            self.delimiter = delimiter
            self.trimEach = trimEach
            self.dropEmpty = dropEmpty
        }
    }

    /// 選択テキストの各行を区切り文字で分割し、改行区切りにして返す。
    /// 区切り文字が空（エスケープを解いた結果も空）なら nil＝変換不能。
    static func split(_ s: String, options: Options) -> String? {
        let delimiter = unescape(options.delimiter)
        guard !delimiter.isEmpty else { return nil }

        let hasTrailingNewline = s.hasSuffix("\n")
        var lines = s.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }

        var out: [String] = []
        for line in lines {
            var parts = line.components(separatedBy: delimiter)
            if options.trimEach { parts = parts.map { $0.trimmingCharacters(in: .whitespaces) } }
            if options.dropEmpty { parts = parts.filter { !$0.isEmpty } }
            out.append(contentsOf: parts)
        }
        return out.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
    }

    /// 入力欄に打てない文字をエスケープで受け取る（`TextEscape` そのもの）。
    static func unescape(_ s: String) -> String { TextEscape.unescape(s) }
}

/// ダイアログの入力欄で「打てない文字」をエスケープ表記で受け取るための共通ロジック。
/// 行の分割の区切り文字・連番の区切り文字が同じ書き方（`\t` / `\n`）で通るように 1 箇所に置く。
enum TextEscape {
    /// エスケープの先導文字。日本語キーボードでは同じキーが `¥`（半角・全角）を打つので、
    /// バックスラッシュと同じに扱う（`¥t` と打ってもタブとして通る）。
    private static let leaders: Set<Character> = ["\\", "¥", "￥"]

    /// `\t`＝タブ、`\n`＝改行、`\\`＝その文字自身。
    /// 未知のエスケープは 2 文字そのまま残す（勝手に食べない）。
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.startIndex
        while it < s.endIndex {
            let ch = s[it]
            let next = s.index(after: it)
            guard leaders.contains(ch), next < s.endIndex else { out.append(ch); it = next; continue }
            switch s[next] {
            case "t":  out.append("\t"); it = s.index(after: next)
            case "n":  out.append("\n"); it = s.index(after: next)
            case let c where leaders.contains(c): out.append(c); it = s.index(after: next)
            default:   out.append(ch);   it = next
            }
        }
        return out
    }
}

/// 選択行への連番付与。開始・増分・桁埋め・区切りをパラメータで受け取る
/// （引数なしの `TextTransform.numberLines` は「開始 1・増分 1・桁埋めなし・タブ区切り」＝既定値）。
enum LineNumberer {
    /// 連番の設定（ダイアログの各項目に 1 対 1 で対応する）。
    struct Options: Equatable {
        /// 最初の行に振る番号。
        var start: Int
        /// 1 行進むごとの増分（負なら減る。0 なら全行が同じ番号）。
        var step: Int
        /// 0 埋めする桁数（0＝埋めない）。負数は符号の後ろを埋める（`-007`）。
        var padWidth: Int
        /// 番号と本文のあいだに置く文字列（`\t` `\n` のエスケープを解いてから使う）。
        var separator: String

        init(start: Int = 1, step: Int = 1, padWidth: Int = 0, separator: String = "\t") {
            self.start = start
            self.step = step
            self.padWidth = padWidth
            self.separator = separator
        }
    }

    /// 選択テキストの各行の先頭に連番を付ける。末尾の改行は保つ。
    static func number(_ s: String, options: Options) -> String {
        let separator = TextEscape.unescape(options.separator)
        let hasTrailingNewline = s.hasSuffix("\n")
        var lines = s.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }

        var n = options.start
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            out.append(pad(n, width: options.padWidth) + separator + line)
            // 桁あふれで落ちないよう飽和加算にする（極端な増分を入れられても壊れない）。
            n = n.addingReportingOverflow(options.step).partialValue
        }
        return out.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
    }

    /// 数値を `width` 桁へ 0 埋めする（負数は `-` の後ろを埋める）。
    private static func pad(_ n: Int, width: Int) -> String {
        let digits = String(n.magnitude)
        let sign = n < 0 ? "-" : ""
        guard width > digits.count else { return sign + digits }
        return sign + String(repeating: "0", count: width - digits.count) + digits
    }
}
