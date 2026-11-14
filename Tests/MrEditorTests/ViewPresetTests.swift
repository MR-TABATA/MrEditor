import XCTest
@testable import MrEditorCore

/// ビュープリセット(C9)のシグネチャ一致・永続化・安全な適用を検証する。
final class ViewPresetTests: XCTestCase {

    // MARK: - シグネチャ一致

    func testMatchesRequiresSameModeAndColumnSet() {
        let preset = ViewPreset(name: "店舗別", mode: .csv,
                                columnOrder: ["name", "age", "city"], columnWidths: [:])
        XCTAssertTrue(preset.matches(mode: .csv, columns: ["name", "age", "city"]))
        XCTAssertTrue(preset.matches(mode: .csv, columns: ["city", "age", "name"]))   // 順不同で一致
        XCTAssertFalse(preset.matches(mode: .tsv, columns: ["name", "age", "city"]))  // mode 違い
        XCTAssertFalse(preset.matches(mode: .csv, columns: ["name", "age"]))          // 部分一致
        XCTAssertFalse(preset.matches(mode: .csv, columns: ["name", "age", "city", "role"])) // 列が増えた
    }

    // MARK: - 永続化（Codable往復・CRUD）

    private func makeStore() -> (ViewPresetStore, UserDefaults) {
        let suiteName = "ViewPresetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (ViewPresetStore(defaults: defaults), defaults)
    }

    override func tearDown() {
        // suiteName ごとに使い捨てているので個別のクリーンアップは不要。
        super.tearDown()
    }

    func testAddThenMatchingReturnsIt() {
        let (store, _) = makeStore()
        store.add(name: "店舗別", mode: .csv, order: ["a", "b"], widths: ["a": 5])
        let matches = store.matching(mode: .csv, columns: ["a", "b"])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].name, "店舗別")
        XCTAssertEqual(matches[0].columnOrder, ["a", "b"])
        XCTAssertEqual(matches[0].columnWidths, ["a": 5])
    }

    func testMatchingExcludesDifferentShape() {
        let (store, _) = makeStore()
        store.add(name: "A", mode: .csv, order: ["a", "b"], widths: [:])
        XCTAssertTrue(store.matching(mode: .csv, columns: ["x", "y"]).isEmpty)
        XCTAssertTrue(store.matching(mode: .tsv, columns: ["a", "b"]).isEmpty)
    }

    func testRenameUpdatesPersistedName() {
        let (store, _) = makeStore()
        let preset = store.add(name: "旧名", mode: .csv, order: ["a"], widths: [:])
        store.rename(id: preset.id, to: "新名")
        XCTAssertEqual(store.matching(mode: .csv, columns: ["a"]).first?.name, "新名")
    }

    func testDeleteRemovesFromMatching() {
        let (store, _) = makeStore()
        let preset = store.add(name: "A", mode: .csv, order: ["a"], widths: [:])
        store.delete(id: preset.id)
        XCTAssertTrue(store.matching(mode: .csv, columns: ["a"]).isEmpty)
    }

    func testMultiplePresetsCoexist() {
        let (store, _) = makeStore()
        store.add(name: "A", mode: .csv, order: ["a", "b"], widths: [:])
        store.add(name: "B", mode: .csv, order: ["a", "b"], widths: [:])
        XCTAssertEqual(store.matching(mode: .csv, columns: ["a", "b"]).count, 2)
    }

    // 「列構成がズレていても壊れない」実際の適用ロジック（`TabularFormatter.applyingLayout`）は
    // MrEditorCore の internal API。
    // MrEditor 側の TabularFormatterTests（testApplyingLayoutUnknownOrderKeyIsIgnored /
    // testApplyingLayoutMissingKeyStaysAtEndInOriginalOrder）がその性質を確認している。
}
