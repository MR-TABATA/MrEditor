import CoreGraphics
import Foundation

/// 桁ルーラーと桁ガイド線の座標計算（UI 非依存の純ロジック）。
///
/// **両ペインが同じ式を使うことが要件。** 小ファイル（`NSTextView`）と巨大ファイル
/// （`DocumentView`）は描画の仕組みがまったく違うので、桁の計算をそれぞれで書くと
/// 必ずズレる。ズレたまま固定長の項目定義（C）を載せると、同じファイルを開き直した
/// だけで項目が別の場所を指す。だから桁 ↔ x の変換はここ 1 箇所にしかない。
///
/// 座標系は**本文の左端を 0 とする x**（ガター幅も横スクロール量も含まない）。
/// 呼ぶ側がそれぞれの原点と横スクロール量を足し引きする。
enum ColumnRuler {
    /// 桁 `col`（1 始まり）の左端 x。
    static func x(ofColumn col: Int, columnWidth: CGFloat) -> CGFloat {
        CGFloat(max(1, col) - 1) * columnWidth
    }

    /// x にある桁（1 始まり）。負の x は 1 桁目に丸める。
    static func column(atX x: CGFloat, columnWidth: CGFloat) -> Int {
        guard columnWidth > 0 else { return 1 }
        return max(1, Int(floor(x / columnWidth)) + 1)
    }

    /// ルーラーの目盛り 1 本。
    struct Tick: Equatable {
        let column: Int
        /// 本文左端を 0 とする x。
        let x: CGFloat
        /// 数字を出す目盛りか（`major` の倍数と 1 桁目）。
        let isMajor: Bool
    }

    /// 可視範囲に掛かる目盛り。`offset` は横スクロール量、`width` は本文の表示幅。
    ///
    /// `major` ごとに数字つきの長い目盛り、`minor` ごとに短い目盛りを返す。
    /// 1 桁目は数えはじめの基準なので、`major` の倍数でなくても必ず major にする。
    static func ticks(offset: CGFloat, width: CGFloat, columnWidth: CGFloat,
                      major: Int = 10, minor: Int = 5) -> [Tick] {
        guard columnWidth > 0, width > 0, major > 0, minor > 0 else { return [] }
        let first = column(atX: offset, columnWidth: columnWidth)
        let last = column(atX: offset + width, columnWidth: columnWidth)
        guard last >= first, last - first < 100_000 else { return [] }   // 極端なズームの暴走止め
        var ticks: [Tick] = []
        for col in first...last {
            let isMajor = col == 1 || col % major == 0
            guard isMajor || col % minor == 0 else { continue }
            ticks.append(Tick(column: col, x: x(ofColumn: col, columnWidth: columnWidth), isMajor: isMajor))
        }
        return ticks
    }
}

/// 桁ガイド線の集合。
///
/// **最初から「桁の配列」で持つ。** 単一の桁（80 桁など）で作ると、固定長の項目定義
/// （`1-8,9-14,15-40`）を載せるときに必ず捨てることになる。1 本しか引かない今でも
/// 配列に入れておけば、C はこの型に `fieldRanges` を足すだけで乗る。
struct ColumnGuides: Equatable {
    /// ガイドを引く桁（1 始まり・昇順・重複なし）。**この不変条件は init と各操作が守る。**
    private(set) var columns: [Int]

    init(_ columns: [Int] = []) {
        self.columns = Array(Set(columns.filter { $0 >= 1 })).sorted()
    }

    var isEmpty: Bool { columns.isEmpty }

    /// 項目を割る切れ目が 1 つでもあるか。**1 桁目のガイドは切れ目ではない**（そこが先頭）ので、
    /// `[1]` だけの状態は「定義なし」と同じ＝固定長表示には入れない（列が 1 本では何も分けていない）。
    var hasFieldBoundaries: Bool { columns.contains { $0 > 1 } }

    /// あれば消す、無ければ足す（ルーラーのクリックはこれ）。
    mutating func toggle(_ column: Int) {
        guard column >= 1 else { return }
        if let i = columns.firstIndex(of: column) {
            columns.remove(at: i)
        } else {
            columns.append(column)
            columns.sort()
        }
    }

    mutating func insert(_ column: Int) {
        guard column >= 1, !columns.contains(column) else { return }
        columns.append(column)
        columns.sort()
    }

    mutating func remove(_ column: Int) {
        columns.removeAll { $0 == column }
    }

    mutating func removeAll() {
        columns.removeAll()
    }

    /// ガイドを `column` から `newColumn` へ動かす（ルーラーのドラッグ）。動いたら true。
    ///
    /// **1 桁ずらすのに消して置き直させない**ためにある。行き先に既にガイドがあるときは
    /// 動かさない（2 本を重ねると片方が消えたように見え、離したときに戻せない）。
    @discardableResult
    mutating func move(_ column: Int, to newColumn: Int) -> Bool {
        guard newColumn >= 1, newColumn != column,
              let i = columns.firstIndex(of: column), !columns.contains(newColumn) else { return false }
        columns[i] = newColumn
        columns.sort()
        return true
    }

    /// `column` から `tolerance` 桁以内で最も近いガイド。クリックの当たり判定に使う
    /// （細い線をピクセル単位で狙わせない）。同距離なら小さい桁を返す。
    func nearest(to column: Int, within tolerance: Int) -> Int? {
        columns
            .filter { abs($0 - column) <= tolerance }
            .min { (abs($0 - column), $0) < (abs($1 - column), $1) }
    }

    /// ガイドを「項目の切れ目」と読んだときの固定長フィールドの範囲（1 始まり・閉区間）。
    ///
    /// 桁 `[9, 15]` は「1-8 / 9-14 / 15-」の 3 項目を意味する。最後の項目は
    /// `lastColumn`（その行の長さなど）が分かっていればそこで閉じ、分からなければ落とす。
    /// **C（固定長の項目定義）が使う口。B の時点では誰も呼ばないが、配列で持つ設計が
    /// そのまま C に届くことを型で示すために置いてある。**
    func fieldRanges(lastColumn: Int? = nil) -> [ClosedRange<Int>] {
        let bounds = columns.filter { $0 > 1 }
        if bounds.isEmpty, lastColumn == nil { return [] }
        var ranges: [ClosedRange<Int>] = []
        var start = 1
        for b in bounds {
            if b - 1 >= start { ranges.append(start...(b - 1)) }
            start = b
        }
        if let last = lastColumn, last >= start {
            ranges.append(start...last)
        }
        return ranges
    }
}

extension ColumnGuides {
    /// 縞に塗る桁範囲（1 始まり・閉区間）。**1 つおき**に返す。
    ///
    /// 固定長のデータは**もともと桁が揃っている**ので、列に見せるのに整形は要らない。
    /// 線を引いた項目を 1 つおきに薄く塗るだけで表になり、本文はそのまま＝**編集できる**。
    func stripes(upTo lastColumn: Int) -> [ClosedRange<Int>] {
        guard lastColumn >= 1 else { return [] }
        return fieldRanges(lastColumn: lastColumn)
            .enumerated()
            .compactMap { $0.offset % 2 == 1 ? $0.element : nil }
            // **見えている桁で切る。** 項目の範囲は次の切れ目まで伸びるので、
            // 画面の外まで塗る指示を返すと、呼ぶ側がそれぞれ切る羽目になる。
            .compactMap { $0.lowerBound > lastColumn ? nil : $0.lowerBound...min($0.upperBound, lastColumn) }
    }

    /// サンプル行に合わせた項目の桁範囲。**最後の項目は一番長い行の末尾で閉じる**。
    ///
    /// ガイドは切れ目しか持たないので「最後の項目がどこで終わるか」はデータが決める。
    /// 幅は文字数ではなく**見えている桁**（全角＝2）で測る。ガイド線は画面上の位置に
    /// 引かれるので、ここを文字数で測ると全角を含む行で線と項目がズレる。
    func fieldRanges(fitting sampleLines: [String]) -> [ClosedRange<Int>] {
        // 定義が data より右まで伸びていても（`…15-40` を 30 桁のデータに当てるなど）、
        // 閉じるのはデータの端。空の列を 1 本増やさない。
        let widest = sampleLines.reduce(0) { max($0, TabularFormatter.displayWidth($1)) }
        guard widest >= 1 else { return [] }
        return fieldRanges(lastColumn: widest)
    }
}

/// 固定長の項目定義（`1-8,9-14,15-40`）の読み書き。
///
/// **固定長を扱う人はたいてい仕様書を持っている**＝境界をクリックで置くだけでは苦行になる。
/// 逆に仕様書が無いときは境界を探すことが本体なのでクリックも要る。両方を同じ 1 つの状態
/// （`ColumnGuides`）に落とすのがここ。**ガイド＝項目の切れ目**なので、文字列との往復は
/// 「境界の桁の集合」を経由する（[[ColumnGuides.fieldRanges]] の裏返し）。
enum ColumnFieldSpec {
    /// 受け付ける区切り（半角/全角のカンマ・読点・空白）。
    private static let separators = CharacterSet(charactersIn: ",，、 \u{3000}\t\n")
    /// 受け付ける範囲記号（半角/全角ハイフン・各種ダッシュ・波ダッシュ）。
    private static let dashes: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}",
                                                 "\u{2014}", "\u{2015}", "\u{FF0D}", "\u{FF5E}",
                                                 "\u{301C}", "~", "\u{30FC}"]
    /// 桁数の上限（打ち間違いで巨大な配列を作らせない）。
    static let maxColumn = 100_000
    /// 項目数の上限。
    static let maxFields = 512

    /// `1-8,9-14,15-40` を**境界の桁**（1 始まり・昇順・重複なし）に読む。
    ///
    /// - `a-b`＝a 桁目から b 桁目まで、`a-`＝a 桁目から行末まで、`a` 単独＝a 桁目から次の境界まで。
    /// - 空文字列は「定義なし」＝空配列（エラーではない）。
    /// - 桁が戻る／重なる／0 以下／上限超えは nil（黙って一部だけ通さない）。
    static func parse(_ text: String) -> [Int]? {
        let tokens = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        guard tokens.count <= maxFields else { return nil }

        var boundaries: [Int] = []
        var prevEnd = 0            // 直前の項目が閉じた桁（0＝まだ無い）
        for token in tokens {
            guard let field = parseToken(token) else { return nil }
            guard field.start > prevEnd else { return nil }        // 桁が戻る／重なる
            if let end = field.end {
                guard end >= field.start, end <= maxColumn else { return nil }
                prevEnd = end
            } else {
                prevEnd = field.start                              // 開いた項目＝以降は書けない
            }
            if field.start > 1 { boundaries.append(field.start) }
            if let end = field.end { boundaries.append(end + 1) }
        }
        // 末尾が閉じている（`…-40`）ときの 41 は「そこで終わり」の印。行末までの項目が
        // 続く定義（`41-`）と区別するために残す。
        let unique = Array(Set(boundaries.filter { $0 >= 2 && $0 <= maxColumn + 1 })).sorted()
        return unique
    }

    /// 1 トークン → (開始桁, 終了桁 or nil＝行末まで)。
    private static func parseToken(_ token: String) -> (start: Int, end: Int?)? {
        let chars = Array(token)
        guard let dashIndex = chars.firstIndex(where: { dashes.contains($0) }) else {
            guard let n = number(String(chars)) else { return nil }
            return (n, nil)
        }
        guard let start = number(String(chars[chars.startIndex..<dashIndex])) else { return nil }
        let tail = String(chars[chars.index(after: dashIndex)...])
        if tail.isEmpty { return (start, nil) }
        guard let end = number(tail) else { return nil }
        return (start, end)
    }

    /// 半角/全角の数字だけからなる 1 以上の整数。
    private static func number(_ s: String) -> Int? {
        let normalized = String(s.map { ch -> Character in
            guard let v = ch.unicodeScalars.first?.value, (0xFF10...0xFF19).contains(v) else { return ch }
            return Character(UnicodeScalar(v - 0xFF10 + 0x30)!)
        })
        guard !normalized.isEmpty, normalized.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(normalized),
              n >= 1, n <= maxColumn else { return nil }
        return n
    }

    /// いまのガイドを `1-8,9-14,15-` の形で書き出す（ダイアログの初期値）。
    ///
    /// 最後の項目は**行末まで開いている**。ガイドは切れ目しか持たないので、
    /// 「どこで終わるか」を勝手に決めない。
    static func text(for guides: ColumnGuides) -> String {
        let bounds = guides.columns.filter { $0 > 1 }
        guard !bounds.isEmpty else { return "" }
        var parts: [String] = []
        var start = 1
        for b in bounds {
            if b - 1 >= start { parts.append("\(start)-\(b - 1)") }
            start = b
        }
        parts.append("\(start)-")
        return parts.joined(separator: ",")
    }
}
