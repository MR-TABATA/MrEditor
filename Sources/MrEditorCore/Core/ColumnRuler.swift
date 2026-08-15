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
