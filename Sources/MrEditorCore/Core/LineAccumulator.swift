import Foundation

/// 流れてくるバイト列を、**完全な行だけ**取り出す係。
///
/// `tail -f` の出力は、こちらの都合とは無関係な大きさで届く。**チャンクの境目は
/// 行の途中に落ちる**ので、届いたぶんをそのまま行として出すと、1 行が 2 行に割れて
/// 画面に並ぶ。しかもログの追従では、割れた行が「そういうログだった」と読めてしまう。
///
/// だから改行が来るまで持っておく。**まだ改行が来ていない末尾は、行にしない。**
struct LineAccumulator {

    /// 改行待ちの端数。
    private var pending = Data()

    /// 端数が膨らみすぎたら諦める上限。改行を含まないものを延々と食わされると
    /// メモリを持っていかれる（バイナリを tail した場合など）。
    static let maxPending = 4 << 20   // 4MB

    /// 届いたぶんを足して、**完成した行だけ**を返す。
    mutating func take(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        pending.append(chunk)

        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let raw = pending[pending.startIndex..<nl]
            pending = pending[pending.index(after: nl)...]
            lines.append(Self.decode(raw))
        }
        // `pending` はスライスなので、詰め直さないと添字が伸び続ける
        pending = Data(pending)

        if pending.count > Self.maxPending { pending.removeAll(keepingCapacity: false) }
        return lines
    }

    /// 流れが終わったときに、改行で終わっていない最後の 1 行を取り出す。
    /// **無ければ空**（無理に 1 行を作らない）。
    mutating func flush() -> [String] {
        guard !pending.isEmpty else { return [] }
        let last = Self.decode(pending)
        pending.removeAll(keepingCapacity: false)
        return [last]
    }

    /// CRLF の `\r` は落とす。Windows で書かれたログをそのまま追うと行末に見えない
    /// 文字が残り、比較したときだけ差分が出る、という分かりにくい形になる。
    private static func decode(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}
