import Foundation

/// 桁ガイドの割り付けに、行を揃える（UI 非依存の純ロジック）。
///
/// **1 行目を Tab で整えたら、その桁割りを残り全部に当てられる。** これが無いと、
/// 桁を決めた後に何百行を手で揃えることになり、結局 `awk` や `column -t` を開く羽目になる。
///
/// 項目の切れ目は**空白の並び**で見る（固定長にする前のデータは、たいてい空白かタブで
/// 区切られている）。切れ目そのものは `ColumnGuides` が持っているので、ここは
/// 「何桁目に置くか」だけを受け取る。
enum ColumnAlign {
    /// 桁を数える単位は**表示幅**（全角＝2）。文字数で詰めると全角の行だけ揃わない。
    private static func width(_ s: String) -> Int { TabularFormatter.displayWidth(s) }

    /// `text` の各行を、`fieldStarts`（1 始まりの桁・昇順）へ揃える。
    ///
    /// - 空白／タブの並びで項目に割り、i 番目の項目を `fieldStarts[i]` 桁目から置く。
    /// - **字は消さない。** 前の項目がその桁を越えていたら、空白 1 つだけ空けて続ける
    ///   （桁は崩れるが、消えるよりはるかにまし。崩れた行は見れば分かる）。
    /// - 項目が定義より多ければ、余りは空白 1 つ区切りで後ろに続ける。
    /// - 空行と、空白だけの行はそのまま。
    /// - 行末の空白は落とす（詰めた結果の余りを残さない）。改行の種類と有無は保つ。
    static func align(_ text: String, to fieldStarts: [Int]) -> String {
        let starts = fieldStarts.filter { $0 >= 1 }.sorted()
        guard !starts.isEmpty else { return text }
        // 改行で分けても、行末の改行の有無を保てるように components を使う。
        let lines = text.components(separatedBy: "\n")
        return lines.map { alignLine($0, to: starts) }.joined(separator: "\n")
    }

    /// 1 行を揃える。`\r`（CRLF の名残）は触らずに末尾へ残す。
    static func alignLine(_ line: String, to starts: [Int]) -> String {
        let hasCR = line.hasSuffix("\r")
        let body = hasCR ? String(line.dropLast()) : line
        let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return line }          // 空行・空白だけの行はそのまま

        var out = ""
        var column = 1                                       // いま書き込む桁（1 始まり）
        for (i, token) in tokens.enumerated() {
            let target = i < starts.count ? starts[i] : column + 1   // 定義より多い項目は 1 空けて続ける
            if target > column {
                out += String(repeating: " ", count: target - column)
                column = target
            } else if i > 0 {
                out += " "                                   // 前の項目が越えている＝最低 1 つ空ける
                column += 1
            }
            out += token
            column += width(token)
        }
        return out + (hasCR ? "\r" : "")
    }
}
