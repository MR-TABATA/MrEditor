import CoreGraphics

/// 本文の上に浮かぶ小窓（検索バー・各バナー）の置き場所の計算（UI 非依存の純ロジック）。
///
/// 浮かせる物が増えるたびに「どちらを下へ逃がすか」を足していくと、組み合わせのぶんだけ
/// 破綻する（1.11 で構造化中も検索できるようにした瞬間、右上で 2 つが重なった）。
/// **逃がし方を増やすのではなく、掴んで動かせるようにする。** ここはそのための、
/// 「ずらした量が窓からはみ出さないか」を決める計算だけを持つ。
enum OverlayPlacement {
    /// 小窓が張り付いている辺。制約の定数の意味が辺ごとに違うので、型で持つ。
    enum Anchor {
        /// 上端／左端からの距離（正の値）。
        case leading
        /// 上端／右端からの距離（**負の値**。trailing 制約の定数）。
        case trailing
    }

    /// ずらし量を、小窓が容器の内側に収まる範囲へ丸める。
    ///
    /// - Parameters:
    ///   - offset: 利用者がドラッグでずらした量。
    ///   - base: ドラッグ前の制約の定数（`Anchor` によって符号の意味が変わる）。
    ///   - size: 小窓の辺の長さ（幅または高さ）。
    ///   - container: 容器の辺の長さ。
    /// - Returns: 収まる範囲に丸めたずらし量。容器が小窓より小さいときは 0（＝既定位置のまま）。
    static func clamp(offset: CGFloat, base: CGFloat, size: CGFloat,
                      container: CGFloat, anchor: Anchor) -> CGFloat {
        guard container > size else { return 0 }
        switch anchor {
        case .leading:
            // 左端（上端）＝ base + offset。0 以上、container - size 以下。
            return min(max(offset, -base), container - size - base)
        case .trailing:
            // 右端（下端）＝ container + base + offset。size 以上、container 以下。
            return min(max(offset, size - container - base), -base)
        }
    }

    /// 覚えてあるずらし量を、いまの窓の大きさへ当てはめ直す。
    /// **窓を縮めたときに小窓が画面の外に残らない**ようにするためのもの。
    static func restore(offset: CGPoint, baseX: CGFloat, baseY: CGFloat,
                        size: CGSize, container: CGSize,
                        horizontal: Anchor, vertical: Anchor) -> CGPoint {
        CGPoint(x: clamp(offset: offset.x, base: baseX, size: size.width,
                         container: container.width, anchor: horizontal),
                y: clamp(offset: offset.y, base: baseY, size: size.height,
                         container: container.height, anchor: vertical))
    }
}
