import Foundation

/// 未保存の新規ドキュメントのタブ名を、本文の先頭行から作る。
/// 「名称未設定」のタブがいくつも並んでも、中身で見分けられるようにする（要望 #133）。
enum UntitledTitle {
    /// 表示の最大文字数。これを超える行は「…」で切る。
    static let maxLength = 24
    /// 先頭から見る範囲。巨大な貼り付けでも、全体は走査しない。
    static let scanLimit = 1024

    /// 先頭の空でない行を、連続する空白を 1 つに詰めて、短くしたもの。
    /// 本文が空、または空白・改行だけのときは nil（呼び出し側は「名称未設定」のままにする）。
    static func make(from text: String) -> String? {
        for line in text.prefix(scanLimit).split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            if words.isEmpty { continue }
            let collapsed = words.joined(separator: " ")
            return collapsed.count <= maxLength ? collapsed : String(collapsed.prefix(maxLength)) + "…"
        }
        return nil
    }
}
