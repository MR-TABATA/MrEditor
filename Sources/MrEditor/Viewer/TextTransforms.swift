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
    case reverseLines
    case numberLines

    /// ケース変換グループ（書式メニューの第1グループ）。
    static let caseGroup: [TextTransform] = [.uppercase, .lowercase, .titlecase, .togglecase]
    /// エンコード／デコードグループ（第2グループ）。
    static let encodingGroup: [TextTransform] = [.urlEncode, .urlDecode, .base64Encode, .base64Decode, .htmlEncode, .htmlDecode]
    /// 行操作グループ（第3グループ）。
    static let lineGroup: [TextTransform] = [.sortAscending, .sortDescending, .uniqueLines, .reverseLines, .numberLines]

    /// メニュー項目のローカライズキー。
    var localizationKey: String {
        switch self {
        case .uppercase:      return "menu.format.uppercase"
        case .lowercase:      return "menu.format.lowercase"
        case .titlecase:      return "menu.format.titlecase"
        case .togglecase:     return "menu.format.togglecase"
        case .urlEncode:      return "menu.format.urlEncode"
        case .urlDecode:      return "menu.format.urlDecode"
        case .base64Encode:   return "menu.format.base64Encode"
        case .base64Decode:   return "menu.format.base64Decode"
        case .htmlEncode:     return "menu.format.htmlEncode"
        case .htmlDecode:     return "menu.format.htmlDecode"
        case .sortAscending:  return "menu.format.sortAscending"
        case .sortDescending: return "menu.format.sortDescending"
        case .uniqueLines:    return "menu.format.uniqueLines"
        case .reverseLines:   return "menu.format.reverseLines"
        case .numberLines:    return "menu.format.numberLines"
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
        case .sortAscending:  return Self.sortLines(s, by: <)
        case .sortDescending: return Self.sortLines(s, by: >)
        case .uniqueLines:    return Self.uniqueLines(s)
        case .reverseLines:   return Self.mapLines(s) { Array($0.reversed()) }
        case .numberLines:    return Self.numberLines(s)
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

    /// 各行の先頭に 1 始まりの連番＋タブを付ける。
    private static func numberLines(_ s: String) -> String {
        let (lines, trailing) = splitLines(s)
        let numbered = lines.enumerated().map { "\($0.offset + 1)\t\($0.element)" }
        return joinLines(numbered, trailingNewline: trailing)
    }
}
