import XCTest
import AppKit
@testable import MrEditor

/// `EditorTheme` のプリセット解決・カスタム色の永続化・変更通知を検証する。
/// UserDefaults.standard を触るため、各テストで元の値へ復元する。
final class EditorThemeTests: XCTestCase {

    private var savedPreset: ThemePreset!
    private var savedCustom: [EditorTheme.ColorKey: NSColor] = [:]
    private var savedOpacity: CGFloat = 1.0
    private var savedANSI = true

    override func setUp() {
        super.setUp()
        savedPreset = EditorTheme.preset
        savedOpacity = EditorTheme.backgroundOpacity
        savedANSI = EditorTheme.ansiColorsEnabled
        for key in EditorTheme.ColorKey.allCases { savedCustom[key] = EditorTheme.customColor(key) }
    }

    override func tearDown() {
        // custom 色を戻す（setCustomColor は preset を .custom にするので、preset 復元は最後）。
        for key in EditorTheme.ColorKey.allCases {
            if let c = savedCustom[key] { EditorTheme.setCustomColor(key, c) }
        }
        EditorTheme.backgroundOpacity = savedOpacity
        EditorTheme.ansiColorsEnabled = savedANSI
        EditorTheme.preset = savedPreset
        super.tearDown()
    }

    func testDefaultSystemUsesSemanticColors() {
        EditorTheme.preset = .system
        let t = EditorTheme.current()
        // 既存ハードコード値（セマンティック色）と一致＝既定で現状と同じ見た目。
        XCTAssertEqual(t.foreground, NSColor.textColor)
        XCTAssertEqual(t.background, NSColor.textBackgroundColor)
        XCTAssertEqual(t.selection, NSColor.selectedTextBackgroundColor)
    }

    func testPresetReturnsFixedColors() {
        EditorTheme.preset = .solarizedDark
        let bg = EditorTheme.current().background.usingColorSpace(.sRGB)!
        // Solarized Dark 背景 #002B36。
        XCTAssertEqual(bg.redComponent, 0x00 / 255.0, accuracy: 0.01)
        XCTAssertEqual(bg.greenComponent, 0x2B / 255.0, accuracy: 0.01)
        XCTAssertEqual(bg.blueComponent, 0x36 / 255.0, accuracy: 0.01)
    }

    func testSetCustomColorSwitchesToCustomAndRoundTrips() {
        let picked = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        EditorTheme.setCustomColor(.foreground, picked)
        XCTAssertEqual(EditorTheme.preset, .custom)
        let got = EditorTheme.current().foreground.usingColorSpace(.sRGB)!
        XCTAssertEqual(got.redComponent, 0.2, accuracy: 0.001)
        XCTAssertEqual(got.greenComponent, 0.4, accuracy: 0.001)
        XCTAssertEqual(got.blueComponent, 0.6, accuracy: 0.001)
        XCTAssertEqual(got.alphaComponent, 0.5, accuracy: 0.001)   // alpha も保たれる
    }

    func testBackgroundOpacityClampsAndPersists() {
        EditorTheme.backgroundOpacity = 0.6
        XCTAssertEqual(EditorTheme.backgroundOpacity, 0.6, accuracy: 0.001)
        XCTAssertFalse(EditorTheme.isOpaqueBackground)
        // 範囲外はクランプ（0.30–1.00）。
        EditorTheme.backgroundOpacity = 5.0
        XCTAssertEqual(EditorTheme.backgroundOpacity, 1.0, accuracy: 0.001)
        XCTAssertTrue(EditorTheme.isOpaqueBackground)
        EditorTheme.backgroundOpacity = 0.0
        XCTAssertEqual(EditorTheme.backgroundOpacity, 0.30, accuracy: 0.001)
    }

    func testWithBackgroundOpacityMultipliesAlpha() {
        EditorTheme.backgroundOpacity = 1.0
        let opaque = NSColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        // 完全不透明時は素通し（同一インスタンス）。
        XCTAssertEqual(EditorTheme.withBackgroundOpacity(opaque), opaque)
        EditorTheme.backgroundOpacity = 0.5
        let half = EditorTheme.withBackgroundOpacity(opaque)
        XCTAssertEqual(half.alphaComponent, 0.5, accuracy: 0.001)
        // 元の alpha も尊重して乗算される。
        let semi = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4)
        XCTAssertEqual(EditorTheme.withBackgroundOpacity(semi).alphaComponent, 0.2, accuracy: 0.001)
    }

    func testAnsiColorsEnabledDefaultsOnAndToggles() {
        EditorTheme.ansiColorsEnabled = true
        XCTAssertTrue(EditorTheme.ansiColorsEnabled)
        EditorTheme.ansiColorsEnabled = false
        XCTAssertFalse(EditorTheme.ansiColorsEnabled)
    }

    func testOpacityAndAnsiPostNotification() {
        let e1 = expectation(forNotification: .mrEditorDisplayChanged, object: nil)
        EditorTheme.backgroundOpacity = 0.7
        wait(for: [e1], timeout: 1)
        let e2 = expectation(forNotification: .mrEditorDisplayChanged, object: nil)
        EditorTheme.ansiColorsEnabled.toggle()
        wait(for: [e2], timeout: 1)
    }

    func testChangePostsDisplayNotification() {
        let presetExp = expectation(forNotification: .mrEditorDisplayChanged, object: nil)
        EditorTheme.preset = .monokai
        wait(for: [presetExp], timeout: 1)

        let colorExp = expectation(forNotification: .mrEditorDisplayChanged, object: nil)
        EditorTheme.setCustomColor(.background, .white)
        wait(for: [colorExp], timeout: 1)
    }
}
