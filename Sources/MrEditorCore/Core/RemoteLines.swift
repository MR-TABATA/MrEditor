import Foundation

/// 遠隔で見る 1 行。**本文は既に手元にある**（tail で取ったバイトか、grep が返した行）。
///
/// 行番号が `nil` なのは「まだ数えていない」。**0 とも 1 とも書かない** ――
/// 遠隔の総行数は `wc -l` で後から埋まるので、それまでは分からないと言う。
public struct RemoteLine: Equatable {
    /// 1 始まり（grep と `wc -l` の流儀）。数えていなければ nil。
    public let number: Int?
    /// 検索の当たりか。`grep -C` で付いてきた前後の行は false。
    public let isMatch: Bool
    public let text: String

    public init(number: Int?, isMatch: Bool, text: String) {
        self.number = number
        self.isMatch = isMatch
        self.text = text
    }
}

/// 遠隔から来たバイト列・grep 出力を、画面に並べる行へ直す。
///
/// **索引を作らない。** 遠隔で見たいのは「末尾」と「絞り込みの結果」で、
/// どちらも**行番号と本文が既に揃っている**（tail は取ったバイトを改行で割るだけ、
/// grep は行番号つきで返る）。だから全体を舐める行インデックスが要らない。
/// これが B 案（遠隔は別の面）の土台。
public enum RemoteLines {

    /// 末尾から取ったバイト列を行に割る。
    ///
    /// - `endsAtByte`: この塊の最後がファイル全体の何バイト目か（＝ふつうは総サイズ）。
    /// - `totalLines`: `wc -l` の結果。分かっていれば**後ろから番号を振る**。
    ///
    /// **先頭の欠けた行は捨てる。** `tail -c` はバイトで切るので、最初の行は途中から
    /// 始まっていることがある。半端な行を「1 行」として見せると、**そこだけ本文が
    /// 欠けたまま、それらしく読めてしまう。**
    public static func fromTail(
        _ data: Data,
        endsAtByte: Int,
        totalLines: Int?,
        droppedLeadingPartial: inout Bool
    ) -> [RemoteLine] {
        droppedLeadingPartial = false
        guard !data.isEmpty else { return [] }

        var text = String(decoding: data, as: UTF8.self)

        // 末尾の改行は「空の最終行」を作らないよう先に落とす
        let endedWithNewline = text.hasSuffix("\n")
        if endedWithNewline { text.removeLast() }

        var parts = text.components(separatedBy: "\n")

        // ファイルの途中から切り出したなら、先頭の行は欠けている可能性がある
        if endsAtByte > data.count, parts.count > 1 {
            parts.removeFirst()
            droppedLeadingPartial = true
        }
        guard !parts.isEmpty else { return [] }

        // 後ろから番号を振る。総行数が分かっていなければ nil のまま。
        var numbers = [Int?](repeating: nil, count: parts.count)
        if let total = totalLines {
            // `wc -l` は改行の数。末尾に改行が無ければ最終行が 1 本多い。
            let lastNumber = endedWithNewline ? total : total + 1
            for i in stride(from: parts.count - 1, through: 0, by: -1) {
                let n = lastNumber - (parts.count - 1 - i)
                numbers[i] = n > 0 ? n : nil
            }
        }

        return parts.enumerated().map {
            RemoteLine(number: numbers[$0.offset], isMatch: false, text: $0.element)
        }
    }

    /// `grep -n` の結果を並べる行へ。**行番号は grep が返したものをそのまま使う。**
    public static func fromMatches(_ matches: [RemoteFile.Match]) -> [RemoteLine] {
        matches.map { RemoteLine(number: $0.line, isMatch: $0.isMatch, text: $0.text) }
    }

    /// 選んだ行を、そのまま貼れる形にする。
    ///
    /// **クリップボードが、遠隔と手元の継ぎ目。** ここで絞った結果をコピーして、
    /// 手元の文書やクリップボード比較（⇧⌘D の入口）へ持っていける ――
    /// 遠隔の面を別に建てても、既にある道具と繋がるのはこのため。
    ///
    /// 行番号は**付けない**のが既定。付けると貼った先で本文ではなくなり、
    /// diff にかけたときに全行が差分になる。
    public static func plainText(_ lines: [RemoteLine], withNumbers: Bool = false) -> String {
        lines.map { line in
            guard withNumbers, let n = line.number else { return line.text }
            return "\(n):\(line.text)"
        }.joined(separator: "\n")
    }
}
