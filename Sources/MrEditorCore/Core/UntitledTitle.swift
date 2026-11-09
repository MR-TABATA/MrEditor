import Foundation

/// 未保存の新規ドキュメントのタブ名を、本文の先頭行から作る。
/// 「名称未設定」のタブがいくつも並んでも、中身で見分けられるようにする（要望 #133）。
enum UntitledTitle {
    /// 表示の最大文字数。これを超える行は「…」で切る。
    static let maxLength = 24
    /// 先頭から見る範囲。巨大な貼り付けでも、全体は走査しない。
    static let scanLimit = 1024

    /// サイドバー・タイトルバーの名前。保存先があればファイル名、なければ先頭行の名前、本文が空なら「名称未設定」。
    static func displayName(fileName: String?, autoTitle: String?, untitled: String) -> String {
        fileName ?? autoTitle ?? untitled
    }

    /// `make(from: String)` と同じ結果を、`NSString` から安く作る（打鍵のたびに呼ばれるため）。
    /// 先頭の「中身のある行」の終わりまでだけを走査して、その 1 行だけを取り出す。
    /// 先頭 `scanLimit` を超えては読まず、本文全体や、先頭 1024 文字の複製は作らない。
    static func make(from storage: NSString) -> String? {
        let limit = min(storage.length, scanLimit)
        var lineStart = 0
        while lineStart < limit {
            var cursor = lineStart
            var hasContent = false
            while cursor < limit {
                let unit = storage.character(at: cursor)
                if isLineBreak(unit) { break }
                if !hasContent, !isWhitespace(unit) { hasContent = true }
                cursor += 1
            }
            if hasContent {
                return make(from: storage.substring(with: NSRange(location: lineStart, length: cursor - lineStart)))
            }
            // 空白だけの行は飛ばす（CR LF は 1 つの改行として数える）。
            let isCRLF = cursor + 1 < limit
                && storage.character(at: cursor) == 0x0D
                && storage.character(at: cursor + 1) == 0x0A
            lineStart = cursor + (isCRLF ? 2 : 1)
        }
        return nil
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x85 || unit == 0x2028 || unit == 0x2029
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }   // 単独のサロゲートは文字として扱う
        return scalar.properties.isWhitespace
    }

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
