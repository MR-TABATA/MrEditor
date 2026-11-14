import Foundation

/// 値ごとの件数を数える器。**チャンクごとのローカル辞書にしない。**
///
/// 素直に「チャンクごとに辞書を持って最後に合流」にすると、**同じ値が全チャンクに重複して
/// 載る**ためメモリが並列度倍に膨らむ（実測: 列の統計で 31 列 × 上限 10 万 ＝ RSS 2.9GB）。
/// 値のハッシュで固定数のシャードへ振り分けると、1 つの値は必ず 1 つのシャードにしか
/// 入らないので、メモリは「異なる値の総数」にだけ比例する。
///
/// ロックはシャード単位。64 枚あるので、10 コアで奪い合っても実用上ぶつからない。
final class ShardedCounter {

    /// 異なる値の上限。超えたら**それ以降に初めて出た値**だけをまとめる（§ 仕様 2.4）。
    /// 実測で 1 件あたり約 110 バイトなので、200 万件で約 220MB。
    static let defaultCap = 2_000_000

    private static let shardCount = 64

    private final class Shard {
        var counts: [String: Int] = [:]
        let lock = NSLock()
    }

    private let shards = (0..<ShardedCounter.shardCount).map { _ in Shard() }
    private let cap: Int
    /// 上限を超えて捨てた（まとめた）行数。
    private(set) var truncatedRows = 0
    private let truncatedLock = NSLock()

    init(cap: Int = ShardedCounter.defaultCap) { self.cap = cap }

    /// 1 件数える。**上限に達した後も、既にある値は数え続ける**
    /// （表に出ている件数は最後まで正確、という約束のため）。
    func add(_ value: String, by n: Int = 1) {
        let shard = shards[Self.index(of: value)]
        shard.lock.lock()
        if shard.counts[value] != nil || shard.counts.count < perShardCap {
            shard.counts[value, default: 0] += n
            shard.lock.unlock()
        } else {
            shard.lock.unlock()
            truncatedLock.lock()
            truncatedRows += n
            truncatedLock.unlock()
        }
    }

    /// まとめて数える。**値ごとにロックを取らない**（シャードごとに 1 回だけ）。
    ///
    /// C2 は 30 列ぶんの辞書を何度も流し込むので、1 件ごとに lock/unlock すると
    /// それだけで秒が飛ぶ（実測: 1.26GB / 30 列で共有の器のぶんが 2.6 秒）。
    func add(contentsOf batch: [String: Int]) {
        guard !batch.isEmpty else { return }
        var buckets = [[(String, Int)]](repeating: [], count: Self.shardCount)
        for (value, count) in batch {
            buckets[Self.index(of: value)].append((value, count))
        }
        var dropped = 0
        for (i, bucket) in buckets.enumerated() where !bucket.isEmpty {
            let shard = shards[i]
            shard.lock.lock()
            for (value, count) in bucket {
                if shard.counts[value] != nil || shard.counts.count < perShardCap {
                    shard.counts[value, default: 0] += count
                } else {
                    dropped += count
                }
            }
            shard.lock.unlock()
        }
        if dropped > 0 {
            truncatedLock.lock()
            truncatedRows += dropped
            truncatedLock.unlock()
        }
    }

    /// 件数降順（同数は値の昇順で安定させる）。
    func sortedRows() -> [(value: String, count: Int)] {
        var merged: [(value: String, count: Int)] = []
        merged.reserveCapacity(distinctCount)
        for shard in shards {
            shard.lock.lock()
            for (k, v) in shard.counts { merged.append((k, v)) }
            shard.lock.unlock()
        }
        merged.sort { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
        return merged
    }

    /// 上位 K 件だけ（件数降順・同数は値の昇順）。**全件を並べ替えない。**
    /// C2 は 31 列 × 10 万件を持ちうるので、代表値 3 件のために毎列 10 万件を
    /// ソートすると、それだけで走査より時間がかかる。
    func topRows(_ k: Int) -> [(value: String, count: Int)] {
        guard k > 0 else { return [] }
        var top: [(value: String, count: Int)] = []
        top.reserveCapacity(k + 1)
        for shard in shards {
            shard.lock.lock()
            for (value, count) in shard.counts {
                if top.count == k, let last = top.last,
                   count < last.count || (count == last.count && value > last.value) { continue }
                let entry = (value: value, count: count)
                var i = top.count
                top.append(entry)
                while i > 0, top[i - 1].count < entry.count
                        || (top[i - 1].count == entry.count && top[i - 1].value > entry.value) {
                    top[i] = top[i - 1]
                    i -= 1
                }
                top[i] = entry
                if top.count > k { top.removeLast() }
            }
            shard.lock.unlock()
        }
        return top
    }

    var distinctCount: Int {
        var n = 0
        for shard in shards {
            shard.lock.lock()
            n += shard.counts.count
            shard.lock.unlock()
        }
        return n
    }

    /// 上限に達して打ち切ったか。**「N 種類以上」と正直に出すための印。**
    var didTruncate: Bool { truncatedRows > 0 }

    // MARK: - 内部

    /// **上限はシャードごとに割って持つ。** 全体の異なる値の数を毎回数えると 64 枚を
    /// 舐めることになり、1 行ごとの処理としては高すぎる。ハッシュで散っているので偏りは
    /// 小さく、打ち切りの起きる位置は cap の前後で数 % ずれる程度。
    /// **「200 万ちょうどで切る」ではなく「200 万あたりで切る」**という約束にする
    /// （表示も丸めた上限ではなく、実際の件数と「打ち切った」の印を出す）。
    private var perShardCap: Int { max(1, cap / Self.shardCount) }

    private static func index(of value: String) -> Int {
        var hasher = Hasher()
        hasher.combine(value)
        // `abs` は Int.min で落ちるので使わない。
        return (hasher.finalize() & Int.max) % shardCount
    }
}