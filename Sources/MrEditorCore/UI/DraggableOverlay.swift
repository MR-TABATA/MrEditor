import AppKit

/// 本文の上に浮かぶ小窓を「掴んで動かせる」ようにする取り付け具。
///
/// 小窓（検索バー・各バナー）は Auto Layout で辺に張り付けてある。動かすために制約を
/// 外して frame 直置きにすると、窓のリサイズで全部自分で面倒を見ることになる。
/// **制約はそのままに、定数だけをずらす。** はみ出しの判定は `OverlayPlacement`（純ロジック）。
///
/// 掴めるのは**背景**だけ。ボタンやテキストフィールドの上で始まったドラッグは掴みにしない
/// （検索欄の文字を選ぼうとしたらバーごと動いた、を起こさない）。
final class DraggableOverlay: NSObject {
    /// 位置を覚えるときの名前（AppSettings のキー）。
    let name: String

    private weak var view: NSView?
    private weak var container: NSView?
    private let horizontal: NSLayoutConstraint
    private let vertical: NSLayoutConstraint
    private let horizontalAnchor: OverlayPlacement.Anchor
    private let verticalAnchor: OverlayPlacement.Anchor
    /// ドラッグしていないときの定数（＝既定位置）。ここへ戻せば「位置を戻す」になる。
    private let baseX: CGFloat
    /// 縦の既定位置。**呼ぶ側が動かすことがある**（構造化バナーが出たら検索バーを一段下げる、など）。
    /// 制約の定数を直接書き換えられると掴んだ位置が消えるので、必ずここを通す。
    private var baseY: CGFloat
    /// 実際に置いてあるずらし量（窓に収まるよう丸めた後）。
    private(set) var offset: CGPoint = .zero
    /// **利用者が望んだ**ずらし量（丸める前）。窓が小さくて置けないときも、これは覚えておく。
    /// ここを分けないと、まだ大きさの決まっていない起動直後に 0 へ丸められ、覚えた位置が消える。
    private var desired: CGPoint = .zero

    private var dragStart: CGPoint?
    private var dragOrigin: CGPoint = .zero

    init(name: String, view: NSView, container: NSView,
         horizontal: NSLayoutConstraint, horizontalAnchor: OverlayPlacement.Anchor,
         vertical: NSLayoutConstraint, verticalAnchor: OverlayPlacement.Anchor) {
        self.name = name
        self.view = view
        self.container = container
        self.horizontal = horizontal
        self.vertical = vertical
        self.horizontalAnchor = horizontalAnchor
        self.verticalAnchor = verticalAnchor
        self.baseX = horizontal.constant
        self.baseY = vertical.constant
        super.init()

        let pan = NSPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        applyStored()
    }

    // MARK: - 位置

    /// 覚えてある位置を当てる（窓の大きさに合わせて丸め直す）。
    func applyStored() {
        set(offset: AppSettings.overlayOffset(for: name), save: false)
    }

    /// 窓の大きさが変わったとき、望んだ位置を今の大きさへ当て直す。
    /// **丸めた後の値ではなく望んだ値**から引き直すので、広げれば元の位置へ戻る。
    func reclamp() {
        set(offset: desired, save: false)
    }

    /// 縦の既定位置を差し替える（掴んだぶんのずらしは保ったまま置き直す）。
    func setBaseY(_ y: CGFloat) {
        guard y != baseY else { return }
        baseY = y
        set(offset: desired, save: false)
    }

    /// 既定位置へ戻す（覚えている位置も忘れる）。
    func reset() {
        set(offset: .zero, save: true)
    }

    private func set(offset requested: CGPoint, save: Bool) {
        desired = requested
        guard let view, let container else { return }
        let clamped = OverlayPlacement.restore(offset: requested, baseX: baseX, baseY: baseY,
                                               size: view.frame.size, container: container.frame.size,
                                               horizontal: horizontalAnchor, vertical: verticalAnchor)
        offset = clamped
        horizontal.constant = baseX + clamped.x
        vertical.constant = baseY + clamped.y
        if save { AppSettings.setOverlayOffset(desired, for: name) }
    }

    // MARK: - ドラッグ

    @objc private func panned(_ g: NSPanGestureRecognizer) {
        guard let view else { return }
        switch g.state {
        case .began:
            dragOrigin = offset
            dragStart = g.location(in: view.superview)
        case .changed:
            guard let start = dragStart else { return }
            let now = g.location(in: view.superview)
            // superview は反転していない（下が原点）ので、上下は符号を反転して「下へ動かす＝定数が増える」に合わせる。
            set(offset: CGPoint(x: dragOrigin.x + (now.x - start.x),
                                y: dragOrigin.y - (now.y - start.y)), save: false)
        case .ended, .cancelled:
            dragStart = nil
            // 覚えるのは**丸めた後**の位置。窓の外まで引っぱった値を覚えると、
            // 次に大きい窓で開いたときに遠くへ飛ぶ。
            set(offset: offset, save: true)
        default:
            break
        }
    }
}

extension DraggableOverlay: NSGestureRecognizerDelegate {
    /// **操作できる部品の上でだけ掴みを譲る。** それ以外（背景・ラベル・アイコン）は掴める。
    ///
    /// 「バー本体の上だけ掴める」にすると、見た目には隙間でも実際は件数ラベルが敷いてあって
    /// どこも掴めない、が起きる（実際に起きた）。判定を**部品側**に置くとそれが無くなる。
    func gestureRecognizerShouldBegin(_ g: NSGestureRecognizer) -> Bool {
        guard let view else { return false }
        let p = g.location(in: view)
        guard let hit = view.hitTest(view.convert(p, to: view.superview)) else { return true }
        var node: NSView? = hit
        while let n = node, n !== view {
            if Self.isInteractive(n) { return false }
            node = n.superview
        }
        return true
    }

    /// 押す・打つ・選ぶができる部品か。ラベル（編集も選択もできない NSTextField）は含めない。
    private static func isInteractive(_ v: NSView) -> Bool {
        if let field = v as? NSTextField { return field.isEditable || field.isSelectable }
        if let text = v as? NSText { return text.isEditable || text.isSelectable }
        if v is NSButton || v is NSSegmentedControl || v is NSPopUpButton
            || v is NSSlider || v is NSStepper || v is NSComboBox { return true }
        return false
    }
}
