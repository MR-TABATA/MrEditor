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
