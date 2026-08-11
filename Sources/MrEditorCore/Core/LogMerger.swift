import Foundation

/// 複数のログを1本の時系列に束ねる純ロジック（UI 非依存・ファイル I/O 非依存）。
///
/// `sort -m` で済まない理由がこの型の存在理由なので、そこだけ書いておく。
///
/// - **時刻を持たない行がある。** スタックトレースの続きや SQL の複数行ダンプは
///   時刻を持たない。素朴に行単位で並べ替えると、これらが親の行から引き剥がされて
///   全体に散らばる。ここでは**直前の時刻を引き継ぐ**（`effectiveTimes`）ことで、
///   継続行が必ず親の直後に残るようにしている。
/// - **同時刻が大量に出る。** 秒までしか無い形式では同じ時刻の行が普通に何十行も
///   並ぶ。並べ替えが不安定だと、開くたびに順番が変わる。ここでは
///   （時刻 → ソース番号 → 行番号）で全順序を作り、**常に同じ結果**にしている。
/// - **ホストごとに時計がずれている。** NTP がずれた1台があると因果が逆転して見える。
///   `clockOffset` でソース単位に補正する。
///
/// 行本文は持たない。`Entry` はどのソースの何行目かだけを指し、本文の取得は呼び出し
/// 側に任せる。巨大ファイルを丸ごとメモリに載せないための境界。
struct LogMerger {
    /// 束ねる対象1本ぶん。
    struct Source {
        /// 表示名（`web-1` など）。
        let label: String
        /// 行ごとの「その行自身が持っていた」時刻。持たない行は `nil`。
        let times: [Date?]
        /// この系の時計ずれ補正（秒）。`+1.5` なら記録時刻を 1.5 秒進める。
        let clockOffset: TimeInterval

        init(label: String, times: [Date?], clockOffset: TimeInterval = 0) {
            self.label = label
            self.times = times
            self.clockOffset = clockOffset
        }
    }

    /// 束ねた結果の1行。
    struct Entry: Equatable {
        /// `sources` の添字。
        let source: Int
        /// そのソース内の行番号（0 始まり）。
        let line: Int
        /// 並べ替えに使った実効時刻（補正済み）。全く時刻の無いソースでは `nil`。
        let time: Date?
        /// その行自身が時刻を持っていたか。`false` は継続行＝画面では時刻を出さない。
        let hasOwnTimestamp: Bool
    }

    /// 行ごとの実効時刻を求める。**入力と同じ本数を必ず返す。**
    ///
    /// - 時刻を持つ行はその時刻（＋`clockOffset`）。
    /// - 持たない行は**直前の時刻を引き継ぐ**（継続行を親から離さないため）。
    /// - 先頭にある時刻を持たない行（見出し・バナー）は、**最初に現れる時刻**を借りる。
    ///   これが無いとファイル冒頭の数行だけ行き場を失う。
    /// - 1つも時刻が無いソースは全行 `nil`。
    static func effectiveTimes(_ times: [Date?], clockOffset: TimeInterval = 0) -> [Date?] {
        var out = [Date?](repeating: nil, count: times.count)
        var carried: Date?
        for i in times.indices {
            if let t = times[i] { carried = t.addingTimeInterval(clockOffset) }
            out[i] = carried
        }
        // 先頭の空白部分を、最初に見つかった時刻で埋める
        if let firstIndex = out.firstIndex(where: { $0 != nil }), firstIndex > 0 {
            let first = out[firstIndex]
            for i in 0..<firstIndex { out[i] = first }
        }
        return out
    }

    /// 複数ソースを1本の時系列に束ねる。
    ///
    /// 各ソース内の行順は必ず保たれる（同時刻でも入れ替わらない）。時刻を持たない
    /// ソースの行は、時刻を持つ行を全て出したあとに、ソース順・行順で並ぶ。
    ///
    /// ソース数 k は現実には数本なので、ヒープを使わず先頭 k 本を毎回見る素直な
    /// k-way merge にしている（O(N·k)）。k が二桁に増えたらここを差し替える。
    static func merge(_ sources: [Source]) -> [Entry] {
        let effective = sources.map { effectiveTimes($0.times, clockOffset: $0.clockOffset) }
        var cursor = [Int](repeating: 0, count: sources.count)
        let total = effective.reduce(0) { $0 + $1.count }

        var out: [Entry] = []
        out.reserveCapacity(total)

        for _ in 0..<total {
            var pick = -1
            var pickTime: Date?
            for s in sources.indices where cursor[s] < effective[s].count {
                let t = effective[s][cursor[s]]
                if pick < 0 { pick = s; pickTime = t; continue }
                // nil は「時刻不明」なので最後に回す。同時刻はソース番号の小さい方が先。
                switch (t, pickTime) {
                case let (a?, b?): if a < b { pick = s; pickTime = t }
                case (_?, nil):    pick = s; pickTime = t
                default:           break
                }
            }
            guard pick >= 0 else { break }
            let line = cursor[pick]
            out.append(Entry(source: pick,
                             line: line,
                             time: effective[pick][line],
                             hasOwnTimestamp: sources[pick].times[line] != nil))
            cursor[pick] += 1
        }
        return out
    }
}
