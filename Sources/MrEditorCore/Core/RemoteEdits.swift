import Foundation

/// 遠隔の画面で直した行を、保存するまで手元で持っておく入れ物（B12）。
///
/// **書き込みは 1 行ずつ、行番号で持つ。** 改行を含まない置き換えしか許さないので、
/// どれを先に書いても他の行の番号は動かない（順序を気にしなくてよい）。
///
/// 持つのは「開いたときの本文」と「直した本文」。**向こうへは両方を送る** ―― 開いたときと
/// 違っていたら、向こうで書かずに止めるため（`RemoteFile.replaceLineCommand`）。
public struct RemoteEdits: Equatable {

    public struct Edit: Equatable {
        public let line: Int
        /// 開いたとき向こうにあった本文（`\r` を含めて、バイトのまま）。
        public let original: String
        /// 直した本文（`\r` を含めて、書く形）。
        public let edited: String

        /// バイト長が変わるか。変わるなら向こうでファイルを作り直す。
        public var changesLength: Bool { original.utf8.count != edited.utf8.count }
    }

    private var byLine: [Int: Edit] = [:]

    public init() {}

    public var isEmpty: Bool { byLine.isEmpty }
    public var count: Int { byLine.count }

    /// 行番号の昇順。
    public var all: [Edit] { byLine.values.sorted { $0.line < $1.line } }

    /// 長さが変わる編集の数。**これが 1 以上なら、保存の前に人へ見せる。**
    public var rewriteCount: Int { byLine.values.filter(\.changesLength).count }

    public func edit(at line: Int) -> Edit? { byLine[line] }

    /// 1 行の本文は、これ以上は直さない（コマンドラインに載せるため）。
    public static let maxLineBytes = 60_000

    /// この行は直してよいか。
    ///
    /// - 行番号が無い行は直せない（まだ数えていない。**どの行を書き換えるのか言えない**）。
    /// - `U+FFFD` を含む行は直せない。UTF-8 として読めないバイトが置換文字に化けているので、
    ///   直して書くと**元のバイトを失う**。
    /// - 長すぎる行は直せない。
    public static func isEditable(_ line: RemoteLine) -> Bool {
        guard line.number != nil else { return false }
        guard !line.text.contains("\u{FFFD}"), !line.text.contains("\0") else { return false }
        return line.text.utf8.count <= maxLineBytes
    }

    /// 画面に出す本文。行末の `\r`（CRLF のファイル）は見せない ―― 入力欄に出ると
    /// 形の分からない文字になる。書くときは `raw(display:original:)` が戻す。
    public static func display(_ raw: String) -> String {
        raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
    }

    /// 入力欄の文字列を、書く形に直す。元の行が `\r` で終わっていたら `\r` を戻す。
    /// 改行を含むなら nil ＝ **1 行の置き換えではない**ので受けない。
    public static func raw(display: String, original: String) -> String? {
        guard !display.contains("\n"), !display.contains("\r") else { return nil }
        return original.hasSuffix("\r") ? display + "\r" : display
    }

    /// 直した内容を預かる。元の本文に戻したなら、預かっていたものを捨てる。
    /// 戻り値は預かった（または捨てた）あとに、その行が「直してある」状態か。
    @discardableResult
    public mutating func stage(line: Int, original: String, edited: String) -> Bool {
        // 同じ行を何度も直しても、基準は**最初に開いたときの本文**のまま。
        let base = byLine[line]?.original ?? original
        if edited == base {
            byLine[line] = nil
            return false
        }
        byLine[line] = Edit(line: line, original: base, edited: edited)
        return true
    }

    /// 書けた行を捨てる。
    public mutating func commit(line: Int) { byLine[line] = nil }

    public mutating func removeAll() { byLine.removeAll() }

    /// 一覧に出す本文。直してあればそちら。
    public func text(for line: RemoteLine) -> String {
        guard let n = line.number, let e = byLine[n] else { return line.text }
        return e.edited
    }
}
