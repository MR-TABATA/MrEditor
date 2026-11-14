import Foundation

/// 値が数として読めるか。**「だいたい数値」を作らないための純関数。**
///
/// 仕様 §3.2 の通り、C2 は**全行が数として読めたときだけ数値列**と呼ぶ。8 割ルールのような
/// 閾値を置くと、混ざった 1 万行を黙って無視して合計を出すことになる（静かな嘘）。
/// だからここは「読めた／読めない」しか返さない。
enum NumericField {

    enum Value: Equatable {
        /// 整数として読めた（合計は Int で持てる＝桁が落ちない）。
        case integer(Int)
        /// 小数・指数・Int に収まらない桁。合計は Double で持つ。
        case real(Double)

        var double: Double {
            switch self {
            case .integer(let n): return Double(n)
            case .real(let d):    return d
            }
        }
    }

    /// 数として読めれば返す。読めなければ nil＝文字列として扱う。
    ///
    /// **1 行あたりの確保を増やさない。** ここは 5,816,534 行 × 30 列＝1.7 億回通るので、
    /// `Array(s.utf8)` を 1 つ作るだけで秒が飛ぶ（実測: 全列の走査が 8.07 秒 → 6 秒台）。
    /// 文字列のバイト列を借りて、その場で読む。
    static func parse(_ s: String) -> Value? {
        var s = s
        return s.withUTF8 { parse($0) }
    }

    /// バイト列から。
    ///
    /// **先頭ゼロのある数字は数値にしない**（`00000001`・郵便番号 `0520021`）。
    /// 数値にするとゼロが落ちて別物になり、しかも並べ替えの結果が変わる。
    /// `0` の 1 文字だけ、`0.5`、`0e3` は数値（ゼロが落ちる心配がない）。
    static func parse(_ b: UnsafeBufferPointer<UInt8>) -> Value? {
        guard !b.isEmpty else { return nil }

        var i = 0
        var negative = false
        if b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") {
            negative = b[i] == UInt8(ascii: "-")
            i += 1
        }
        guard i < b.count else { return nil }

        // 先頭ゼロ（`0` の直後がまだ数字）＝文字列。
        if b[i] == UInt8(ascii: "0"), i + 1 < b.count, isDigit(b[i + 1]) { return nil }

        var intDigits = 0
        var intValue = 0
        var overflowed = false
        while i < b.count, isDigit(b[i]) {
            intDigits += 1
            let d = Int(b[i] - UInt8(ascii: "0"))
            let (m, o1) = intValue.multipliedReportingOverflow(by: 10)
            let (a, o2) = o1 ? (0, true) : m.addingReportingOverflow(d)
            if o1 || o2 { overflowed = true } else { intValue = a }
            i += 1
        }

        var isReal = false
        var fracDigits = 0
        if i < b.count, b[i] == UInt8(ascii: ".") {
            isReal = true
            i += 1
            while i < b.count, isDigit(b[i]) { fracDigits += 1; i += 1 }
        }
        guard intDigits + fracDigits > 0 else { return nil }

        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            isReal = true
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            var expDigits = 0
            while i < b.count, isDigit(b[i]) { expDigits += 1; i += 1 }
            guard expDigits > 0 else { return nil }
        }
        // 末尾に何か残っていたら数値ではない（`12ab`・`1,234`・`3件`）。
        guard i == b.count else { return nil }

        if !isReal && !overflowed {
            return .integer(negative ? -intValue : intValue)
        }
        guard let d = Double(String(decoding: b, as: UTF8.self)) else { return nil }
        return .real(d)
    }

    private static func isDigit(_ c: UInt8) -> Bool {
        c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
    }
}

/// 1 行を**全部の欄に**切る。C2 は 31 列を 1 パスで見るので、列ごとに行頭から数え直す
/// （`CSVFieldScanner.fieldRange` を列の数だけ呼ぶ）と、1 行の走査が列数倍になる。
///
/// 切り方の規則は `CSVFieldScanner.fieldRange` と**同じでなければならない**
/// （画面・C1・C2 の 3 者で列がズレると誰も気づけない）。`ColumnStatsRunnerTests` が
/// `TabularFormatter.splitDelimited` と突き合わせて確かめている。
enum CSVRowScanner {

    /// 欄を順に渡す。`body` の第 1 引数は 0 始まりの列番号。
    /// 戻り値はその行の欄の数（列数より多いことも少ないこともある）。
    @discardableResult
    static func forEachField(in line: UnsafeBufferPointer<UInt8>,
                             separator: UInt8,
                             quoted: Bool,
                             limit: Int,
                             _ body: (Int, Range<Int>) -> Void) -> Int {
        let quote = UInt8(ascii: "\"")
        var field = 0
        var i = 0
        var start = 0
        var inQuotes = false
        var atFieldStart = true

        while i < line.count {
            let c = line[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < line.count && line[i + 1] == quote { i += 2; continue }
                    inQuotes = false
                }
                i += 1
            } else if quoted && c == quote && atFieldStart {
                inQuotes = true
                atFieldStart = false
                i += 1
            } else if c == separator {
                if field < limit { body(field, start..<i) }
                field += 1
                i += 1
                start = i
                atFieldStart = true
            } else {
                atFieldStart = false
                i += 1
            }
        }
        if field < limit { body(field, start..<line.count) }
        return field + 1
    }
}