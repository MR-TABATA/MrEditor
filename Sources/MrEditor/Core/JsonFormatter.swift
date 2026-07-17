import Foundation

/// 単一 JSON ドキュメントを字下げ整形（pretty-print）する純ロジック（UI 非依存）。
///
/// `JSONSerialization` は辞書のキー順を保たないため、**元テキストをトークナイザで走査して
/// 再インデントする**（キーの出現順・数値/文字列の表記を一切変えない）。整形前に
/// `JSONSerialization` で妥当性だけ検証し、不正なら `nil` を返す（＝呼び出し側は no-op/beep）。
///
/// NDJSON（1 行 1 オブジェクト）は複数トップレベル値なので検証に落ちて `nil` になる。
/// それは行指向の `StructuredMode.ndjson` の担当で、こちらは 1 ドキュメント整形に限定する。
enum JsonFormatter {
    /// 妥当な単一 JSON ならインデント整形した文字列、そうでなければ `nil`。
    /// - Parameter indent: 1 段の字下げに使う文字列（既定 2 スペース）。
    static func pretty(_ text: String, indent: String = "  ") -> String? {
        // 妥当性検証（トップレベルのスカラも許容）。
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return nil
        }
        return reindent(text, indent: indent)
    }

    /// トークナイザで再インデント。文字列内はそのまま複写し、構造文字の外側の空白は捨てる。
    private static func reindent(_ text: String, indent: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count + chars.count / 4)
        var depth = 0
        var i = 0
        let n = chars.count

        func newline(_ d: Int) {
            out.append("\n")
            for _ in 0..<d { out.append(indent) }
        }
        // 次の非空白文字を先読み（空コンテナ判定用）。
        func nextNonSpace(from k: Int) -> Character? {
            var j = k
            while j < n {
                let c = chars[j]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { j += 1; continue }
                return c
            }
            return nil
        }

        while i < n {
            let c = chars[i]
            switch c {
            case " ", "\t", "\n", "\r":
                i += 1   // 構造の外側の空白は捨てる
            case "\"":
                // 文字列はエスケープ込みでそのまま複写。
                out.append(c); i += 1
                while i < n {
                    let s = chars[i]
                    out.append(s)
                    if s == "\\" && i + 1 < n { out.append(chars[i + 1]); i += 2; continue }
                    i += 1
                    if s == "\"" { break }
                }
            case "{", "[":
                if let nxt = nextNonSpace(from: i + 1), nxt == (c == "{" ? "}" : "]") {
                    // 空コンテナは 1 行に。
                    out.append(c); out.append(nxt)
                    // 閉じまで読み飛ばす。
                    var j = i + 1
                    while j < n, chars[j] != nxt { j += 1 }
                    i = j + 1
                } else {
                    depth += 1
                    out.append(c)
                    newline(depth)
                    i += 1
                }
            case "}", "]":
                depth = max(0, depth - 1)
                newline(depth)
                out.append(c)
                i += 1
            case ",":
                // 末尾カンマ（直後が閉じ括弧）は落とす。Foundation は許容するが整形では不要。
                if let nxt = nextNonSpace(from: i + 1), nxt == "}" || nxt == "]" {
                    i += 1
                } else {
                    out.append(c)
                    newline(depth)
                    i += 1
                }
            case ":":
                out.append(": ")
                i += 1
            default:
                out.append(c); i += 1
            }
        }
        return out
    }
}
