import XCTest
@testable import MrEditorCore

/// 浮きパネルのずらし量が、窓の内側に収まること。
///
/// **ここが緩いと「動かしたら画面の外に消えて二度と戻せない」になる。**
/// 窓を縮めたときも同じで、覚えてある位置をそのまま当てると外に残る。
final class OverlayPlacementTests: XCTestCase {

    // 容器 1000、小窓 440 で考える。

    func testLeadingAnchorStaysInside() {
        // 左端から 14pt の位置。左へは 14 までしか動けない。
        let c = OverlayPlacement.clamp(offset: -100, base: 14, size: 440, container: 1000, anchor: .leading)
        XCTAssertEqual(c, -14)
        // 右へは 1000-440-14 = 546 まで。
        XCTAssertEqual(OverlayPlacement.clamp(offset: 900, base: 14, size: 440, container: 1000, anchor: .leading), 546)
    }

    func testLeadingAnchorPassesThroughInsideRange() {
        XCTAssertEqual(OverlayPlacement.clamp(offset: 120, base: 14, size: 440, container: 1000, anchor: .leading), 120)
    }

    func testTrailingAnchorStaysInside() {
        // 右端から 28pt（制約の定数は -28）。右へは 28 までしか動けない。
        XCTAssertEqual(OverlayPlacement.clamp(offset: 500, base: -28, size: 440, container: 1000, anchor: .trailing), 28)
        // 左へは 440-1000+28 = -532 まで。
        XCTAssertEqual(OverlayPlacement.clamp(offset: -900, base: -28, size: 440, container: 1000, anchor: .trailing), -532)
    }

    /// 窓が小窓より狭いときは動かさない（どこへ置いてもはみ出すので、既定位置のまま）。
    func testTooSmallContainerKeepsDefault() {
        XCTAssertEqual(OverlayPlacement.clamp(offset: 200, base: 14, size: 440, container: 300, anchor: .leading), 0)
        XCTAssertEqual(OverlayPlacement.clamp(offset: -200, base: -28, size: 440, container: 300, anchor: .trailing), 0)
    }

    /// 覚えてある位置を、縮んだ窓へ当てはめ直す（外に残さない）。
    func testRestoreClampsBothAxes() {
        let p = OverlayPlacement.restore(offset: CGPoint(x: -900, y: 800),
                                         baseX: -28, baseY: 10,
                                         size: CGSize(width: 440, height: 32),
                                         container: CGSize(width: 1000, height: 600),
                                         horizontal: .trailing, vertical: .leading)
        XCTAssertEqual(p.x, -532)
        XCTAssertEqual(p.y, 600 - 32 - 10)
    }

    /// 動かしていない（0）ならそのまま 0（既定位置）。
    func testZeroOffsetStaysZero() {
        let p = OverlayPlacement.restore(offset: .zero, baseX: -28, baseY: 10,
                                         size: CGSize(width: 440, height: 32),
                                         container: CGSize(width: 1000, height: 600),
                                         horizontal: .trailing, vertical: .leading)
        XCTAssertEqual(p, .zero)
    }
}
