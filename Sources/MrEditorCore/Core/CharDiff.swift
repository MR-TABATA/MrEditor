import Foundation

/// 変更行の「行内のどこが変わったか」。
///
/// ログの 1 文字違い（status=200 → status=500、latency=42ms → 43ms）を見つけるのが本命なので、
/// 行を赤く塗るだけでは足りない。**変更行に限って**文字単位で差分を取る。
///
/// 対象は画面に出ている変更行だけ（数十行）なので、素朴な DP で足りる。
/// 長すぎる行は諦めて行全体を変更扱いにする（1 行 10 万文字の DP を回すほうが害）。
enum CharDiff {

    /// この長さを超える行は、行内差分を取らない（左右とも丸ごと変更として塗る）。
    static let maxLineLength = 2_000

    /// 左右の行を比べ、**左で消えた範囲**と**右で足された範囲**を返す。
    /// 範囲は Character 単位（絵文字や結合文字を割らない）。
    static func ranges(left: String, right: String) -> (left: [Range<Int>], right: [Range<Int>]) {
        let a = Array(left), b = Array(right)
        if a.count > maxLineLength || b.count > maxLineLength {
            return (a.isEmpty ? [] : [0..<a.count], b.isEmpty ? [] : [0..<b.count])
        }

        // 共通の先頭・末尾を落とす。ログの行は大半が共通なので、これだけで DP がほぼ消える。
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p && s < b.count - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }

        let aMid = Array(a[p..<(a.count - s)])
        let bMid = Array(b[p..<(b.count - s)])
        if aMid.isEmpty && bMid.isEmpty { return ([], []) }
        if aMid.isEmpty { return ([], [p..<(p + bMid.count)]) }
        if bMid.isEmpty { return ([p..<(p + aMid.count)], []) }

        // 中央だけ LCS。
        let n = aMid.count, m = bMid.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = aMid[i] == bMid[j] ? dp[i + 1][j + 1] + 1
                                              : max(dp[i + 1][j], dp[i][j + 1])
            }
        }

        var lOut: [Range<Int>] = [], rOut: [Range<Int>] = []
        var i = 0, j = 0
        var lRun: Int? = nil, rRun: Int? = nil
        func closeL(_ end: Int) { if let s0 = lRun { lOut.append((p + s0)..<(p + end)); lRun = nil } }
        func closeR(_ end: Int) { if let s0 = rRun { rOut.append((p + s0)..<(p + end)); rRun = nil } }

        while i < n && j < m {
            if aMid[i] == bMid[j] {
                closeL(i); closeR(j)
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                if lRun == nil { lRun = i }
                i += 1
            } else {
                if rRun == nil { rRun = j }
                j += 1
            }
        }
        closeL(i); closeR(j)
        if i < n { lOut.append((p + i)..<(p + n)) }
        if j < m { rOut.append((p + j)..<(p + m)) }
        return (lOut, rOut)
    }
}
