import Foundation

/// JSON をその場で問い合わせる軽量クエリ（jmespath の実用サブセット）。UI 非依存の純ロジック。
///
/// 対応する構文:
/// - フィールド / ドット path: `a.b.c`、クォート付き `"a b".c`
/// - 配列インデックス（負値可）: `a[0]`、`a[-1]`
/// - 投影ワイルドカード: 配列 `a[*].b`、オブジェクト値 `a.*`
/// - フィルタ: `a[?k == 'v']`（比較 `== != < <= > >=`。右辺は `'文字列'` / 数値 / `true`/`false`/`null`）
/// - 恒等: 空文字 / `@`（ドキュメント全体）
///
/// 非対応（呼び出し側で割り切る）: パイプ `|`、関数 `length(@)` 等、スライス `[1:3]`、
/// フラット化 `[]`、多重選択 `[a,b]`。ネストした投影は近似（1 段を主眼に置く）。
enum JsonQuery {
    struct QueryError: Error { let message: String }

    /// 式を JSON 値（`JSONSerialization` の `Any`）に対して評価する。
    /// - Returns: 一致値。JSON の null は `NSNull`。マッチなしは `NSNull`（jmespath 準拠）。
    /// - Throws: 構文エラー時に `QueryError`。
    static func evaluate(_ expression: String, on root: Any) throws -> Any {
        let steps = try parse(expression)
        var current: Projected = .single(root)
        for step in steps { current = apply(step, to: current) }
        return current.materialized
    }

    /// 文字列 JSON を解析して評価し、結果を整形テキストに整えるところまで一括で行う。
    /// - Returns: 整形済み結果テキスト。無効な JSON / 構文エラーは `QueryError`。
    static func run(_ expression: String, onJSONText text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw QueryError(message: "invalid JSON")
        }
        let result = try evaluate(expression, on: root)
        return prettyResult(result)
    }

    /// 結果値を表示テキストへ。オブジェクト/配列は `JsonFormatter` で字下げ、スカラはそのまま。
    static func prettyResult(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let s = value as? String { return s }   // 文字列はクォートなしで素直に
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "\(value)" }
        return JsonFormatter.pretty(text) ?? text
    }

    // MARK: - 評価の中間表現

    /// 投影中（ワイルドカード/フィルタ後）は配列を要素ごとに写像する。
    private enum Projected {
        case single(Any)
        case projection([Any])

        /// 最終結果へ。投影は配列にまとめる。
        var materialized: Any {
            switch self {
            case .single(let v): return v
            case .projection(let arr): return arr
            }
        }
    }

    // MARK: - ステップ

    private enum Step {
        case field(String)
        case index(Int)
        case arrayWildcard          // [*]
        case objectWildcard         // .*
        case filter(Comparison)     // [?lhs op rhs]
    }

    private struct Comparison {
        let lhsPath: [Step]
        let op: String
        let rhs: Operand
    }

    private enum Operand {
        case literal(Any)           // 'str' / 数値 / true / false / null
        case path([Step])           // 要素相対の path
    }

    // MARK: - 適用

    private static func apply(_ step: Step, to current: Projected) -> Projected {
        switch current {
        case .single(let v):
            return applyToSingle(step, v)
        case .projection(let arr):
            // 投影中は各要素へ写像し、null（マッチなし）を落とす（jmespath 準拠）。
            var out: [Any] = []
            for el in arr {
                let r = applyToSingle(step, el)
                switch r {
                case .single(let rv):
                    if !(rv is NSNull) { out.append(rv) }
                case .projection(let rarr):
                    out.append(contentsOf: rarr)   // ネスト投影は平坦化して近似
                }
            }
            return .projection(out)
        }
    }

    private static func applyToSingle(_ step: Step, _ value: Any) -> Projected {
        switch step {
        case .field(let name):
            if let obj = value as? [String: Any] { return .single(obj[name] ?? NSNull()) }
            return .single(NSNull())
        case .index(let i):
            guard let arr = value as? [Any] else { return .single(NSNull()) }
            let idx = i < 0 ? arr.count + i : i
            return .single((idx >= 0 && idx < arr.count) ? arr[idx] : NSNull())
        case .arrayWildcard:
            guard let arr = value as? [Any] else { return .projection([]) }
            return .projection(arr)
        case .objectWildcard:
            guard let obj = value as? [String: Any] else { return .projection([]) }
            // オブジェクト値。順序は保証されないが投影用途では許容。
            return .projection(Array(obj.values))
        case .filter(let cmp):
            guard let arr = value as? [Any] else { return .projection([]) }
            return .projection(arr.filter { matches(cmp, element: $0) })
        }
    }

    // MARK: - フィルタ比較

    private static func matches(_ cmp: Comparison, element: Any) -> Bool {
        let lhs = (try? evaluateSteps(cmp.lhsPath, on: element)) ?? NSNull()
        let rhs: Any
        switch cmp.rhs {
        case .literal(let v): rhs = v
        case .path(let p):    rhs = (try? evaluateSteps(p, on: element)) ?? NSNull()
        }
        switch cmp.op {
        case "==": return jsonEqual(lhs, rhs)
        case "!=": return !jsonEqual(lhs, rhs)
        case "<", "<=", ">", ">=":
            guard let a = numeric(lhs), let b = numeric(rhs) else { return false }
            switch cmp.op {
            case "<":  return a < b
            case "<=": return a <= b
            case ">":  return a > b
            default:   return a >= b
            }
        default: return false
        }
    }

    private static func evaluateSteps(_ steps: [Step], on value: Any) throws -> Any {
        var current: Projected = .single(value)
        for s in steps { current = apply(s, to: current) }
        return current.materialized
    }

    private static func numeric(_ v: Any) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    private static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        if a is NSNull && b is NSNull { return true }
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = numeric(a), let y = numeric(b) { return x == y }
        if let x = a as? Bool, let y = b as? Bool { return x == y }
        // NSNumber は Bool も包むため、bool 同士は上の numeric で 0/1 一致になり得る点は許容。
        return false
    }

    // MARK: - パース

    private static func parse(_ expression: String) throws -> [Step] {
        let expr = expression.trimmingCharacters(in: .whitespaces)
        if expr.isEmpty || expr == "@" { return [] }
        let chars = Array(expr)
        var i = 0
        let n = chars.count
        var steps: [Step] = []
        while i < n {
            let c = chars[i]
            if c == "." { i += 1; continue }        // 区切り
            if c == "*" { steps.append(.objectWildcard); i += 1; continue }
            if c == "[" {
                let (step, next) = try parseBracket(chars, i)
                steps.append(step); i = next; continue
            }
            // フィールド（クォート付き or 素）
            let (name, next) = parseFieldName(chars, i)
            if name.isEmpty { throw QueryError(message: "unexpected '\(c)'") }
            steps.append(.field(name)); i = next
        }
        return steps
    }

    private static func parseFieldName(_ chars: [Character], _ start: Int) -> (String, Int) {
        var i = start
        let n = chars.count
        if chars[i] == "\"" {
            var name = ""; i += 1
            while i < n, chars[i] != "\"" {
                if chars[i] == "\\" && i + 1 < n { i += 1 }
                name.append(chars[i]); i += 1
            }
            i += 1   // 閉じ "
            return (name, i)
        }
        var name = ""
        while i < n {
            let c = chars[i]
            if c == "." || c == "[" || c == "*" { break }
            name.append(c); i += 1
        }
        return (name, i)
    }

    private static func parseBracket(_ chars: [Character], _ start: Int) throws -> (Step, Int) {
        var i = start + 1   // '[' の次
        let n = chars.count
        guard i < n else { throw QueryError(message: "unterminated '['") }
        if chars[i] == "*" {
            i += 1
            try expect(chars, &i, "]")
            return (.arrayWildcard, i)
        }
        if chars[i] == "?" {
            i += 1
            // 対応する ']' まで（クォート内は無視）。
            var body = ""
            while i < n {
                let c = chars[i]
                if c == "'" {
                    body.append(c); i += 1
                    while i < n, chars[i] != "'" { body.append(chars[i]); i += 1 }
                    if i < n { body.append(chars[i]); i += 1 }   // 閉じ '
                    continue
                }
                if c == "]" { break }
                body.append(c); i += 1
            }
            try expect(chars, &i, "]")
            return (.filter(try parseComparison(body)), i)
        }
        // 整数インデックス（負値可）。
        var num = ""
        if i < n, chars[i] == "-" { num.append("-"); i += 1 }
        while i < n, chars[i].isNumber { num.append(chars[i]); i += 1 }
        guard let idx = Int(num) else { throw QueryError(message: "invalid index") }
        try expect(chars, &i, "]")
        return (.index(idx), i)
    }

    private static func expect(_ chars: [Character], _ i: inout Int, _ c: Character) throws {
        guard i < chars.count, chars[i] == c else { throw QueryError(message: "expected '\(c)'") }
        i += 1
    }

    private static func parseComparison(_ body: String) throws -> Comparison {
        // トップレベル（クォート外）で比較演算子を探す。長い演算子を先に。
        let ops = ["==", "!=", "<=", ">=", "<", ">"]
        let chars = Array(body)
        var i = 0
        let n = chars.count
        var inQuote = false
        while i < n {
            let c = chars[i]
            if c == "'" { inQuote.toggle(); i += 1; continue }
            if !inQuote {
                for op in ops where matchOp(chars, i, op) {
                    let lhs = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                    let rhs = String(chars[(i + op.count)...]).trimmingCharacters(in: .whitespaces)
                    return Comparison(lhsPath: try parse(lhs), op: op, rhs: try parseOperand(rhs))
                }
            }
            i += 1
        }
        throw QueryError(message: "filter needs a comparator")
    }

    private static func matchOp(_ chars: [Character], _ i: Int, _ op: String) -> Bool {
        let o = Array(op)
        guard i + o.count <= chars.count else { return false }
        for k in 0..<o.count where chars[i + k] != o[k] { return false }
        return true
    }

    private static func parseOperand(_ s: String) throws -> Operand {
        if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
            return .literal(String(s.dropFirst().dropLast()))
        }
        if s == "true" { return .literal(true) }
        if s == "false" { return .literal(false) }
        if s == "null" { return .literal(NSNull()) }
        if let d = Double(s) { return .literal(d) }
        // それ以外は要素相対 path。
        return .path(try parse(s))
    }
}
