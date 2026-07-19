import AppKit
import XCTest
@testable import MrEditor

final class ANSIColorTests: XCTestCase {
    private let palette = ANSIPalette.from(theme: EditorTheme.builtin(.system))
    private let base: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]

    /// エスケープを含まない行は nil（呼び出し側は従来経路へ）。
    func testNoEscapeReturnsNil() {
        XCTAssertNil(ANSIColor.attributed("plain log line", base: base, palette: palette))
    }

    /// エスケープが除去され、可視テキストだけ残る。
    func testStripsEscapes() {
        let line = "\u{1B}[31mERROR\u{1B}[0m done"
        let r = ANSIColor.attributed(line, base: base, palette: palette)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.plain, "ERROR done")
        XCTAssertEqual(r?.attributed.string, "ERROR done")
    }

    /// 前景色が SGR で切り替わり、reset で既定へ戻る。
    func testForegroundColorRuns() {
        let line = "\u{1B}[31mRED\u{1B}[0mX"
        guard let r = ANSIColor.attributed(line, base: base, palette: palette) else { return XCTFail() }
        let attr = r.attributed
        // "RED" は赤（palette[1]）、"X" は色属性なし（既定前景）。
        let redColor = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(redColor, ANSIPalette.xterm16[1])
        let xColor = attr.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        XCTAssertNil(xColor)
    }

    /// 背景色（40–47）と高輝度前景（90–97）。
    func testBackgroundAndBright() {
        let line = "\u{1B}[42;91mhi\u{1B}[0m"
        guard let r = ANSIColor.attributed(line, base: base, palette: palette) else { return XCTFail() }
        let fg = r.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let bg = r.attributed.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(fg, ANSIPalette.xterm16[9])   // 91 = bright red
        XCTAssertEqual(bg, ANSIPalette.xterm16[2])   // 42 = green bg
    }

    /// 256 色（38;5;n）と truecolor（38;2;r;g;b）。
    func testExtendedColors() {
        let c256 = ANSIColor.attributed("\u{1B}[38;5;196mX\u{1B}[0m", base: base, palette: palette)
        XCTAssertNotNil(c256?.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        let truecolor = ANSIColor.attributed("\u{1B}[38;2;10;20;30mX", base: base, palette: palette)
        let c = truecolor?.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let s = c?.usingColorSpace(.sRGB)
        XCTAssertEqual(s?.redComponent ?? -1, 10.0 / 255, accuracy: 0.001)
        XCTAssertEqual(s?.blueComponent ?? -1, 30.0 / 255, accuracy: 0.001)
    }

    /// 太字・下線が属性へ反映される。
    func testBoldUnderline() {
        let line = "\u{1B}[1;4mX\u{1B}[0m"
        guard let r = ANSIColor.attributed(line, base: base, palette: palette) else { return XCTFail() }
        XCTAssertNotNil(r.attributed.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        let font = r.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let bold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
        XCTAssertTrue(bold)
    }

    /// SGR 以外の CSI（カーソル移動など）も表示から除去される。
    func testNonSGRCSIStripped() {
        let line = "a\u{1B}[2Kb\u{1B}[10;5Hc"
        let r = ANSIColor.attributed(line, base: base, palette: palette)
        XCTAssertEqual(r?.plain, "abc")
    }
}
