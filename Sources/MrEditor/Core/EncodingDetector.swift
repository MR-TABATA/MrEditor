import Foundation

/// 判定された文字コード。
enum DetectedEncoding {
    case utf8
    case utf16LE
    case utf16BE
    case shiftJIS
    case eucJP

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .shiftJIS: return .shiftJIS
        case .eucJP: return .japaneseEUC
        }
    }

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .shiftJIS: return "Shift-JIS"
        case .eucJP: return "EUC-JP"
        }
    }

    /// エンコード指定メニューに並べる候補（日本語圏で使う順）。
    static let selectable: [DetectedEncoding] = [.utf8, .shiftJIS, .eucJP, .utf16LE, .utf16BE]
}

/// ファイルの改行コード。挿入・貼り付けする改行はこれに揃える（読み込み時に検出）。
enum LineEnding {
    case lf      // \n（Unix / macOS）
    case crlf    // \r\n（Windows）
    case cr      // \r（旧 Mac）

    var bytes: [UInt8] {
        switch self {
        case .lf: return [0x0A]
        case .crlf: return [0x0D, 0x0A]
        case .cr: return [0x0D]
        }
    }

    var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    /// 挿入テキスト内の改行（\r\n / \r / \n の混在）を、この EOL に揃える。改行が無ければそのまま。
    func normalize(_ text: String) -> String {
        guard text.contains("\r") || text.contains("\n") else { return text }
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n")
                     .replacingOccurrences(of: "\r", with: "\n")
        return self == .lf ? lf : lf.replacingOccurrences(of: "\n", with: string)
    }

    /// 先頭バイト列から最初の改行を見つけて判定する（改行が無ければ LF 既定）。
    static func detect(_ data: Data, encoding: DetectedEncoding) -> LineEnding {
        // UTF-16 は CR/LF が 2 バイト単位で並ぶため、デコードして文字単位で判定する。
        if encoding == .utf16LE || encoding == .utf16BE,
           let s = String(data: data, encoding: encoding.stringEncoding) {
            // Swift では "\r\n" が 1 つの Character なので、文字そのもので分類する。
            if let i = s.firstIndex(where: { $0.isNewline }) {
                switch s[i] {
                case "\r\n": return .crlf
                case "\r": return .cr
                default: return .lf
                }
            }
            return .lf
        }
        // ASCII 上位互換（UTF-8 / Shift-JIS / EUC-JP）はバイト走査で足りる。
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 0x0D: return (i + 1 < bytes.count && bytes[i + 1] == 0x0A) ? .crlf : .cr
            case 0x0A: return .lf
            default: i += 1
            }
        }
        return .lf
    }
}

/// エンコード変換保存の心臓部。`source` のバイト列を**行境界**（最後の 0x0A まで）で切りながら
/// `target` へ変換する。0x0A は UTF-8 / Shift-JIS / EUC-JP のマルチバイト内には現れないため、
/// そこで区切れば文字を割らない安全な境界になる（原本を任意サイズのスライスで流し込める）。
enum EncodingTranscoder {
    /// `feed` に渡した消費関数へ原本スライスを順に流し、変換済みバイトを `emit` に渡す。
    /// 目的エンコードで表現できない文字を代替に置換したら（lossy）true を返す。
    @discardableResult
    static func stream(from source: DetectedEncoding, to target: DetectedEncoding,
                       feed: ((ArraySlice<UInt8>) throws -> Void) throws -> Void,
                       emit: @escaping (Data) throws -> Void) throws -> Bool {
        var carry = [UInt8]()
        var lossy = false
        func flush(_ bytes: [UInt8]) throws {
            guard !bytes.isEmpty else { return }
            let s = String(data: Data(bytes), encoding: source.stringEncoding)
                ?? String(decoding: bytes, as: UTF8.self)
            if let d = s.data(using: target.stringEncoding) {
                try emit(d)
            } else {
                lossy = true
                try emit(s.data(using: target.stringEncoding, allowLossyConversion: true) ?? Data(s.utf8))
            }
        }
        try feed { slice in
            carry.append(contentsOf: slice)
            if let nl = carry.lastIndex(of: 0x0A) {
                try flush(Array(carry[...nl]))
                carry.removeSubrange(...nl)
            }
        }
        try flush(carry)                                    // 末尾（改行なし最終行）
        return lossy
    }
}

/// 文字コードを先頭バイト列から推定する。
///
/// 判定順: BOM → UTF-8 厳密 → Shift-JIS / EUC-JP スコアリング。
/// 不能なら UTF-8 にフォールバック（化けても落ちない方針）。
enum EncodingDetector {
    static func detect(_ data: Data) -> DetectedEncoding {
        let bytes = [UInt8](data)
        let n = bytes.count

        // 1. BOM
        if n >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return .utf8 }
        if n >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return .utf16LE }
        if n >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return .utf16BE }

        // 2. UTF-8 として厳密に妥当か
        if isValidUTF8(bytes) { return .utf8 }

        // 3. Shift-JIS / EUC-JP スコアリング
        let sjis = scoreShiftJIS(bytes)
        let euc = scoreEUCJP(bytes)
        return sjis >= euc ? .shiftJIS : .eucJP
    }

    /// 厳密な UTF-8 妥当性判定。末尾でマルチバイトが切れている場合は許容する。
    private static func isValidUTF8(_ b: [UInt8]) -> Bool {
        let n = b.count
        var i = 0
        while i < n {
            let c = b[i]
            if c < 0x80 {
                i += 1
            } else if c & 0xE0 == 0xC0 {
                if c < 0xC2 { return false } // 冗長符号化
                if i + 1 >= n { return true }
                if b[i + 1] & 0xC0 != 0x80 { return false }
                i += 2
            } else if c & 0xF0 == 0xE0 {
                if i + 2 >= n { return i + 1 >= n || b[i + 1] & 0xC0 == 0x80 }
                if b[i + 1] & 0xC0 != 0x80 || b[i + 2] & 0xC0 != 0x80 { return false }
                i += 3
            } else if c & 0xF8 == 0xF0 {
                if c > 0xF4 { return false }
                if i + 3 >= n { return true }
                if b[i + 1] & 0xC0 != 0x80 || b[i + 2] & 0xC0 != 0x80 || b[i + 3] & 0xC0 != 0x80 {
                    return false
                }
                i += 4
            } else {
                return false
            }
        }
        return true
    }

    private static func scoreShiftJIS(_ b: [UInt8]) -> Int {
        var score = 0
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c < 0x80 {
                i += 1
            } else if (0xA1...0xDF).contains(c) {
                i += 1 // 半角カナ（単バイト）
            } else if (0x81...0x9F).contains(c) || (0xE0...0xFC).contains(c) {
                if i + 1 < n {
                    let d = b[i + 1]
                    if (0x40...0x7E).contains(d) || (0x80...0xFC).contains(d) {
                        score += 1
                        i += 2
                        continue
                    }
                }
                score -= 2
                i += 1
            } else {
                score -= 2
                i += 1
            }
        }
        return score
    }

    private static func scoreEUCJP(_ b: [UInt8]) -> Int {
        var score = 0
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c < 0x80 {
                i += 1
            } else if c == 0x8E { // 半角カナ
                if i + 1 < n, (0xA1...0xDF).contains(b[i + 1]) {
                    score += 1
                    i += 2
                    continue
                }
                score -= 2
                i += 1
            } else if (0xA1...0xFE).contains(c) {
                if i + 1 < n, (0xA1...0xFE).contains(b[i + 1]) {
                    score += 1
                    i += 2
                    continue
                }
                score -= 2
                i += 1
            } else {
                score -= 2
                i += 1
            }
        }
        return score
    }
}
