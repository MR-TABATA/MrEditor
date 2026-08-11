import Foundation

/// 行のハッシュ。**128 ビット**にしてある。
///
/// 64 ビットだと 8,600 万行で誕生日衝突が 10^-4 オーダーに乗る。diff で衝突が起きると
/// 「違う行を同じと言う」＝**黙って差分を見落とす**ことになり、閲覧側の「落とさない」より
/// たちが悪い。16 バイト/行のコストを払って潰す（10GB・86,420,337 行で 1.4GB）。
struct LineHash: Hashable {
    let a: UInt64
    let b: UInt64
}

/// diff の 1 手。行の範囲で表す。
enum DiffOp: Equatable {
    /// 両方に同じ行が count 行続く。
    case equal(left: Int, right: Int, count: Int)
    /// 左にしかない（削除）。
    case delete(left: Int, count: Int)
    /// 右にしかない（追加）。
    case insert(right: Int, count: Int)
    /// 置き換え（左の一塊が右の一塊になった）。行内差分はこのブロックの中で取る。
    case replace(left: Int, leftCount: Int, right: Int, rightCount: Int)
}

/// 行単位の diff。
///
/// **patience diff**（両側で 1 回しか出てこない行＝アンカーを見つけ、その間を再帰）を採る。
/// 巨大なログで Myers を素直に回すと O(ND) が破裂するが、patience は
///   - 共通の先頭・末尾を落とす（ログは大抵ここで大半が消える）
///   - アンカー間の小さな区間だけを詳しく見る
/// ので、メモリも時間も行数に対してほぼ線形に収まる。
///
/// アンカーが 1 つも無い区間（全行が重複だらけ、等）は、区間が小さければ Myers、
/// 大きければ丸ごと replace として畳む（**嘘をつかず、諦めたことが分かる形**にする）。
enum LineDiff {

    /// アンカーが無い区間に Myers を回してよい上限（左右の行数の積）。
    /// これを超えたら 1 個の replace に畳む。
    static let myersCellBudget = 4_000_000

    static func compute(_ left: [LineHash], _ right: [LineHash]) -> [DiffOp] {
        var ops: [DiffOp] = []
        diff(left, right, 0..<left.count, 0..<right.count, into: &ops)
        return coalesce(ops)
    }

    // MARK: - 本体

    private static func diff(_ l: [LineHash], _ r: [LineHash],
                            _ lr: Range<Int>, _ rr: Range<Int>,
                            into ops: inout [DiffOp]) {
        var lo = lr, ro = rr

        // 共通の先頭
        var prefix = 0
        while lo.lowerBound + prefix < lo.upperBound,
              ro.lowerBound + prefix < ro.upperBound,
              l[lo.lowerBound + prefix] == r[ro.lowerBound + prefix] {
            prefix += 1
        }
        if prefix > 0 {
            ops.append(.equal(left: lo.lowerBound, right: ro.lowerBound, count: prefix))
            lo = (lo.lowerBound + prefix)..<lo.upperBound
            ro = (ro.lowerBound + prefix)..<ro.upperBound
        }

        // 共通の末尾
        var suffix = 0
        while lo.upperBound - suffix - 1 >= lo.lowerBound,
              ro.upperBound - suffix - 1 >= ro.lowerBound,
              l[lo.upperBound - suffix - 1] == r[ro.upperBound - suffix - 1] {
            suffix += 1
        }
        let lMid = lo.lowerBound..<(lo.upperBound - suffix)
        let rMid = ro.lowerBound..<(ro.upperBound - suffix)

        emitMiddle(l, r, lMid, rMid, into: &ops)

        if suffix > 0 {
            ops.append(.equal(left: lo.upperBound - suffix, right: ro.upperBound - suffix, count: suffix))
        }
    }

    private static func emitMiddle(_ l: [LineHash], _ r: [LineHash],
                                   _ lr: Range<Int>, _ rr: Range<Int>,
                                   into ops: inout [DiffOp]) {
        if lr.isEmpty && rr.isEmpty { return }
        if lr.isEmpty { ops.append(.insert(right: rr.lowerBound, count: rr.count)); return }
        if rr.isEmpty { ops.append(.delete(left: lr.lowerBound, count: lr.count)); return }

        // アンカー = 左右それぞれで 1 回だけ出てくる、共通の行。
        guard let anchors = uniqueAnchors(l, r, lr, rr), !anchors.isEmpty else {
            // アンカー無し。小さければ Myers、大きければ諦めて replace。
            if lr.count * rr.count <= myersCellBudget {
                myers(l, r, lr, rr, into: &ops)
            } else {
                ops.append(.replace(left: lr.lowerBound, leftCount: lr.count,
                                    right: rr.lowerBound, rightCount: rr.count))
            }
            return
        }

        // アンカー列（左昇順・右も昇順になるよう LIS で選抜済み）で区切って再帰。
        var lPos = lr.lowerBound
        var rPos = rr.lowerBound
        for (li, ri) in anchors {
            diff(l, r, lPos..<li, rPos..<ri, into: &ops)
            ops.append(.equal(left: li, right: ri, count: 1))
            lPos = li + 1
            rPos = ri + 1
        }
        diff(l, r, lPos..<lr.upperBound, rPos..<rr.upperBound, into: &ops)
    }

    /// 左右それぞれの区間で出現回数 1、かつ両方に在る行を拾い、
    /// 右のインデックスが増加する最長列（LIS）だけ残す＝交差しないアンカー列。
    private static func uniqueAnchors(_ l: [LineHash], _ r: [LineHash],
                                      _ lr: Range<Int>, _ rr: Range<Int>) -> [(Int, Int)]? {
        var lCount: [LineHash: Int] = [:]
        var lWhere: [LineHash: Int] = [:]
        lCount.reserveCapacity(lr.count)
        for i in lr {
            lCount[l[i], default: 0] += 1
            lWhere[l[i]] = i
        }
        var rCount: [LineHash: Int] = [:]
        var rWhere: [LineHash: Int] = [:]
        rCount.reserveCapacity(rr.count)
        for i in rr {
            rCount[r[i], default: 0] += 1
            rWhere[r[i]] = i
        }

        var pairs: [(Int, Int)] = []
        for (h, c) in lCount where c == 1 {
            if rCount[h] == 1, let li = lWhere[h], let ri = rWhere[h] {
                pairs.append((li, ri))
            }
        }
        if pairs.isEmpty { return nil }
        pairs.sort { $0.0 < $1.0 }

        // 右インデックスの LIS（狭義単調増加）。
        var tails: [Int] = []          // tails[k] = 長さ k+1 の列の末尾の「右index」
        var tailIdx: [Int] = []        // その pairs 上の位置
        var prev = [Int](repeating: -1, count: pairs.count)
        for (i, p) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if tails[mid] < p.1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[i] = tailIdx[lo - 1] }
            if lo == tails.count { tails.append(p.1); tailIdx.append(i) }
            else { tails[lo] = p.1; tailIdx[lo] = i }
        }
        var out: [(Int, Int)] = []
        var k = tails.isEmpty ? -1 : tailIdx[tails.count - 1]
        while k >= 0 { out.append(pairs[k]); k = prev[k] }
        out.reverse()
        return out
    }

    /// 小さい区間だけに使う Myers（O(ND)）。区間の外へは出ない。
    private static func myers(_ l: [LineHash], _ r: [LineHash],
                              _ lr: Range<Int>, _ rr: Range<Int>,
                              into ops: inout [DiffOp]) {
        let n = lr.count, m = rr.count
        // 素朴な LCS（DP）。myersCellBudget で面積を抑えてあるので現実的。
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = (l[lr.lowerBound + i] == r[rr.lowerBound + j])
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < n && j < m {
            if l[lr.lowerBound + i] == r[rr.lowerBound + j] {
                ops.append(.equal(left: lr.lowerBound + i, right: rr.lowerBound + j, count: 1))
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.delete(left: lr.lowerBound + i, count: 1)); i += 1
            } else {
                ops.append(.insert(right: rr.lowerBound + j, count: 1)); j += 1
            }
        }
        if i < n { ops.append(.delete(left: lr.lowerBound + i, count: n - i)) }
        if j < m { ops.append(.insert(right: rr.lowerBound + j, count: m - j)) }
    }

    // MARK: - 整形

    /// 連続する同種の手をまとめ、隣り合う delete+insert は replace に畳む
    /// （「消して足した」より「書き換わった」と見せたほうが読める。行内差分もここに効く）。
    static func coalesce(_ ops: [DiffOp]) -> [DiffOp] {
        var merged: [DiffOp] = []
        for op in ops {
            guard let last = merged.last else { merged.append(op); continue }
            switch (last, op) {
            case let (.equal(l1, r1, c1), .equal(l2, r2, c2)) where l1 + c1 == l2 && r1 + c1 == r2:
                merged[merged.count - 1] = .equal(left: l1, right: r1, count: c1 + c2)
            case let (.delete(l1, c1), .delete(l2, c2)) where l1 + c1 == l2:
                merged[merged.count - 1] = .delete(left: l1, count: c1 + c2)
            case let (.insert(r1, c1), .insert(r2, c2)) where r1 + c1 == r2:
                merged[merged.count - 1] = .insert(right: r1, count: c1 + c2)
            default:
                merged.append(op)
            }
        }

        var out: [DiffOp] = []
        var k = 0
        while k < merged.count {
            if case let .delete(l, lc) = merged[k], k + 1 < merged.count,
               case let .insert(r, rc) = merged[k + 1] {
                out.append(.replace(left: l, leftCount: lc, right: r, rightCount: rc))
                k += 2
            } else if case let .insert(r, rc) = merged[k], k + 1 < merged.count,
                      case let .delete(l, lc) = merged[k + 1] {
                out.append(.replace(left: l, leftCount: lc, right: r, rightCount: rc))
                k += 2
            } else {
                out.append(merged[k])
                k += 1
            }
        }
        return out
    }
}
