import Foundation

/// データの「嘘発見器（Data Sanity Check）」が検出した異常行。
///
/// CSV/TSV/NDJSON 等の構造化テキストにおいて、1 パス走査中に検出された
/// カラム数不一致や型汚染（数値列への文字列混入等）の具体的な行情報。
public struct SanityIssue: Identifiable, Sendable {

    public enum Kind: String, Sendable {
        /// カラム数の不一致（カンマのエスケープ漏れ、クォート閉じ忘れ等で列がズレた行）
        case columnMismatch
        /// 型の混入・汚染（数値列や日時列に文字列や不正な値が混入）
        case typeContamination
        /// 異常な長大行
        case extremeLength
    }

    public var id: String { "\(line):\(kind.rawValue):\(columnIndex ?? -1)" }

    /// 1 始まりのファイル行番号（ジャンプ先）。
    public let line: Int
    /// 異常の種類。
    public let kind: Kind
    /// 対象の列番号（0 始まり、型混入時）。
    public let columnIndex: Int?
    /// 対象の列名（ヘッダ）。
    public let columnName: String?
    /// 期待された値/形式（例: "30 列", "数値"）。
    public let expected: String
    /// 実際に入っていた値/列数（例: "31 列", "'N/A'"）。
    public let actual: String
    /// 行のプレビュー（先頭部分）。
    public let preview: String

    public init(line: Int,
                kind: Kind,
                columnIndex: Int? = nil,
                columnName: String? = nil,
                expected: String,
                actual: String,
                preview: String) {
        self.line = line
        self.kind = kind
        self.columnIndex = columnIndex
        self.columnName = columnName
        self.expected = expected
        self.actual = actual
        self.preview = preview
    }
}
