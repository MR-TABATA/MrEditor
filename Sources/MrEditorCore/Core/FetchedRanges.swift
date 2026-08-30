import Foundation

/// 疎なキャッシュの、**どこまで取ってきたか**。
///
/// 遠隔のファイルは手元に疎ファイルとして置き、見たところだけを埋める（範囲読み）。
/// 疎ファイルの穴は **mmap するとゼロとして読めてしまう** ので、
/// 「まだ取っていない」と「本当に 0x00 が入っている」を、これで区別する。
///
/// **ここを間違えると、被害は「開けない」ではなく「本文の一部が静かにゼロで埋まる」。**
/// 10GB のログのど真ん中が 0 で埋まっていても、画面はそれらしく描いてしまう。
/// だから読み取りの経路は必ずここを通し、欠けていれば取りに行く。
///
/// 区間は**正規化して持つ**（重なりなし・昇順・隣接は連結）。連結までするのは、
/// スクロールで 4KB ずつ埋めていくと区間が数万に増え、探索が線形に効いてくるため。
struct FetchedRanges: Equatable {

    /// 重なりなし・昇順・隣接連結済み。空区間は持たない。
    private(set) var ranges: [Range<Int>] = []

    init() {}

    init(_ initial: [Range<Int>]) {
        for r in initial { insert(r) }
    }

    /// 取得済みとして記録する。重なり・隣接は畳む。
    mutating func insert(_ range: Range<Int>) {
        guard !range.isEmpty else { return }

        var merged = range
        var out: [Range<Int>] = []
        out.reserveCapacity(ranges.count + 1)

        for r in ranges {
            if r.upperBound < merged.lowerBound {
                out.append(r)                 // まだ手前
            } else if merged.upperBound < r.lowerBound {
                out.append(merged)            // ここに挟まる
                merged = r
            } else {
                // 重なるか隣接する（`<` ではなく `<=` の関係）＝ 畳む
                merged = min(r.lowerBound, merged.lowerBound)..<max(r.upperBound, merged.upperBound)
            }
        }
        out.append(merged)
        ranges = out
    }

    /// その範囲が丸ごと取得済みか。
    func contains(_ range: Range<Int>) -> Bool {
        missing(in: range).isEmpty
    }

    /// その範囲のうち、**まだ取っていないところ**。昇順・重なりなし。
    ///
    /// 返ってきた区間だけを取りに行けばよく、既に持っているところは再取得しない
    /// （スクロールで行き来するたびに同じバイトを引き直すと、範囲読みの意味が薄れる）。
    func missing(in range: Range<Int>) -> [Range<Int>] {
        guard !range.isEmpty else { return [] }

        var gaps: [Range<Int>] = []
        var cursor = range.lowerBound

        for r in ranges {
            if r.upperBound <= cursor { continue }        // まだ手前
            if r.lowerBound >= range.upperBound { break }  // もう先

            if r.lowerBound > cursor {
                gaps.append(cursor..<min(r.lowerBound, range.upperBound))
            }
            cursor = max(cursor, r.upperBound)
            if cursor >= range.upperBound { return gaps }
        }

        if cursor < range.upperBound { gaps.append(cursor..<range.upperBound) }
        return gaps
    }

    /// 取得済みの合計バイト数。「10GB のうち 3MB だけ取ってある」を人に見せるため。
    var fetchedBytes: Int {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// ファイルが伸びた・入れ替わった等でキャッシュを捨てるとき。
    mutating func removeAll() { ranges.removeAll() }
}
