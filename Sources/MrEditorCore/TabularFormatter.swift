import Foundation

/// 構造化表示のモード。CSV/TSV は区切り整形、NDJSON はキー投影。
public enum StructuredMode: String, CaseIterable {
    case csv, tsv, ndjson
}

/// 生の1行文字列を、等幅カラムに桁揃えした表示文字列へ整形する純ロジック（UI 非依存）。
///
/// 列（ヘッダ名＋固定幅）はサンプル行から `build` で確定する。`format` は1行を
/// セルに分解し、各セルを列幅へ表示幅ベースでパディング／省略して ` │ ` で連結する。
/// バイトオフセットに依存しないため、大ファイル（`PieceTableViewer`）と小ファイル
/// （`EditableViewer`）の両経路から同じ呼び出しで使える。
public struct TabularFormatter {
    public struct Column { public let key: String; public let width: Int; public init(key: String, width: Int) { self.key = key; self.width = width } }   // width は表示セル単位

    public let mode: StructuredMode
    let columns: [Column]
    /// セルの区切り。
    static let separator = " │ "

    var columnCount: Int { columns.count }

    // MARK: - 構築

    /// サンプル行（生文字列・先頭〜1000 行想定）から列（名前＋固定幅）を確定する。
    public static func build(mode: StructuredMode, sampleLines: [String], widthCap: Int = 40) -> TabularFormatter {
        let rows = sampleLines.filter { !$0.isEmpty }
        switch mode {
        case .csv, .tsv:
            let sep: Character = (mode == .csv) ? "," : "\t"
            let parsed = rows.map { splitDelimited($0, sep: sep, csvQuotes: mode == .csv) }
            let header = parsed.first ?? []
            let colCount = parsed.map(\.count).max() ?? header.count
            var cols: [Column] = []
            for j in 0..<max(colCount, header.count) {
                let name = j < header.count ? header[j] : ""
                var w = displayWidth(name)
                for cells in parsed where j < cells.count { w = max(w, displayWidth(cells[j])) }
                cols.append(Column(key: name, width: clampWidth(w, cap: widthCap)))
            }
            return TabularFormatter(mode: mode, columns: cols)
        case .ndjson:
            var order: [String] = []
            var seen = Set<String>()
            var maxW: [String: Int] = [:]
            for line in rows {
                guard let obj = jsonObject(line) else { continue }
                for key in orderedKeys(of: line) {
                    if !seen.contains(key) { seen.insert(key); order.append(key); maxW[key] = displayWidth(key) }
                    let v = valueString(obj[key] ?? NSNull())
                    maxW[key] = max(maxW[key] ?? 0, displayWidth(v))
                }
            }
            let cols = order.map { Column(key: $0, width: clampWidth(maxW[$0] ?? displayWidth($0), cap: widthCap)) }
            return TabularFormatter(mode: mode, columns: cols)
        }
    }

    // MARK: - 整形

    /// 1 行 → 列に桁揃えした表示文字列。
    public func format(_ rawLine: String) -> String {
        let cells = self.cells(of: rawLine)
        var parts: [String] = []
        parts.reserveCapacity(columns.count)
        for (j, col) in columns.enumerated() {
            let raw = j < cells.count ? cells[j] : ""
            parts.append(Self.pad(raw, to: col.width))
        }
        return parts.joined(separator: Self.separator)
    }

    /// ヘッダ行（列名を桁揃え）。将来のピン留めヘッダ用。CSV/TSV では行0が実データのヘッダ。
    func headerLine() -> String {
        columns.map { Self.pad($0.key, to: $0.width) }.joined(separator: Self.separator)
    }

    /// 1 行 → セル配列。
    func cells(of rawLine: String) -> [String] {
        switch mode {
        case .csv:    return Self.splitDelimited(rawLine, sep: ",", csvQuotes: true)
        case .tsv:    return Self.splitDelimited(rawLine, sep: "\t", csvQuotes: false)
        case .ndjson:
            guard let obj = Self.jsonObject(rawLine) else { return [rawLine] }
            return columns.map { Self.valueString(obj[$0.key] ?? NSNull()) }
        }
    }

    // MARK: - 分割（1行内）

    /// 区切り分割。`csvQuotes` の場合のみ RFC4180 風のクォート（フィールド先頭の "…"、"" エスケープ）を扱う。
    /// クォート内改行は対象外（行指向のため各物理行＝1レコード）。
    static func splitDelimited(_ line: String, sep: Character, csvQuotes: Bool) -> [String] {
        if !csvQuotes { return line.components(separatedBy: String(sep)) }
        var out: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false; i += 1; continue
                }
                field.append(c); i += 1
            } else {
                if c == "\"" && field.isEmpty { inQuotes = true; i += 1 }
                else if c == sep { out.append(field); field = ""; i += 1 }
                else { field.append(c); i += 1 }
            }
        }
        out.append(field)
        return out
    }

    // MARK: - JSON

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// JSON オブジェクトのキーを**出現順**で返す（`JSONSerialization` は順序を保たないため元文字列を軽く走査）。
    private static func orderedKeys(of line: String) -> [String] {
        guard let obj = jsonObject(line) else { return [] }
        var keys: [String] = []
        var seen = Set<String>()
        let chars = Array(line)
        var i = 0
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" || c == "[" { depth += 1; i += 1; continue }
            if c == "}" || c == "]" { depth -= 1; i += 1; continue }
            // トップレベル（depth==1）の "key": だけ拾う。
            if c == "\"" && depth == 1 {
                var k = ""; i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                    k.append(chars[i]); i += 1
                }
                i += 1 // 閉じ "
                // 直後（空白を飛ばして）が : ならキー。
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, chars[j] == ":", obj[k] != nil, !seen.contains(k) {
                    seen.insert(k); keys.append(k)
                }
                continue
            }
            i += 1
        }
        // 走査で拾えなかったキーは末尾に足す（順不同でも欠落させない）。
        for k in obj.keys where !seen.contains(k) { keys.append(k) }
        return keys
    }

    /// JSON 値を表示文字列へ。文字列はそのまま、その他は compact JSON、null は空。
    private static func valueString(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let s = value as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(value)"
    }

    // MARK: - パディング／表示幅

    /// 表示幅ベースで `width` セルへ左寄せパディング。超過は `width-1` セルで切って `…`。
    static func pad(_ s: String, to width: Int) -> String {
        let w = displayWidth(s)
        if w == width { return s }
        if w < width { return s + String(repeating: " ", count: width - w) }
        // 切り詰め（… の 1 セルを残す）。
        var out = ""
        var used = 0
        for ch in s {
            let cw = charWidth(ch)
            if used + cw > width - 1 { break }
            out.append(ch); used += cw
        }
        out.append("…")            // … は幅1
        let pad = width - (used + 1)
        return pad > 0 ? out + String(repeating: " ", count: pad) : out
    }

    /// 文字列の表示幅（等幅フォント基準・CJK/全角=2）。
    static func displayWidth(_ s: String) -> Int {
        var w = 0
        for ch in s { w += charWidth(ch) }
        return w
    }

    private static func charWidth(_ ch: Character) -> Int {
        for u in ch.unicodeScalars where isWide(u.value) { return 2 }
        return 1
    }

    private static func clampWidth(_ w: Int, cap: Int) -> Int { max(1, min(cap, w)) }

    /// East Asian Wide/Fullwidth のおおよその範囲判定（等幅で2セル幅になる文字）。
    private static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F,      // Hangul Jamo
             0x2E80...0x303E,      // CJK radicals, Kangxi, CJK symbols/punct
             0x3041...0x33FF,      // Hiragana, Katakana, CJK symbols
             0x3400...0x4DBF,      // CJK Ext A
             0x4E00...0x9FFF,      // CJK Unified
             0xA000...0xA4CF,      // Yi
             0xAC00...0xD7A3,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compat ideographs
             0xFE30...0xFE4F,      // CJK compat forms
             0xFF00...0xFF60,      // Fullwidth forms
             0xFFE0...0xFFE6,      // Fullwidth signs
             0x1F300...0x1FAFF,    // emoji / symbols
             0x20000...0x3FFFD:    // CJK Ext B+
            return true
        default:
            return false
        }
    }
}
