import Foundation

/// 一致行の前後 N 行を表示に足す（`grep -C` 相当）。
///
/// 絞り込みは「その行だけ」を見せるが、調査は往復する。エラー行の直前に何が起きたか、
/// 直後にどう転んだかは、たいてい隣の行にある。前後が見えないと絞り込んだ瞬間に
/// 文脈を失い、フィルタを解除して行番号を頼りに探し直すことになる。
///
/// 出力は **昇順・重複なし**。一致が近いと窓が重なるので、単純に足すのではなく
/// 走査済みの位置（`next`）から先だけを足して潰す（`grep` が `--` で区切って
/// まとめるのと同じ考え方）。区切り線は入れない——行番号のガターに元の行番号が
/// 出ているので、飛んでいることはそこで分かる。
enum FilterContext {
    /// 前後に出せる行数の上限（UI 側の入力もここで丸める）。
    static let maxContext = 100

    /// 展開後の表示行数の上限。一致行そのものが `SearchEngine` の 100 万件で
    /// 打ち切られているので、その先の展開でメモリを増やしても意味がない。
    /// （100 万件 × 前後 100 行＝2 億行分の配列＝1.6GB。ここで止める。）
    static let displayCap = 1_000_000

    /// `matches`（昇順・0 始まり）に前後 `context` 行を足した表示行の並びを返す。
    /// `context` が 0 なら `matches` をそのまま返す（配列を作り直さない）。
    static func expand(matches: [Int], context: Int, lineCount: Int) -> [Int] {
        guard context > 0, !matches.isEmpty, lineCount > 0 else { return matches }
        var out: [Int] = []
        out.reserveCapacity(min(matches.count * (2 * context + 1), displayCap))
        var next = 0                       // まだ出していない最小の行（重複を潰す境界）
        for m in matches {
            let lo = max(m - context, next, 0)
            let hi = min(m + context, lineCount - 1)
            guard lo <= hi else { continue }   // 窓が丸ごと既出／範囲外
            for line in lo...hi {
                out.append(line)
                if out.count >= displayCap { return out }
            }
            next = hi + 1
        }
        return out
    }
}
