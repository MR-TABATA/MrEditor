import Foundation

/// Markdown 本文を構文の役割ごとに範囲分けする（純ロジック・AppKit 非依存）。
///
/// ここでは「どの範囲が何の役割か」だけを決める。色や書体（bold/italic のフォント、
/// アクセント色）を割り当てて実際に塗るのは描画側（`EditableViewer`）の仕事。
/// `NSLayoutManager` の temporary attribute として塗るので、この判定は毎回本文全体を
/// 見直しても安い（textStorage を書き換えないため undo/dirty/保存に一切乗らない）。
enum MarkdownSyntax {
    enum Role: Equatable {
        case heading
        case bold
        case italic
        case strikethrough
        case inlineCode
        case codeBlock
        case blockquote
        case horizontalRule
        case listMarker
        case link
        case tablePipe
    }

    struct Span: Equatable {
        let range: NSRange
        let role: Role
    }

    // MARK: - フェンス（```/~~~ で囲われたコードブロック）

    /// 各行が「開いているフェンスの内側」かどうか（デリミタ行自身も含む・0 始まりの行番号）。
    /// 閉じずに文書末まで続いたら、そのまま末尾まで内側として扱う（CommonMark と同じ）。
    static func fencedLineNumbers(_ lines: [String]) -> Set<Int> {
        var result = Set<Int>()
        var openMarker: Character?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = openMarker {
                result.insert(i)
                if trimmed.hasPrefix(String(repeating: marker, count: 3)) { openMarker = nil }
                continue
            }
            if trimmed.hasPrefix("```") { openMarker = "`"; result.insert(i) }
            else if trimmed.hasPrefix("~~~") { openMarker = "~"; result.insert(i) }
        }
        return result
    }

    // MARK: - 行の切り出し

    /// `text` を実際の改行位置で行ごとの範囲へ分ける（末尾の改行文字は含めない）。
    /// 末尾が改行で終わっていても、その後ろに空行は足さない（0 行のときは空配列）。
    static func lineRanges(_ text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        let len = text.length
        var idx = 0
        while idx < len {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: idx, length: 0))
            ranges.append(NSRange(location: start, length: contentsEnd - start))
            idx = end
        }
        return ranges
    }

    // MARK: - 行頭のブロック要素

    private static let headingRegex = try! NSRegularExpression(
        pattern: "^ {0,3}#{1,6}(?:\\s|$)", options: [.anchorsMatchLines])
    private static let blockquoteRegex = try! NSRegularExpression(
        pattern: "^ {0,3}>", options: [.anchorsMatchLines])
    private static let horizontalRuleRegex = try! NSRegularExpression(
        pattern: "^ {0,3}(?:(?:-\\s*){3,}|(?:\\*\\s*){3,}|(?:_\\s*){3,})$", options: [.anchorsMatchLines])
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: "^ {0,3}([-*+]|\\d{1,9}[.)])(?:\\s|$)", options: [.anchorsMatchLines])

    // MARK: - インライン要素

    private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let linkRegex = try! NSRegularExpression(pattern: "!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)")
    private static let boldRegex = try! NSRegularExpression(
        pattern: "\\*\\*[^*\\n]+?\\*\\*|__[^_\\n]+?__")
    private static let italicRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*(?!\\*)[^*\\n]+?\\*(?!\\*)|(?<![_\\w])_(?!_)[^_\\n]+?_(?![_\\w])")
    private static let strikethroughRegex = try! NSRegularExpression(pattern: "~~[^~\\n]+?~~")

    /// `text` 全体（`lineRanges` で切った各行）を役割ごとの範囲に変換する。
    /// `fenced` はコードフェンスの内側の行番号（`fencedLineNumbers` の結果）。
    static func spans(text: NSString, lineRanges: [NSRange], fenced: Set<Int>) -> [Span] {
        let whole = text as String
        var spans: [Span] = []
        for (i, lineRange) in lineRanges.enumerated() where lineRange.length > 0 {
            if fenced.contains(i) {
                spans.append(Span(range: lineRange, role: .codeBlock))
                continue
            }
            if headingRegex.firstMatch(in: whole, range: lineRange) != nil {
                spans.append(Span(range: lineRange, role: .heading))
                continue
            }
            if horizontalRuleRegex.firstMatch(in: whole, range: lineRange) != nil {
                spans.append(Span(range: lineRange, role: .horizontalRule))
                continue
            }
            if blockquoteRegex.firstMatch(in: whole, range: lineRange) != nil {
                spans.append(Span(range: lineRange, role: .blockquote))
            }
            if let m = listMarkerRegex.firstMatch(in: whole, range: lineRange) {
                let marker = m.range(at: 1)
                if marker.location != NSNotFound {
                    spans.append(Span(range: marker, role: .listMarker))
                }
            }
            spans.append(contentsOf: pipeSpans(in: text, range: lineRange))
            spans.append(contentsOf: inlineSpans(in: whole, range: lineRange))
        }
        return spans
    }

    /// 行内の `|` 1 文字ずつ（テーブルの区切り）。
    private static func pipeSpans(in text: NSString, range: NSRange) -> [Span] {
        var spans: [Span] = []
        var searchFrom = range.location
        let end = range.location + range.length
        while searchFrom < end {
            let r = text.range(of: "|", options: [], range: NSRange(location: searchFrom, length: end - searchFrom))
            guard r.location != NSNotFound else { break }
            spans.append(Span(range: r, role: .tablePipe))
            searchFrom = r.location + 1
        }
        return spans
    }

    /// 行内の強調・コード・リンク。先に見つけた範囲を優先し、重なる後発の一致は捨てる
    /// （インラインコードの中の `**` を太字と誤認しない、など）。
    private static func inlineSpans(in text: String, range: NSRange) -> [Span] {
        var occupied: [NSRange] = []
        var spans: [Span] = []
        func add(_ regex: NSRegularExpression, role: Role) {
            for m in regex.matches(in: text, range: range) {
                let r = m.range
                guard !occupied.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
                occupied.append(r)
                spans.append(Span(range: r, role: role))
            }
        }
        add(inlineCodeRegex, role: .inlineCode)
        add(linkRegex, role: .link)
        add(boldRegex, role: .bold)
        add(italicRegex, role: .italic)
        add(strikethroughRegex, role: .strikethrough)
        return spans
    }
}
