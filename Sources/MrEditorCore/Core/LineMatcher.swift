import Foundation

/// 検索の式。**リテラル AND か、正規表現か。**
///
/// `SearchEngine`（1 本のファイルを検索）と、フォルダを横断して検索する側（Pro）が
/// **同じ型を渡す**ことで、「検索バーで書いた式」と「横断検索で書いた式」の意味が
/// ずれないようにしている。
public enum SearchMode {
    /// リテラル AND（全語を含む行）。語ごとの区切りは空白。
    case terms([String])
    /// 正規表現（行ごとに照合）。
    case regex(NSRegularExpression)
}

/// 1 行が検索式に当たるかを決める。**照合の規則はここ 1 箇所しかない。**
///
/// 元は `SearchEngine` の走査ループの中に直接書いてあった。フォルダ横断検索（Pro）が
/// 同じ規則を要るようになったので切り出した——**同じ式で違う結果が出るのが最悪**で、
/// しかも利用者からは絶対に分からない（どちらが正しいのか確かめる手段が無い）。
///
/// ## 1 行あたりの確保を増やさない
///
/// 8,642 万行を通すので、準備（語のバイト列化・大小の畳み込み）は `init` で 1 回だけ行い、
/// 走査中は既にあるバイト列を見るだけにする。
///
/// ## Shift-JIS / EUC もバイトのまま探す（2026-09-05）
///
/// 元は非 UTF-8 だけ「行をデコードしてから文字列で照合」していた。バイトのままだと
/// 2 バイト目が誤爆するから、という理由で、判断としては正しい。ただし**代償が大きすぎた**。
///
///   1.06GB の Shift-JIS CSV（581 万行）を全走査   26.0 秒
///   同じ内容の UTF-8 版（1.26GB）                  1.2 秒
///   mmap で舐めて改行を数えるだけ                  0.13 秒
///
/// 26 秒のほぼ全部が `String(data:encoding:)` を 581 万回呼ぶ費用で、release ビルドでも
/// 縮まない（自分のコードではなく Foundation 側の費用だから）。
///
/// そこで**語のほうを対象のエンコーディングへ変換して、バイトのまま探す**。誤爆は
/// 「当たった位置が文字の切れ目に乗っているか」を確かめて弾く（`isCharBoundary`）。
/// 切れ目の確認は当たった箇所でしか走らず、しかも走査位置が単調に進むので全体で O(n)。
///
/// **バイト経路に乗せない場合**（`decode` に戻す）:
///   - 語が対象のエンコーディングに変換できない
///   - 大小無視で、語に**非 ASCII の大小を持つ文字**が入っている（全角 Ａ など）。
///     `.caseInsensitive` は全角 Ａ と ａ も同一視するが、バイト比較では出せない。
public struct LineMatcher {

    private let regex: NSRegularExpression?
    /// UTF-8 のバイト探索用（大小無視なら小文字化済み）。
    private let termBytes: [[UInt8]]
    /// 非 UTF-8 の文字列照合用。
    private let termStrings: [String]
    private let useByteSearch: Bool
    private let fold: Bool
    private let stringOptions: NSString.CompareOptions
    private let encoding: DetectedEncoding

    /// `caseSensitive` は terms モードにだけ効く（正規表現は compile 時に決まっている）。
    public init(mode: SearchMode, caseSensitive: Bool, encoding: DetectedEncoding) {
        self.encoding = encoding
        self.fold = !caseSensitive
        self.stringOptions = caseSensitive ? [] : .caseInsensitive
        switch mode {
        case .terms(let terms):
            regex = nil
            termStrings = terms
            let folded = terms.map { caseSensitive ? $0 : $0.lowercased() }
            if encoding == .utf8 {
                termBytes = folded.map { Array($0.utf8) }
                useByteSearch = true
            } else if caseSensitive || !terms.contains(where: Self.hasNonASCIICase),
                      let encoded = Self.encode(folded, to: encoding) {
                termBytes = encoded
                useByteSearch = true
            } else {
                termBytes = []          // デコードして文字列で照合する（従来どおり）
                useByteSearch = false
            }
        case .regex(let rx):
            regex = rx                  // 行ごとにデコードして照合（全エンコーディング共通）
            termBytes = []
            termStrings = []
            useByteSearch = false
        }
    }

    /// 何も探していない（空の検索語）。呼ぶ側は走査そのものを省く。
    /// **`termBytes` では判じない** ── バイト経路に乗らなかったときに空になるので、
    /// 「探す語はあるのに走査を省く」になってしまう。
    public var isEmpty: Bool { regex == nil && termStrings.isEmpty }

    /// バイト列の 1 行が当たるか。**これが本線**（10GB を通る経路）。
    public func matches(_ p: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        if let regex {
            let s = decode(p, length)
            return regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
        if useByteSearch {
            if encoding == .utf8 {
                return termBytes.allSatisfy { Self.containsBytes(p, length, $0, fold: fold) }
            }
            return termBytes.allSatisfy {
                Self.containsAligned(p, length, $0, fold: fold, encoding: encoding)
            }
        }
        let s = decode(p, length)
        return termStrings.allSatisfy { s.range(of: $0, options: stringOptions) != nil }
    }

    public func matches(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = line.baseAddress, !line.isEmpty else { return matchesEmptyLine() }
        return matches(base, line.count)
    }

    /// 文字列の 1 行が当たるか（本文が手元にある小ファイル経路）。
    public func matches(_ line: String) -> Bool {
        if let regex {
            return regex.firstMatch(in: line,
                                    range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        return termStrings.allSatisfy { line.range(of: $0, options: stringOptions) != nil }
    }

    private func matchesEmptyLine() -> Bool {
        if let regex {
            return regex.firstMatch(in: "", range: NSRange(location: 0, length: 0)) != nil
        }
        return termStrings.allSatisfy(\.isEmpty)
    }

    private func decode(_ p: UnsafePointer<UInt8>, _ length: Int) -> String {
        let data = Data(bytes: p, count: length)
        return String(data: data, encoding: encoding.stringEncoding)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// バイト列内に語が 1 回でも現れるか。`fold=true` で ASCII 大小無視（語は小文字化済み前提）。
    /// **UTF-8 専用**（後続バイトは 0x80..0xBF なので、語の先頭が文字の途中に当たらない）。
    static func containsBytes(_ p: UnsafePointer<UInt8>, _ len: Int, _ q: [UInt8], fold: Bool) -> Bool {
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

    /// 非 UTF-8（Shift-JIS / EUC-JP）でバイトのまま探す。**文字の切れ目だけを始点にする。**
    ///
    /// 素朴にバイト比較すると 2 通りの事故が起きる。どちらも実際に踏んだ:
    ///
    /// 1. **2 バイト目を拾う。** Shift-JIS の「ア」は `83 41` なので、語 `"A"`（`41`）が
    ///    文字の途中に当たる。→ 始点を文字の切れ目に限ることで消える。
    /// 2. **2 バイト目を小文字化してしまう。** `41` は 'A' の範囲なので、大小無視の畳み込みが
    ///    `83 41` を `83 61` に変えてしまい、**「ア」が探せなくなる**（2026-09-05 に乱択テストで
    ///    見つけた）。→ 畳み込むのは 1 バイト文字のときだけにする。
    ///
    /// 語も対象と同じエンコーディングに変換済みなので、始点が合えば文字の並びも合う。
    static func containsAligned(_ p: UnsafePointer<UInt8>, _ len: Int, _ q: [UInt8],
                                fold: Bool, encoding: DetectedEncoding) -> Bool {
        let m = q.count
        guard m > 0, len >= m else { return false }
        var i = 0
        let limit = len - m
        while i <= limit {
            if matchesAt(p, len, i, q, fold: fold, encoding: encoding) { return true }
            i += charLength(p[i], encoding)      // 文字の切れ目だけを次の始点にする
        }
        return false
    }

    /// `i`（文字の切れ目）から語がそのまま続くか。1 バイト文字のときだけ ASCII を畳み込む。
    private static func matchesAt(_ p: UnsafePointer<UInt8>, _ len: Int, _ i: Int,
                                  _ q: [UInt8], fold: Bool, encoding: DetectedEncoding) -> Bool {
        var li = i, qi = 0
        let m = q.count
        while qi < m {
            guard li < len else { return false }
            let clen = charLength(p[li], encoding)
            if clen == 1 {
                var a = p[li]
                if fold, a >= 65, a <= 90 { a += 32 }
                if a != q[qi] { return false }
                li += 1; qi += 1
            } else {
                guard qi + clen <= m, li + clen <= len else { return false }
                for k in 0..<clen where p[li + k] != q[qi + k] { return false }
                li += clen; qi += clen
            }
        }
        return true
    }

    /// 先頭バイトから見た 1 文字のバイト数（不正なバイトは 1 として進める ── 進まないと
    /// 走査が止まる）。
    static func charLength(_ b: UInt8, _ encoding: DetectedEncoding) -> Int {
        switch encoding {
        case .shiftJIS:
            // 2 バイト文字の 1 バイト目は 0x81..0x9F と 0xE0..0xFC。
            // 0xA0..0xDF は半角カナ（1 バイト）。
            return ((b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xFC)) ? 2 : 1
        case .eucJP:
            if b == 0x8F { return 3 }                       // 補助漢字
            if b == 0x8E || (b >= 0xA1 && b <= 0xFE) { return 2 }
            return 1
        case .utf8, .utf16LE, .utf16BE:
            return 1
        }
    }

    /// 語を対象のエンコーディングのバイト列にする。1 つでも変換できなければ nil
    /// （その場合は従来どおりデコードして文字列で照合する）。
    static func encode(_ terms: [String], to encoding: DetectedEncoding) -> [[UInt8]]? {
        var out: [[UInt8]] = []
        out.reserveCapacity(terms.count)
        for t in terms {
            if t.isEmpty { out.append([]); continue }
            guard let d = t.data(using: encoding.stringEncoding) else { return nil }
            out.append([UInt8](d))
        }
        return out
    }

    /// 非 ASCII で大小を持つ文字が入っているか（全角 Ａ など）。
    /// 入っていたらバイト比較では `.caseInsensitive` と同じ結果を出せないので、
    /// 大小無視のときはバイト経路に乗せない。
    static func hasNonASCIICase(_ term: String) -> Bool {
        term.unicodeScalars.contains { scalar in
            guard !scalar.isASCII else { return false }
            let s = String(scalar)
            return s.lowercased() != s || s.uppercased() != s
        }
    }
}
