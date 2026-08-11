import AppKit

/// いま見えているドキュメントを、**Pro 側から読むための写し**。
///
/// `DocumentPane` そのものを public にしない理由: あの protocol は 60 以上の要求を持つ
/// 編集・保存・検索の口で、Pro が要るのは「何のファイルを、どの文字コードで、どこまで
/// 絞り込んで見ているか」だけ。**公開面は小さいほど直しやすい**（path 依存の 2 リポを
/// 同時に直す回数を減らす）。
///
/// この構造体は**値の写し**であって生きた参照ではない。分析の実行時に 1 度作る。
public struct ActiveDocument {
    /// 開いているファイル。未保存の新規ドキュメントでは nil（`text` を使う）。
    public let fileURL: URL?
    /// バッファの文字コード。ファイルを読み直す側（Pro）はこれで解釈する。
    public let encoding: DetectedEncoding
    /// 構造化表示中のモード（nil＝オフ）。
    public let structuredMode: StructuredMode?
    /// 構造化表示中の列名（オフなら空）。並び順は画面の列順。
    public let columnNames: [String]
    /// 小ファイル（編集ペイン）の本文。**大ファイルでは nil**＝ファイルを自分で読むこと。
    public let text: String?
    /// 「一致行だけ表示」中の一致行（**0 始まり**）。nil＝フィルタしていない。
    public let filterMatchLines: [Int]?

    public init(fileURL: URL?,
                encoding: DetectedEncoding,
                structuredMode: StructuredMode?,
                columnNames: [String],
                text: String?,
                filterMatchLines: [Int]?) {
        self.fileURL = fileURL
        self.encoding = encoding
        self.structuredMode = structuredMode
        self.columnNames = columnNames
        self.text = text
        self.filterMatchLines = filterMatchLines
    }

    /// 分析の対象が「ファイルを読む」経路か（＝大ファイル）。
    public var scansFile: Bool { text == nil && fileURL != nil }
}