import AppKit

/// 差分の位置を溝（knob slot）に描くスクローラ。
///
/// 8,600 万行を並べたとき、「どこに差分があるか」はスクロールバーでしか分からない。
/// 差分が上の方に 3 箇所、末尾に 1 箇所、という全体像が一目で見えることが、
/// 巨大ファイルの diff では本文と同じくらい効く。
final class DiffScroller: NSScroller {

    /// 差分の位置（0...1 の相対位置と、その種類）。溝に色の目盛りとして描く。
    struct Marker {
        enum Kind { case delete, insert, replace }
        let position: Double
        let kind: Kind
    }

    var markers: [Marker] = [] { didSet { needsDisplay = true } }

    private func color(_ k: Marker.Kind) -> NSColor {
        switch k {
        case .delete:  return NSColor.systemRed.withAlphaComponent(0.75)
        case .insert:  return NSColor.systemGreen.withAlphaComponent(0.75)
        case .replace: return NSColor.systemYellow.withAlphaComponent(0.75)
        }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        super.drawKnobSlot(in: slotRect, highlight: flag)
        guard !markers.isEmpty else { return }

        // 目盛りは最低 2pt の高さを持たせる（1 行分の差分でも見えるように）。
        let h = max(2.0, slotRect.height / 400)
        for m in markers {
            let y = slotRect.minY + CGFloat(m.position) * (slotRect.height - h)
            color(m.kind).setFill()
            NSRect(x: slotRect.minX + 2, y: y, width: slotRect.width - 4, height: h).fill()
        }
    }
}
