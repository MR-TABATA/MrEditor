import Foundation

/// 「値」でなく「形」で行を比べるための正規化（純ロジック・UI 非依存）。
///
/// テスト環境から取ったデータと本番から取ったデータを並べても、**値は違って当たり前**で、
/// 見たいのは「同じ形をしているか」——— 日付が `2026-08-19` なのか `2026/08/19` なのか、
/// ID がゼロ埋めされているか、NULL が空欄なのか `NULL` なのか。そこで行を**形だけ残して潰してから**
/// ハッシュする。
///
/// **なぜこれで済むか:** diff エンジンは行の中身を一切見ていない（`LineDiff.compute` の入力は
/// `[LineHash]` だけ）。つまり**何をハッシュするかを差し替えるだけ**で「フォーマットを比較」になる。
/// 差し替え点は `DiffSource.lineHashes(mask:)` の 1 箇所で、表示は生の行のまま（`DiffModel` は
/// 左右の行番号しか持たない）。
///
/// **潰し方の要点は「型の名前に置き換えない」こと。** 日付を `<DATE>` にしてしまうと
/// `2026-08-19` と `2026/08/19` が同じものになり、**いちばん見たかった違いが消える**。
/// 数字は 1 桁ずつ `9` へ、英字の並びは `A` 1 個へ落とし、**区切り文字と桁はそのまま残す**。
///
///     2026-08-19 12:00:00 ERROR uid=41    →  9999-99-99 99:99:99 A A=99
///     2026/08/19 12:00:00 WARN  uid=7     →  9999/99/99 99:99:99 A A=9
///                                             ^^^^ ここだけが差分として出る
///
/// **全角は半角と別の印に落とす**（半角数字は `9`、全角数字は `#`）。値の違いは消えるのに、
/// `１２３` と `123` の食い違いは差分として残る —— 環境差でいちばん多い事故のひとつなので、
/// ここを一緒くたにしない。
public struct FormatMask: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 数字の**値**を無視する（桁数は残る）。`007` と `123` は同じ、`7` とは違う。
    public static let digits      = FormatMask(rawValue: 1 << 0)
    /// 数字の**桁数**も無視する（`.digits` と併せて使う）。`007` と `7` も同じになる。
    public static let digitCount  = FormatMask(rawValue: 1 << 1)
    /// 文字の並びの中身を無視する（`ERROR` も `WARN` も 1 個の `A`、`釧路検察審査会` も
    /// `伊達簡易裁判所` も 1 個の `T`）。**仮名・漢字も「値」として畳む** —— 日本語の CSV で
    /// これを畳まないと、氏名や住所が全部差分になって「値は無視する」が嘘になる。
    /// ただし**全角の記号と全角スペースは畳まない**（`、` と `,`、全角空白と半角空白の
    /// 食い違いは、まさに見つけたい「形」の違いだから）。
    public static let letters     = FormatMask(rawValue: 1 << 2)
    /// 大文字小文字の違いを無視する（`.letters` を入れているときは既にそちらに吸収される）。
    public static let letterCase  = FormatMask(rawValue: 1 << 3)
    /// 連続する空白を 1 個とみなし、行末の空白を落とす。
    public static let spaces      = FormatMask(rawValue: 1 << 4)
    /// 引用符（`"` `'`）の有無を無視する。
    public static let quotes      = FormatMask(rawValue: 1 << 5)

    /// 「フォーマットを比較」で使う既定。**値は無視するが、桁と区切りは見る。**
    ///
    /// 桁を無視しないのは、ゼロ埋めの食い違い（`007` ⇔ `7`）が環境差の定番だから。
    /// 一緒に潰すと、いちばん見つけたいものが見つからなくなる。
    public static let standard: FormatMask = [.digits, .letters]

    // MARK: - 正規化

    // 潰した後に置く印。**半角と全角で別の印にする**（違いを残すため）。
    private static let asciiDigitMark: UInt8 = 0x39   // '9'
    private static let wideDigitMark:  UInt8 = 0x23   // '#'
    private static let asciiLetterMark: UInt8 = 0x41  // 'A'
    private static let wideLetterMark:  UInt8 = 0x40  // '@'
    private static let cjkMark:         UInt8 = 0x54  // 'T'（仮名・漢字などの並び）

    /// 1 行分のバイト列（改行を含まない）を正規化して `emit` へ流す。
    ///
    /// **1 行ずつ確定させて出す**（戻り値で配列を作らない）。86,000,000 行のファイルを通すので、
    /// 行ごとに `[UInt8]` や `String` を作った時点で終わる。
    @inline(__always)
    func transform(_ p: UnsafePointer<UInt8>, count n: Int, _ emit: (UInt8) -> Void) {
        var i = 0
        var run: UInt8 = 0            // 畳んでいる並びの印（0 = 並びの途中でない）
        var pendingSpace = false      // 出すかどうかは、次に中身が来るまで決まらない（行末なら落とす）

        @inline(__always) func flushSpace() {
            if pendingSpace { emit(0x20); pendingSpace = false; run = 0 }
        }

        while i < n {
            let c = p[i]
            var width = 1

            // 種類分け。全角の数字・英字は 3 バイト（U+FF10.. / U+FF21.. / U+FF41..）。
            // 0 = その他, 1 = 半角数字, 2 = 全角数字, 3 = 半角英字, 4 = 全角英字,
            // 5 = 空白, 6 = 引用符, 7 = 仮名・漢字など
            var kind = 0
            if c >= 0x30, c <= 0x39 { kind = 1 }
            else if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) { kind = 3 }
            else if c == 0x20 || c == 0x09 { kind = 5 }
            else if c == 0x22 || c == 0x27 { kind = 6 }
            else if c >= 0xE3, c <= 0xE9, i + 2 < n {
                // 仮名・漢字（U+3040〜U+9FFF）。ただし U+3000 台＝句読点・全角スペース
                // （E3 80 xx）は記号なので畳まず、そのまま「形」として残す。
                if !(c == 0xE3 && p[i + 1] == 0x80) { kind = 7; width = 3 }
            }
            else if c == 0xEF, i + 2 < n {
                let b = p[i + 1], d = p[i + 2]
                if b == 0xBC, d >= 0x90, d <= 0x99 { kind = 2; width = 3 }              // ０-９
                else if b == 0xBC, d >= 0xA1, d <= 0xBA { kind = 4; width = 3 }         // Ａ-Ｚ
                else if b == 0xBD, d >= 0x81, d <= 0x9A { kind = 4; width = 3 }         // ａ-ｚ
            }

            @inline(__always) func emitRaw() { for k in 0..<width { emit(p[i + k]) } }

            switch kind {
            case 1, 2:
                let mark = (kind == 1) ? Self.asciiDigitMark : Self.wideDigitMark
                if contains(.digits) {
                    flushSpace()
                    if contains(.digitCount) {
                        if run != mark { emit(mark); run = mark }
                    } else {
                        emit(mark); run = 0
                    }
                } else {
                    flushSpace(); emitRaw(); run = 0
                }
            case 3, 4, 7:
                let mark: UInt8
                switch kind {
                case 3:  mark = Self.asciiLetterMark
                case 4:  mark = Self.wideLetterMark
                default: mark = Self.cjkMark
                }
                if contains(.letters) {
                    flushSpace()
                    if run != mark { emit(mark); run = mark }
                } else {
                    flushSpace()
                    if kind == 3, contains(.letterCase) { emit(c | 0x20) } else { emitRaw() }
                    run = 0
                }
            case 5:
                if contains(.spaces) { pendingSpace = true; run = 0 } else { emit(c); run = 0 }
            case 6:
                if !contains(.quotes) { flushSpace(); emit(c); run = 0 }
            default:
                flushSpace(); emitRaw(); run = 0
            }
            i += width
        }
        // pendingSpace は流さない ＝ 行末の空白は落ちる。
    }

    /// 正規化した結果の文字列。**テストと説明のため**（本番の経路はハッシュへ直接流す）。
    public func masked(_ line: String) -> String {
        var out: [UInt8] = []
        let bytes = Array(line.utf8)
        out.reserveCapacity(bytes.count)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            transform(base, count: buf.count) { out.append($0) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - ハッシュ（diff の入力）

    /// 1 行分のバイト列を正規化しながらハッシュにする。
    func hashLine(_ p: UnsafePointer<UInt8>, count n: Int) -> LineHash {
        var h = LineHasher()
        transform(p, count: n) { h.feed($0) }
        return h.value
    }

    func hashLine(_ bytes: [UInt8]) -> LineHash {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return LineHasher().value }
            return hashLine(base, count: buf.count)
        }
    }

    /// バイト列を 0x0A で切って、正規化した行ごとのハッシュにする。
    ///
    /// 行の切り方と末尾の扱いは `LineHasher.hashLines` と**必ず同じ**にする（行末の 0x0D は落とし、
    /// 末尾が改行で終わるなら空行を足さない）。ここがずれると、モードを切り替えただけで
    /// 行数が変わって左右の対応が崩れる。
    func hashLines(_ buf: UnsafeRawBufferPointer) -> [LineHash] {
        var out: [LineHash] = []
        out.reserveCapacity(max(16, buf.count / 64))
        guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return out }
        var start = 0
        for i in 0..<buf.count where base[i] == 0x0A {
            var end = i
            if end > start, base[end - 1] == 0x0D { end -= 1 }      // CRLF と LF の違いだけで全行を差分にしない
            out.append(hashLine(base + start, count: end - start))
            start = i + 1
        }
        if start < buf.count || buf.count == 0 {
            var end = buf.count
            if end > start, base[end - 1] == 0x0D { end -= 1 }
            out.append(hashLine(base + start, count: end - start))
        }
        return out
    }
}
