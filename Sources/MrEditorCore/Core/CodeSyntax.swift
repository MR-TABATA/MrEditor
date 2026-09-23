import Foundation

/// Markdown 以外のコード言語のごく軽い構文ハイライト（純ロジック・AppKit 非依存）。
///
/// 本格的な言語ごとの文法は持たない。コメント・文字列・数値・予約語だけを、
/// 1 回の線形スキャンで拾う（コメント記号が文字列の中にあっても誤って
/// コメント扱いしない、というのが正規表現の単純な組み合わせでは崩れやすい点で、
/// ここだけは状態を持って前から読む）。
enum CodeSyntax {
    /// `definition` は「宣言の名前」（`def`/`class`/`func` などの直後の識別子。YAML では
    /// `key:` の key）。予約語そのものではなく、予約語の直後に来た名前だけに付く役割。
    enum Role { case comment, string, number, keyword, definition }
    struct Span { let range: NSRange; let role: Role }

    struct LanguageSpec {
        /// 行コメントの開始記号（`#`, `//`, `--` など）。複数持てる言語はない想定だが配列にしておく。
        let lineComments: [String]
        /// ブロックコメント（`/* ... */`）。無い言語は nil。
        let blockComment: (open: String, close: String)?
        /// 改行をまたがない普通の文字列の引用符。
        let stringQuotes: [Character]
        /// 改行をまたげる三重引用符（Python の `"""` `'''` など）。無い言語は空配列。
        let tripleQuotes: [String]
        /// 予約語。`caseInsensitiveKeywords` が true の言語は大文字で揃えて渡す。
        let keywords: Set<String>
        let caseInsensitiveKeywords: Bool
        /// この直後に来る識別子を「宣言の名前」として塗る予約語（`def`, `class`, `func` など）。
        /// 空白だけを挟んだ次の識別子が対象（`func (r *T) Name()` のような受け取り側つきの
        /// 宣言は、名前の手前で空白以外の文字（`(`）が挟まるため対象外＝安全側に倒す）。
        let declarationKeywords: Set<String>

        init(lineComments: [String] = [], blockComment: (open: String, close: String)? = nil,
             stringQuotes: [Character] = ["\"", "'"], tripleQuotes: [String] = [],
             keywords: Set<String> = [], caseInsensitiveKeywords: Bool = false,
             declarationKeywords: Set<String> = []) {
            self.lineComments = lineComments
            self.blockComment = blockComment
            self.stringQuotes = stringQuotes
            self.tripleQuotes = tripleQuotes
            self.keywords = keywords
            self.caseInsensitiveKeywords = caseInsensitiveKeywords
            self.declarationKeywords = declarationKeywords
        }
    }

    enum Language: CaseIterable {
        case python, swift, javascript, shell, yaml, json, sql, css
        case java, php, go, ruby, perl

        /// 拡張子（小文字）から言語を決める。対応外の拡張子は nil。
        static func detect(extension ext: String) -> Language? {
            switch ext {
            case "py": return .python
            case "swift": return .swift
            case "js", "mjs", "cjs", "jsx", "ts", "tsx": return .javascript
            case "sh", "bash", "zsh": return .shell
            case "yml", "yaml": return .yaml
            case "json": return .json
            case "sql": return .sql
            case "css", "scss": return .css
            case "java": return .java
            case "php": return .php
            case "go": return .go
            case "rb": return .ruby
            case "pl", "pm": return .perl
            default: return nil
            }
        }

        var spec: LanguageSpec {
            switch self {
            case .python:
                return LanguageSpec(
                    lineComments: ["#"], stringQuotes: ["\"", "'"], tripleQuotes: ["\"\"\"", "'''"],
                    keywords: ["False", "None", "True", "and", "as", "assert", "async", "await",
                               "break", "class", "continue", "def", "del", "elif", "else", "except",
                               "finally", "for", "from", "global", "if", "import", "in", "is",
                               "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
                               "while", "with", "yield"],
                    declarationKeywords: ["def", "class"])
            case .swift:
                return LanguageSpec(
                    lineComments: ["//"], blockComment: (open: "/*", close: "*/"),
                    keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
                               "func", "import", "init", "inout", "internal", "let", "open", "operator",
                               "private", "protocol", "public", "rethrows", "static", "struct",
                               "subscript", "typealias", "var", "break", "case", "continue", "default",
                               "defer", "do", "else", "fallthrough", "for", "guard", "if", "in",
                               "repeat", "return", "switch", "where", "while", "as", "Any", "catch",
                               "false", "is", "nil", "self", "Self", "super", "throw", "throws",
                               "true", "try", "guard"],
                    declarationKeywords: ["func", "class", "struct", "enum", "protocol"])
            case .javascript:
                return LanguageSpec(
                    lineComments: ["//"], blockComment: (open: "/*", close: "*/"),
                    keywords: ["break", "case", "catch", "class", "const", "continue", "debugger",
                               "default", "delete", "do", "else", "export", "extends", "finally",
                               "for", "function", "if", "import", "in", "instanceof", "new", "return",
                               "super", "switch", "this", "throw", "try", "typeof", "var", "void",
                               "while", "with", "yield", "let", "async", "await", "static", "get",
                               "set", "of", "interface", "type", "enum", "implements", "namespace",
                               "declare", "readonly", "as", "from", "true", "false", "null",
                               "undefined"],
                    declarationKeywords: ["function", "class"])
            case .shell:
                return LanguageSpec(
                    lineComments: ["#"],
                    keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do",
                               "done", "case", "esac", "function", "in", "return", "exit", "export",
                               "local", "readonly", "set", "unset", "shift", "break", "continue",
                               "eval", "exec", "source", "alias"],
                    declarationKeywords: ["function"])
            case .yaml:
                return LanguageSpec(
                    lineComments: ["#"],
                    keywords: ["TRUE", "FALSE", "NULL", "YES", "NO", "ON", "OFF"],
                    caseInsensitiveKeywords: true)
            case .json:
                return LanguageSpec(stringQuotes: ["\""], keywords: ["true", "false", "null"])
            case .sql:
                return LanguageSpec(
                    lineComments: ["--"], blockComment: (open: "/*", close: "*/"),
                    keywords: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                               "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "VIEW", "JOIN",
                               "INNER", "LEFT", "RIGHT", "OUTER", "ON", "GROUP", "BY", "ORDER",
                               "HAVING", "LIMIT", "OFFSET", "AS", "AND", "OR", "NOT", "NULL", "IS",
                               "IN", "EXISTS", "BETWEEN", "LIKE", "DISTINCT", "UNION", "ALL", "CASE",
                               "WHEN", "THEN", "ELSE", "END", "PRIMARY", "KEY", "FOREIGN",
                               "REFERENCES", "DEFAULT", "UNIQUE", "CONSTRAINT"],
                    caseInsensitiveKeywords: true)
            case .css:
                return LanguageSpec(blockComment: (open: "/*", close: "*/"))
            case .java:
                return LanguageSpec(
                    lineComments: ["//"], blockComment: (open: "/*", close: "*/"),
                    keywords: ["abstract", "assert", "boolean", "break", "byte", "case", "catch",
                               "char", "class", "const", "continue", "default", "do", "double",
                               "else", "enum", "extends", "final", "finally", "float", "for", "goto",
                               "if", "implements", "import", "instanceof", "int", "interface", "long",
                               "native", "new", "package", "private", "protected", "public", "return",
                               "short", "static", "strictfp", "super", "switch", "synchronized",
                               "this", "throw", "throws", "transient", "try", "void", "volatile",
                               "while", "true", "false", "null"],
                    declarationKeywords: ["class", "interface"])
            case .php:
                return LanguageSpec(
                    lineComments: ["//", "#"], blockComment: (open: "/*", close: "*/"),
                    keywords: ["abstract", "and", "array", "as", "break", "callable", "case", "catch",
                               "class", "clone", "const", "continue", "declare", "default", "do",
                               "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach",
                               "endif", "endswitch", "endwhile", "extends", "final", "finally", "fn",
                               "for", "foreach", "function", "global", "goto", "if", "implements",
                               "include", "include_once", "instanceof", "insteadof", "interface",
                               "isset", "list", "match", "namespace", "new", "or", "print", "private",
                               "protected", "public", "require", "require_once", "return", "static",
                               "switch", "throw", "trait", "try", "unset", "use", "var", "while",
                               "xor", "yield", "true", "false", "null"],
                    declarationKeywords: ["function", "class"])
            case .go:
                return LanguageSpec(
                    lineComments: ["//"], blockComment: (open: "/*", close: "*/"),
                    stringQuotes: ["\"", "'"],
                    keywords: ["break", "case", "chan", "const", "continue", "default", "defer",
                               "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
                               "interface", "map", "package", "range", "return", "select", "struct",
                               "switch", "type", "var", "true", "false", "nil", "iota"],
                    declarationKeywords: ["func"])
            case .ruby:
                return LanguageSpec(
                    lineComments: ["#"],
                    keywords: ["BEGIN", "END", "alias", "and", "begin", "break", "case", "class",
                               "def", "defined?", "do", "else", "elsif", "end", "ensure", "false",
                               "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
                               "rescue", "retry", "return", "self", "super", "then", "true", "undef",
                               "unless", "until", "when", "while", "yield"],
                    declarationKeywords: ["def", "class", "module"])
            case .perl:
                return LanguageSpec(
                    lineComments: ["#"],
                    keywords: ["my", "our", "local", "sub", "package", "use", "no", "require", "if",
                               "elsif", "else", "unless", "while", "until", "for", "foreach", "do",
                               "return", "last", "next", "redo", "qw", "print", "say", "defined",
                               "undef", "ref", "bless", "die", "warn"],
                    declarationKeywords: ["sub"])
            }
        }
    }

    /// `text` 全体を 1 回だけ前から読んでコメント・文字列・数値・予約語・宣言名の範囲を返す。
    static func spans(text: NSString, language: Language) -> [Span] {
        if language == .yaml { return yamlSpans(text: text) }   // YAML はデータ形式なので別経路

        let spec = language.spec
        let length = text.length
        guard length > 0 else { return [] }
        var buffer = [unichar](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))

        let lineCommentStarts = spec.lineComments.map { Array($0.utf16) }
        let blockOpen = spec.blockComment.map { Array($0.open.utf16) }
        let blockClose = spec.blockComment.map { Array($0.close.utf16) }
        let tripleQuotes = spec.tripleQuotes.map { Array($0.utf16) }
        let quoteChars = Set(spec.stringQuotes.compactMap { $0.utf16.first })

        func matches(_ pattern: [UInt16], at i: Int) -> Bool {
            guard !pattern.isEmpty, i + pattern.count <= length else { return false }
            for k in 0..<pattern.count where buffer[i + k] != pattern[k] { return false }
            return true
        }
        func isIdentifierStart(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95   // A-Z a-z _
        }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func isIdentifierPart(_ c: UInt16) -> Bool { isIdentifierStart(c) || isDigit(c) }
        func isInlineWhitespace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 }   // space/tab/CR

        var spans: [Span] = []
        var i = 0
        // `def`/`class`/`func` などの直後、空白だけを挟んだ次の識別子を宣言名として塗る。
        // 空白以外の文字（`(` など）を挟んだら諦める（Go のレシーバ付きメソッドなど）。
        var expectDefinition = false
        while i < length {
            let c = buffer[i]

            if let open = blockOpen, let close = blockClose, matches(open, at: i) {
                expectDefinition = false
                let start = i
                i += open.count
                while i < length, !matches(close, at: i) { i += 1 }
                i = min(length, i + close.count)
                spans.append(Span(range: NSRange(location: start, length: i - start), role: .comment))
                continue
            }
            if let prefix = lineCommentStarts.first(where: { matches($0, at: i) }) {
                expectDefinition = false
                let start = i
                i += prefix.count
                while i < length, buffer[i] != 10 { i += 1 }   // \n
                spans.append(Span(range: NSRange(location: start, length: i - start), role: .comment))
                continue
            }
            if let triple = tripleQuotes.first(where: { matches($0, at: i) }) {
                expectDefinition = false
                let start = i
                i += triple.count
                while i < length, !matches(triple, at: i) {
                    i += (buffer[i] == 92 && i + 1 < length) ? 2 : 1   // \ エスケープ
                }
                i = min(length, i + triple.count)
                spans.append(Span(range: NSRange(location: start, length: i - start), role: .string))
                continue
            }
            if quoteChars.contains(c) {
                expectDefinition = false
                let quote = c
                let start = i
                i += 1
                while i < length, buffer[i] != quote, buffer[i] != 10 {
                    i += (buffer[i] == 92 && i + 1 < length) ? 2 : 1
                }
                if i < length, buffer[i] == quote { i += 1 }
                spans.append(Span(range: NSRange(location: start, length: i - start), role: .string))
                continue
            }
            if isDigit(c) {
                expectDefinition = false
                let start = i
                while i < length, isIdentifierPart(buffer[i]) || buffer[i] == 46 { i += 1 }   // '.'
                spans.append(Span(range: NSRange(location: start, length: i - start), role: .number))
                continue
            }
            if isIdentifierStart(c) {
                let start = i
                while i < length, isIdentifierPart(buffer[i]) { i += 1 }
                let range = NSRange(location: start, length: i - start)
                if expectDefinition {
                    spans.append(Span(range: range, role: .definition))
                    expectDefinition = false
                    continue
                }
                if !spec.keywords.isEmpty {
                    let word = text.substring(with: range)
                    let key = spec.caseInsensitiveKeywords ? word.uppercased() : word
                    if spec.keywords.contains(key) {
                        spans.append(Span(range: range, role: .keyword))
                    }
                    if spec.declarationKeywords.contains(word) { expectDefinition = true }
                }
                continue
            }
            if expectDefinition, !isInlineWhitespace(c) { expectDefinition = false }
            i += 1
        }
        return spans
    }

    // MARK: - YAML（データ形式。予約語ではなく「キー」が主役なので別パス）

    private static let yamlKeyRegex = try! NSRegularExpression(
        pattern: "^\\s*(?:-\\s+)?([A-Za-z0-9_.\\-]+)\\s*:(?=\\s|$)", options: [.anchorsMatchLines])
    private static let yamlLiteralRegex = try! NSRegularExpression(
        pattern: "\\b(?:true|false|null|yes|no|on|off)\\b", options: [.caseInsensitive])
    private static let yamlStringRegex = try! NSRegularExpression(pattern: "\"[^\"\\n]*\"|'[^'\\n]*'")

    /// 行ごとに: コメント（クォートの外の `#`）／キー（`key:` の key）／文字列／真偽値・null を拾う。
    private static func yamlSpans(text: NSString) -> [Span] {
        var spans: [Span] = []
        let whole = text as String
        for lineRange in MarkdownSyntax.lineRanges(text) where lineRange.length > 0 {
            // クォートの中の # をコメント開始と誤認しないよう、クォート開閉を追いながら探す。
            var commentLength = lineRange.length
            var inQuote: unichar?
            var k = 0
            while k < lineRange.length {
                let c = text.character(at: lineRange.location + k)
                if let q = inQuote {
                    if c == q { inQuote = nil }
                } else if c == 34 || c == 39 {   // " '
                    inQuote = c
                } else if c == 35 {              // #
                    let prev = k == 0 ? 32 : text.character(at: lineRange.location + k - 1)
                    if prev == 32 || prev == 9 { commentLength = k; break }
                }
                k += 1
            }
            if commentLength < lineRange.length {
                spans.append(Span(range: NSRange(location: lineRange.location + commentLength,
                                                  length: lineRange.length - commentLength), role: .comment))
            }
            let contentRange = NSRange(location: lineRange.location, length: commentLength)

            if let m = yamlKeyRegex.firstMatch(in: whole, range: contentRange) {
                let keyRange = m.range(at: 1)
                if keyRange.location != NSNotFound {
                    spans.append(Span(range: keyRange, role: .definition))
                }
            }
            var occupied: [NSRange] = []
            for m in yamlStringRegex.matches(in: whole, range: contentRange) {
                spans.append(Span(range: m.range, role: .string))
                occupied.append(m.range)
            }
            for m in yamlLiteralRegex.matches(in: whole, range: contentRange) {
                let r = m.range
                guard !occupied.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
                spans.append(Span(range: r, role: .keyword))
            }
        }
        return spans
    }
}
