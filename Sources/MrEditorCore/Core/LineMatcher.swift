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
/// 走査中は既にあるバイト列を見るだけにする。UTF-8 はバイトのまま探し、Shift-JIS / EUC は
/// 行をデコードしてから文字列で照合する（バイトのままだと 2 バイト目が誤爆する）。
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
            termBytes = terms.map { Array((caseSensitive ? $0 : $0.lowercased()).utf8) }
            termStrings = terms
            useByteSearch = (encoding == .utf8)
        case .regex(let rx):
            regex = rx                  // 行ごとにデコードして照合（全エンコーディング共通）
            termBytes = []
            termStrings = []
            useByteSearch = false
        }
    }

    /// 何も探していない（空の検索語）。呼ぶ側は走査そのものを省く。
    public var isEmpty: Bool { regex == nil && termBytes.isEmpty }

    /// バイト列の 1 行が当たるか。**これが本線**（10GB を通る経路）。
    public func matches(_ p: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        if let regex {
            let s = decode(p, length)
            return regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
        if useByteSearch {
            return termBytes.allSatisfy { Self.containsBytes(p, length, $0, fold: fold) }
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
        return termBytes.allSatisfy(\.isEmpty)
    }

    private func decode(_ p: UnsafePointer<UInt8>, _ length: Int) -> String {
        let data = Data(bytes: p, count: length)
        return String(data: data, encoding: encoding.stringEncoding)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// バイト列内に語が 1 回でも現れるか。`fold=true` で ASCII 大小無視（語は小文字化済み前提）。
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
}