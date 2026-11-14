import XCTest
@testable import MrEditorCore

/// 古い版が UserDefaults に残した、いまは使わないキー（AI 設定・Pro 版の設定など）が、
/// 残っている設定の読み書きに影響しないこと。
final class LegacySettingsTests: XCTestCase {

    private let legacyKeys = [
        "MrEditor.ai.provider", "MrEditor.ai.model", "MrEditor.ai.baseURL",
        "MrEditor.ai.remembered.anthropic", "com.aaedit.MrkEditor.viewPresets"
    ]
    private var savedLegacy: [String: Any?] = [:]
    private var saved: (tab: Int, hl: Bool)!

    override func setUp() {
        super.setUp()
        saved = (AppSettings.tabWidth, AppSettings.highlightCurrentLine)
        let d = UserDefaults.standard
        for k in legacyKeys { savedLegacy[k] = d.object(forKey: k) }
    }

    override func tearDown() {
        AppSettings.tabWidth = saved.tab
        AppSettings.highlightCurrentLine = saved.hl
        let d = UserDefaults.standard
        for (k, v) in savedLegacy {
            if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    func testLeftoverKeysDoNotAffectRemainingSettings() {
        let d = UserDefaults.standard
        d.set("openai", forKey: "MrEditor.ai.provider")
        d.set("gpt-x", forKey: "MrEditor.ai.model")
        d.set("http://localhost:11434", forKey: "MrEditor.ai.baseURL")
        d.set(["m1", "m2"], forKey: "MrEditor.ai.remembered.anthropic")
        d.set(Data("not json".utf8), forKey: "com.aaedit.MrkEditor.viewPresets")

        AppSettings.tabWidth = 6
        AppSettings.highlightCurrentLine = false
        XCTAssertEqual(AppSettings.tabWidth, 6)
        XCTAssertFalse(AppSettings.highlightCurrentLine)
        AppSettings.tabWidth = 2
        XCTAssertEqual(AppSettings.tabWidth, 2, "書いた値が、そのまま読み戻せる")
    }
}
