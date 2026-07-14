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

    /// スクロールバーに描くための、差分の位置（0...1）と種類。
    /// 差分が数十万箇所ある場合に全部描いても潰れるだけなので、上限で間引く。
    func markers(limit: Int = 600) -> [(position: Double, kind: DiffRow.Kind)] {
        guard rowCount > 0 else { return [] }
        var out: [(Double, DiffRow.Kind)] = []
        var acc = 0
        var diffs: [(Int, DiffRow.Kind)] = []
        for op in ops {
            switch op {
            case let .equal(_, _, c):        acc += c
            case let .delete(_, c):          diffs.append((acc, .delete)); acc += c
            case let .insert(_, c):          diffs.append((acc, .insert)); acc += c
            case let .replace(_, lc, _, rc): diffs.append((acc, .replace)); acc += max(lc, rc)
            }
        }
        let step = max(1, diffs.count / limit)
        for i in Swift.stride(from: 0, to: diffs.count, by: step) {
            out.append((Double(diffs[i].0) / Double(rowCount), diffs[i].1))
        }
        return out
    }

    /// 選択範囲の本文を組む（コピー用）。
    ///
    /// `line(row)` は「その列のその行の文字列。相手側にしか無い行（画面では空白で埋めている行）
    /// なら nil」を返す。**埋め草の行は飛ばす** —— 存在しない行をコピーして空行を混ぜたら、
    /// 貼り付け先で嘘になる。
    func selectedText(from start: (row: Int, idx: Int),
                      to end: (row: Int, idx: Int),
                      line: (Int) -> String?) -> String {
        guard start.row <= end.row, start.row >= 0, end.row < rowCount else { return "" }
        var parts: [String] = []
        for row in start.row...end.row {
            guard let text = line(row) else { continue }      // 埋め草は飛ばす
            let u = Array(text.utf16)
            let from = (row == start.row) ? min(max(0, start.idx), u.count) : 0
            let to   = (row == end.row)   ? min(max(0, end.idx), u.count)   : u.count
            guard from <= to else { continue }
            parts.append(String(utf16CodeUnits: Array(u[from..<to]), count: to - from))
        }
        return parts.joined(separator: "\n")
    }

    /// op `i` が始まる表示行。
    func startRow(ofOp i: Int) -> Int {
        guard i > 0, i <= cumulative.count else { return 0 }
        return cumulative[i - 1]
    }

    /// ハンク `op` の**次の**ハンク（op 添字）。無ければ nil。
    ///
    /// **スクロール位置で探してはいけない。** 最初はそうしていたが、画面に収まる小さな
    /// ファイルでは topRow が 0 のまま動かず、何度押しても同じ差分に戻った（実際に戻った）。
    /// 基準は「いま選んでいるハンク」。
    func hunk(after op: Int?) -> Int? {
        let hunks = hunkOpIndices
        guard let op else { return hunks.first }
        return hunks.first { $0 > op }
    }

    /// ハンク `op` の**前の**ハンク（op 添字）。
    func hunk(before op: Int?) -> Int? {
        let hunks = hunkOpIndices
        guard let op else { return hunks.last }
        return hunks.last { $0 < op }
    }

    // MARK: - マージ

    /// 差分の塊（ハンク）の一覧。`ops` 上の添字で持つ（採用状態の鍵になる）。
    var hunkOpIndices: [Int] {
        ops.enumerated().compactMap { i, op in
            if case .equal = op { return nil }
            return i
        }
    }

    /// 表示行 row を含む op の添字。
    func opIndex(at row: Int) -> Int? {
        guard row >= 0, row < rowCount else { return nil }
        var acc = 0
        for (i, op) in ops.enumerated() {
            let rows: Int
            switch op {
            case let .equal(_, _, c):        rows = c
            case let .delete(_, c):          rows = c
            case let .insert(_, c):          rows = c
            case let .replace(_, lc, _, rc): rows = max(lc, rc)
            }
            if row < acc + rows { return i }
            acc += rows
        }
        return nil
    }

    /// マージ結果を書き出す。
    ///
    /// **左が土台。** `adopted` に入っている op（ハンク）だけ、右の内容を採る。
    /// 入っていないハンクは左のまま。
    ///   - equal   : 左をそのまま
    ///   - replace : 採用なら右、でなければ左
    ///   - insert  : 右にしかない行。採用なら足す、でなければ足さない
    ///   - delete  : 左にしかない行。採用なら**落とす**（右で消えたのを取り込む）、でなければ残す
    ///
    /// **本文をメモリに載せない。** ソースから直接バイトを流すので、10GB でも成立する。
    func writeMerged(left: DiffSource, right: DiffSource, adopted: Set<Int>,
                     eol: [UInt8], to out: FileHandle) throws {
        for (i, op) in ops.enumerated() {
            let take = adopted.contains(i)
            switch op {
            case let .equal(l, _, c):
                try left.writeLines(from: l, count: c, eol: eol, to: out)
            case let .replace(l, lc, r, rc):
                if take { try right.writeLines(from: r, count: rc, eol: eol, to: out) }
                else    { try left.writeLines(from: l, count: lc, eol: eol, to: out) }
            case let .insert(r, c):
                if take { try right.writeLines(from: r, count: c, eol: eol, to: out) }
            case let .delete(l, c):
                if !take { try left.writeLines(from: l, count: c, eol: eol, to: out) }
            }
        }
    }
}
