import Foundation

/// 並べて見るときの 1 行（左右のどちらか、または両方）。
struct DiffRow {
    enum Kind { case equal, delete, insert, replace }
    let kind: Kind
    /// 左ファイルの行番号（0 始まり）。右にしか無い行では nil＝左は空白で埋める。
    let left: Int?
    /// 右ファイルの行番号（0 始まり）。左にしか無い行では nil。
    let right: Int?
}

/// diff の表示モデル。
///
/// **行を実体化しない。** 8,600 万行の diff で `[DiffRow]` を作ると、それだけで 1GB を超えて
/// 「本文は抱えない」という設計と矛盾する。持つのは差分の手（ops）とその累積行数だけで、
/// 画面に出る行だけを二分探索でその場に組み立てる。ops の数は差分の塊の数なので、たかが知れている。
struct DiffModel {
    let ops: [DiffOp]
    /// ops[i] までの累積表示行数。二分探索用。
    private let cumulative: [Int]
    /// 並べたときの総行数。
    let rowCount: Int
    /// 差分の塊の先頭行（「次の差分へ」で飛ぶ先）。
    let hunkStarts: [Int]

    init(ops: [DiffOp]) {
        self.ops = ops
        var cum: [Int] = []
        var hunks: [Int] = []
        var total = 0
        var prevWasDiff = false
        cum.reserveCapacity(ops.count)
        for op in ops {
            let isDiff: Bool
            let rows: Int
            switch op {
            case let .equal(_, _, c):                       rows = c; isDiff = false
            case let .delete(_, c):                         rows = c; isDiff = true
            case let .insert(_, c):                         rows = c; isDiff = true
            case let .replace(_, lc, _, rc):                rows = max(lc, rc); isDiff = true
            }
            if isDiff && !prevWasDiff { hunks.append(total) }
            prevWasDiff = isDiff
            total += rows
            cum.append(total)
        }
        self.cumulative = cum
        self.rowCount = total
        self.hunkStarts = hunks
    }

    var isIdentical: Bool { ops.count == 1 && ops.first.map { if case .equal = $0 { return true } else { return false } } == true }

    /// 差分のある行数（変更・追加・削除の合計。ステータス表示用）。
    var changedRowCount: Int {
        ops.reduce(0) { acc, op in
            switch op {
            case .equal: return acc
            case let .delete(_, c): return acc + c
            case let .insert(_, c): return acc + c
            case let .replace(_, lc, _, rc): return acc + max(lc, rc)
            }
        }
    }

    /// 表示行 row が、左右のどの行に当たるか。O(log ops)。
    func row(at row: Int) -> DiffRow? {
        guard row >= 0, row < rowCount else { return nil }
        // cumulative は単調増加。row < cumulative[i] となる最小の i を探す。
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= row { lo = mid + 1 } else { hi = mid }
        }
        let base = lo == 0 ? 0 : cumulative[lo - 1]
        let offset = row - base
        switch ops[lo] {
        case let .equal(l, r, _):
            return DiffRow(kind: .equal, left: l + offset, right: r + offset)
        case let .delete(l, _):
            return DiffRow(kind: .delete, left: l + offset, right: nil)
        case let .insert(r, _):
            return DiffRow(kind: .insert, left: nil, right: r + offset)
        case let .replace(l, lc, r, rc):
            return DiffRow(kind: .replace,
                           left: offset < lc ? l + offset : nil,
                           right: offset < rc ? r + offset : nil)
        }
    }

    /// row 以降で最初の差分の先頭。無ければ nil。
    func nextHunk(after row: Int) -> Int? { hunkStarts.first { $0 > row } }
    /// row より前で最後の差分の先頭。
    func previousHunk(before row: Int) -> Int? { hunkStarts.last { $0 < row } }
}
