import Foundation

/// diff に食わせる「行の列」。
///
/// これを 1 枚かませることで、入口が 3 つ（2 ファイルを選ぶ／開いているタブ同士／
/// クリップボード）あってもコアは 1 本で済む。ファイルは mmap のまま、クリップボードは
/// メモリ上の文字列のまま、同じ口に流れる。
protocol DiffSource {
    /// 表示名（タブ名・見出し用）。
    var displayName: String { get }
    /// 行数。
    var lineCount: Int { get }
    /// 行のハッシュ列（全行分）。diff の入力。
    func lineHashes() -> [LineHash]
    /// i 行目の中身。**可視行の描画にしか呼ばれない**（全行を文字列化してはいけない）。
    func line(at index: Int) -> String

    /// 行 [from, from+count) の生バイトを、行末（改行）ごと出力先へ流す。
    ///
    /// マージ結果の書き出しに使う。**本文をメモリに載せない** —— チャンクで流すので、
    /// 10GB のファイルをマージしても、抱えるのは 1 チャンク分だけ（[[DiffModel.writeMerged]]）。
    /// 最終行に改行が無いファイルもあるため、末尾に改行が無ければ `eol` を足す。
    func writeLines(from: Int, count: Int, eol: [UInt8], to out: FileHandle) throws
}

// MARK: - ハッシュ

/// バイト列を 128 ビットにする。FNV-1a を 2 本、別の基底で回す。
/// 衝突すると diff が差分を見落とすので、ここをケチらない（[[LineHash]] の説明を参照）。
struct LineHasher {
    private var a: UInt64 = 0xcbf29ce484222325
    private var b: UInt64 = 0x9e3779b97f4a7c15

    mutating func feed(_ byte: UInt8) {
        a = (a ^ UInt64(byte)) &* 0x100000001b3
        b = (b ^ UInt64(byte)) &* 0xff51afd7ed558ccd
    }
    var value: LineHash { LineHash(a: a, b: b) }

    /// 生バイト列を 0x0A で切って、行ごとのハッシュにする。行末の 0x0D は落とす
    /// （CRLF と LF の違いだけで「全行が違う」と言わないため）。
    static func hashLines(_ buf: UnsafeRawBufferPointer) -> [LineHash] {
        var out: [LineHash] = []
        out.reserveCapacity(max(16, buf.count / 64))
        guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return out }
        var h = LineHasher()
        var pending = false          // 現在の行に 1 バイトでも入ったか（末尾の空行判定用）
        var prevCR = false
        for i in 0..<buf.count {
            let c = base[i]
            if c == 0x0A {
                out.append(h.value)
                h = LineHasher()
                pending = false
                prevCR = false
            } else {
                if prevCR { h.feed(0x0D) }        // CR の次が LF 以外なら本物の CR として食わせる
                if c == 0x0D { prevCR = true; pending = true; continue }
                prevCR = false
                h.feed(c)
                pending = true
            }
        }
        if pending || buf.count == 0 { out.append(h.value) }
        return out
    }
}

// MARK: - ファイル（mmap のまま）

/// ファイルを mmap して行を供給する。行の中身は要求されたときだけ読む。
final class FileDiffSource: DiffSource {
    let displayName: String
    private let buffer: FileBuffer
    private let index: LineIndex
    private let encoding: DetectedEncoding

    /// **メインスレッドから呼んではいけない。** 索引を作り切るまで戻らない（10GB で約 9 秒）。
    /// `LineIndex` の完了通知はメインスレッドへ回されるので、メインで待つと即デッドロックする。
    init?(url: URL) {
        precondition(!Thread.isMainThread, "FileDiffSource はメインスレッドで作らない（索引の完了待ちで固まる）")
        guard let buffer = FileBuffer(url: url) else { return nil }
        self.buffer = buffer
        self.displayName = url.lastPathComponent
        // 判定は先頭だけ見れば足りる（10GB 全部を Data に起こしたら本末転倒）。
        let head = buffer.data(in: 0..<min(buffer.count, 64 << 10))
        self.encoding = EncodingDetector.detect(head)
        self.index = LineIndex(buffer: buffer)
        // 行の中身を引くのに疎索引が要る。diff は全行を触るので、ここで作り切る。
        let done = DispatchSemaphore(value: 0)
        index.buildInBackground(progress: { _ in }, completion: { done.signal() })
        done.wait()
    }

    var lineCount: Int { index.displayLineCount }

    func lineHashes() -> [LineHash] {
        buffer.withBytes(in: 0..<buffer.count) { LineHasher.hashLines($0) }
    }

    func line(at i: Int) -> String {
        guard i >= 0, i < lineCount else { return "" }
        let data = buffer.data(in: byteRange(from: i, count: 1))
        let text = String(data: data, encoding: encoding.stringEncoding)
            ?? String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    }

    /// 行 [from, from+count) のバイト範囲（行末の改行を含む）。
    private func byteRange(from: Int, count: Int) -> Range<Int> {
        let start = index.byteOffset(ofLineStart: from)
        let endLine = from + count
        let end = (endLine < lineCount) ? index.byteOffset(ofLineStart: endLine) : buffer.count
        return start..<max(start, end)
    }

    func writeLines(from: Int, count: Int, eol: [UInt8], to out: FileHandle) throws {
        guard count > 0, from >= 0, from < lineCount else { return }
        let range = byteRange(from: from, count: min(count, lineCount - from))
        guard !range.isEmpty else { return }

        // 8MB ずつ流す（全体を Data に起こさない）。
        let chunk = 8 << 20
        var pos = range.lowerBound
        while pos < range.upperBound {
            let end = min(pos + chunk, range.upperBound)
            try out.write(contentsOf: buffer.data(in: pos..<end))
            pos = end
        }
        // 最終行に改行が無いファイルもある。次が続くなら改行を足す。
        if buffer.count > 0, range.upperBound == buffer.count {
            let last = buffer.data(in: (buffer.count - 1)..<buffer.count)
            if last.first != 0x0A { try out.write(contentsOf: Data(eol)) }
        }
    }
}

// MARK: - メモリ上のテキスト（クリップボード・未保存のタブ）

/// 文字列を行に切って供給する。クリップボード比較と、未保存タブの比較に使う。
final class TextDiffSource: DiffSource {
    let displayName: String
    private let lines: [String]

    init(text: String, displayName: String) {
        self.displayName = displayName
        // 末尾の改行 1 個は「行」を増やさない（ファイル側の扱いと揃える）。
        var t = text
        if t.hasSuffix("\r\n") { t.removeLast(2) } else if t.hasSuffix("\n") { t.removeLast() }
        self.lines = t.isEmpty ? [""] : t.components(separatedBy: .newlines)
    }

    var lineCount: Int { lines.count }

    func lineHashes() -> [LineHash] {
        lines.map { line in
            var h = LineHasher()
            for b in line.utf8 { h.feed(b) }
            return h.value
        }
    }

    func line(at i: Int) -> String { (i >= 0 && i < lines.count) ? lines[i] : "" }

    func writeLines(from: Int, count: Int, eol: [UInt8], to out: FileHandle) throws {
        guard count > 0, from >= 0, from < lines.count else { return }
        let end = min(from + count, lines.count)
        var bytes: [UInt8] = []
        for i in from..<end {
            bytes.append(contentsOf: Array(lines[i].utf8))
            bytes.append(contentsOf: eol)
        }
        try out.write(contentsOf: Data(bytes))
    }
}

// MARK: - メモリ予算

/// diff が積む索引は **1 行 16 バイト**（128 ビットのハッシュ）。閲覧と違い、これは
/// 本当にアプリが抱えるメモリなので、機械に載るかを先に確かめる。
///
/// 固定の行数上限にしないのは、8GB の MacBook Air と 64GB の Mac Studio で
/// 同じ操作が片方だけ死ぬのが最悪だから。**積んでいる RAM から予算を決める。**
enum DiffBudget {

    /// 物理メモリのうち diff に使ってよい割合。
    static let fraction = 0.25

    /// ハッシュ列（16B/行 × 2 ファイル）に対して、実際に積み上がる総量の倍率。
    ///
    /// **実測値**（2026-07-13、配布と同じ最適化ビルド、1GB × 2 ＝ 8,712,081 行）:
    ///   行ハッシュ 270 MB → ピーク実メモリ 1,765 MB ＝ **6.5 倍**。
    /// 差分の大半は `LineDiff.uniqueAnchors` が区間ごとに作る出現表（Dictionary）。
    ///
    /// 当初は 2.5 と置いていたが、これは**推測で、2.6 倍の過小評価だった**。
    /// 10GB × 2 で判定を無理に通したところ、実際に 8.8GB を超えて落ちた
    /// （この係数なら正しく断る）。数字は測ってから書く。
    static let overheadFactor = 6.5

    static func estimatedBytes(leftLines: Int, rightLines: Int) -> Int {
        Int(Double((leftLines + rightLines) * MemoryLayout<LineHash>.size) * overheadFactor)
    }

    static var allowedBytes: Int {
        Int(Double(ProcessInfo.processInfo.physicalMemory) * fraction)
    }

    /// 収まるか。収まらないなら、黙って落ちるのではなく理由を出して断る。
    static func fits(leftLines: Int, rightLines: Int) -> Bool {
        estimatedBytes(leftLines: leftLines, rightLines: rightLines) <= allowedBytes
    }

    static func describe(leftLines: Int, rightLines: Int) -> String {
        let needMB = Double(estimatedBytes(leftLines: leftLines, rightLines: rightLines)) / 1_048_576
        let haveMB = Double(allowedBytes) / 1_048_576
        return String(format: "%.0f 行の比較には約 %.0f MB 必要ですが、この Mac で diff に使える上限は約 %.0f MB です。",
                      Double(leftLines + rightLines), needMB, haveMB)
    }
}
