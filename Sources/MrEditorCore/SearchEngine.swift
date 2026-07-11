import Foundation

/// 検索モード。
public enum SearchMode {
    case terms([String])               // リテラル AND（全語を含む行・語ごとに大小無視）
    case regex(NSRegularExpression)    // 正規表現（行ごとに照合）
}

/// 巨大ファイルをストリーム走査して一致行を集める検索エンジン。
///
/// 行単位（0x0A 区切り）に走査する。UTF-8 はクエリのバイト列をそのまま探索（高速）、
/// 非 UTF-8（Shift-JIS/EUC）は行をデコードして文字列照合（正確）。
/// 全文をメモリに乗せない（mmap をそのまま舐める）。一致行は上限まで保持する。
public final class SearchEngine {
    public struct Result {
        public var lines: [Int] = []      // 一致した行番号（昇順・上限まで）
        public var lineCount = 0          // 一致行の総数（上限超過も計上）
        public var isComplete = false
        public var capped = false
        public init(lines: [Int] = [], lineCount: Int = 0, isComplete: Bool = false, capped: Bool = false) {
            self.lines = lines; self.lineCount = lineCount
            self.isComplete = isComplete; self.capped = capped
        }
    }

    private let buffer: FileBuffer
    private let encoding: DetectedEncoding
    private let lineCap = 1_000_000
    private let queue = DispatchQueue(label: "MrEditor.search", qos: .userInitiated)

    /// 世代カウンタ。再検索/キャンセルで増やし、走査側は値の変化で打ち切る。
    /// （aligned Int の読みは arm64 で原子的。遅延キャンセルの良性レース。）
    private var generation = 0

    public init(buffer: FileBuffer, encoding: DetectedEncoding) {
        self.buffer = buffer
        self.encoding = encoding
    }

    /// 進行中の検索を打ち切る。
    public func cancel() { generation += 1 }

    /// 指定モードで全体を走査する。progress / completion はメインスレッドで呼ぶ。
    /// `caseSensitive` は terms モードに効く（regex は compile 時に決まる）。
    public func search(_ mode: SearchMode, caseSensitive: Bool = false,
                progress: @escaping (Result, Double) -> Void,
                completion: @escaping (Result) -> Void) {
        generation += 1
        let gen = generation
        let total = buffer.count
        let enc = encoding
        let cap = lineCap
        let fold = !caseSensitive
        let strOpts: NSString.CompareOptions = caseSensitive ? [] : .caseInsensitive

        // モード別の前計算
        let regex: NSRegularExpression?
        let termBytes: [[UInt8]]       // UTF-8/ASCII バイト探索（fold 時は小文字化済み）
        let termStrings: [String]      // 非 UTF-8 文字列照合
        let useByteSearch: Bool
        switch mode {
        case .terms(let terms):
            guard !terms.isEmpty else {
                DispatchQueue.main.async { if self.generation == gen { completion(Result(isComplete: true)) } }
                return
            }
            regex = nil
            termBytes = terms.map { Array((fold ? $0.lowercased() : $0).utf8) }
            termStrings = terms
            useByteSearch = (enc == .utf8)
        case .regex(let rx):
            regex = rx                  // 行ごとデコードして照合（全エンコーディング共通）
            termBytes = []; termStrings = []
            useByteSearch = false
        }

        queue.async { [weak self] in
            guard let self else { return }
            var res = Result()
            var lineNo = 0
            var reported = 0

            self.buffer.withBytes(in: 0..<total) { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var i = 0
                while i < total {
                    let nl = memchr(base + i, 0x0A, total - i)
                    let lineEnd = nl != nil ? (UnsafeRawPointer(nl!) - UnsafeRawPointer(base)) : total
                    let lineLen = lineEnd - i

                    let matched: Bool
                    if let rx = regex {
                        let d = Data(bytes: base + i, count: lineLen)
                        let s = String(data: d, encoding: enc.stringEncoding)
                            ?? String(decoding: d, as: UTF8.self)
                        matched = rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
                    } else if useByteSearch {
                        matched = termBytes.allSatisfy { SearchEngine.containsBytes(base + i, lineLen, $0, fold: fold) }
                    } else {
                        let d = Data(bytes: base + i, count: lineLen)
                        let s = String(data: d, encoding: enc.stringEncoding)
                            ?? String(decoding: d, as: UTF8.self)
                        matched = termStrings.allSatisfy { s.range(of: $0, options: strOpts) != nil }
                    }
                    if matched {
                        res.lineCount += 1
                        if res.lines.count < cap { res.lines.append(lineNo) } else { res.capped = true }
                    }
                    lineNo += 1
                    i = (nl != nil) ? lineEnd + 1 : total

                    if i - reported >= (64 << 20) {        // 64MB ごとに進捗報告＆キャンセル確認
                        if self.generation != gen { return }
                        reported = i
                        let snapshot = res
                        let p = Double(i) / Double(total)
                        DispatchQueue.main.async { if self.generation == gen { progress(snapshot, p) } }
                    }
                }
            }
            if self.generation != gen { return }
            res.isComplete = true
            let final = res
            DispatchQueue.main.async { if self.generation == gen { completion(final) } }
        }
    }

    /// バイト列内に語が1回でも現れるか。`fold=true` で ASCII 大小無視（q は小文字化済み前提）。
    private static func containsBytes(_ p: UnsafePointer<UInt8>, _ len: Int, _ q: [UInt8], fold: Bool) -> Bool {
        let m = q.count
        guard m > 0, len >= m else { return false }
        var i = 0
        let limit = len - m
        while i <= limit {
            var k = 0
            while k < m {
                var a = p[i + k]
                if fold, a >= 65, a <= 90 { a += 32 }   // ASCII 大文字→小文字
                if a != q[k] { break }
                k += 1
            }
            if k == m { return true }
            i += 1
        }
        return false
    }
}
