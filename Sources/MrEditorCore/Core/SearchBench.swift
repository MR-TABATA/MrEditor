import Foundation

/// 検索の速さを **release ビルドで**測るための入口。
///
/// テストからも測れるが、`swift test -c release` はテスト補助が `#if DEBUG` で
/// 囲まれていて通らない。debug の数字だけを見て「遅い」と判じると、ビルド設定の
/// せいなのか実装のせいなのか分けられない ── Swift の debug はこの手の密な走査で
/// 桁が変わる。だから release で走る経路をひとつ作っておく。
public enum SearchBench {
    public struct Result: Sendable {
        public let bytes: Int
        public let encoding: String
        public let matchedLines: Int
        public let seconds: Double
    }

    /// 照合をせず、mmap でファイル全体を舐めて改行を数えるだけ。
    /// **検索の遅さが mmap（ページフォルト）由来かを切り分けるための下限値。**
    /// これが速ければ、遅いのは読み出しではなく照合の側だと分かる。
    public static func scan(path: String) -> Result? {
        let url = URL(fileURLWithPath: path)
        guard let buffer = FileBuffer(url: url) else { return nil }
        let total = buffer.count
        let started = Date()
        var lines = 0
        buffer.withBytes(in: 0..<total) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var i = 0
            while i < total {
                guard let nl = memchr(base + i, 0x0A, total - i) else { break }
                lines += 1
                i = UnsafeRawPointer(nl) - UnsafeRawPointer(base) + 1
            }
        }
        return Result(bytes: total, encoding: "(照合なし)", matchedLines: lines,
                      seconds: Date().timeIntervalSince(started))
    }

    /// `path` を開いて `term` で全走査し、かかった秒数を返す（表示はしない）。
    public static func run(path: String, term: String) -> Result? {
        let url = URL(fileURLWithPath: path)
        guard let buffer = FileBuffer(url: url),
              let head = try? FileHandle(forReadingFrom: url) else { return nil }
        let encoding = EncodingDetector.detect(head.readData(ofLength: 64 << 10))
        try? head.close()

        let engine = SearchEngine(buffer: buffer, encoding: encoding)
        let started = Date()
        var matched = 0
        let done = DispatchSemaphore(value: 0)
        engine.search(.terms([term]), progress: { _, _ in }, completion: {
            matched = $0.lineCount
            done.signal()
        })
        // completion は main で呼ばれる。呼び出し側が main を塞ぐと届かないので、
        // ここで run loop を回して待つ。
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return Result(bytes: buffer.count, encoding: encoding.displayName,
                      matchedLines: matched, seconds: Date().timeIntervalSince(started))
    }
}
