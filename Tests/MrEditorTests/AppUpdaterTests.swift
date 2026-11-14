import XCTest
@testable import MrEditorCore

/// 自動更新（Sparkle）の入口。更新の行き先はバンドルが名乗り、名乗っていなければ何もしない。
final class AppUpdaterTests: XCTestCase {

    /// **開発ビルドや別のバンドルに、配布版の更新を勧めさせない。**
    func testUpdateFeedComesFromBundleDeclaration() {
        XCTAssertEqual(AppInfo.updateFeed(from: "https://mrktools.app/downloads/mreditor/appcast.xml"),
                       URL(string: "https://mrktools.app/downloads/mreditor/appcast.xml"))
        XCTAssertNil(AppInfo.updateFeed(from: nil))          // 宣言なし（開発ビルド）
        XCTAssertNil(AppInfo.updateFeed(from: ""))           // 空文字は「無し」
        XCTAssertNil(AppInfo.updateFeed(from: "   "))        // 空白だけも「無し」
        XCTAssertNil(AppInfo.updateFeed(from: 42))           // 文字列でない
    }

    /// feed は、Sparkle が読むキー（SUFeedURL）で宣言する。
    func testFeedKeyIsSparkles() {
        XCTAssertEqual(AppInfo.updateFeedKey, "SUFeedURL")
    }

    /// テストはバンドル無しで走るので、更新確認は無効（ネットワークを叩かない）。
    func testUpdaterIsUnavailableWithoutDeclaration() {
        guard AppInfo.updateFeedURL == nil else {
            return XCTFail("テスト実行環境が feed を宣言している")
        }
        XCTAssertFalse(AppUpdater.isAvailable)
    }
}

/// 「起動時に確認する」は、Sparkle 自身の保存値が唯一の本物。起動のたびに、こちらから上書きしない。
@MainActor
final class AppUpdaterSettingTests: XCTestCase {

    private final class FakeBackend: UpdaterBackend {
        var automaticallyChecksForUpdates: Bool
        var started = false
        var manualChecks = 0
        init(_ initial: Bool) { automaticallyChecksForUpdates = initial }
        func start() { started = true }
        func checkForUpdates() { manualChecks += 1 }
    }

    private let legacyKey = "MrEditor.automaticUpdateChecks"
    private var savedLegacy: Any?

    override func setUp() {
        super.setUp()
        savedLegacy = UserDefaults.standard.object(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    override func tearDown() {
        if let savedLegacy {
            UserDefaults.standard.set(savedLegacy, forKey: legacyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        super.tearDown()
    }

    /// 利用者が Sparkle 側で選んだ値を、起動のたびに上書きしない（上書きすると、確認のスケジュールも
    /// リセットされる）。
    func testStartDoesNotOverwriteTheValueSparkleKeeps() {
        for stored in [true, false] {
            let backend = FakeBackend(stored)
            AppUpdater(backend: backend).start()
            XCTAssertEqual(backend.automaticallyChecksForUpdates, stored, "Sparkle の保存値 \(stored) を、そのまま使う")
            XCTAssertTrue(backend.started)
        }
    }

    /// 1.28.0 までに、「確認しない」を選んだ人が、更新で「確認する」へ戻らない。引き継ぐのは 1 度だけ。
    func testALegacyChoiceIsCarriedOverOnceAndThenRemoved() {
        UserDefaults.standard.set(false, forKey: legacyKey)
        let first = FakeBackend(true)
        AppUpdater(backend: first).start()
        XCTAssertFalse(first.automaticallyChecksForUpdates, "自前の保存値（OFF）を、Sparkle へ引き継ぐ")
        XCTAssertNil(UserDefaults.standard.object(forKey: legacyKey), "引き継いだら、自前の保存値は消す")

        // その後、利用者が Sparkle 側で ON にしても、次の起動で、古い値に戻されない。
        let second = FakeBackend(true)
        AppUpdater(backend: second).start()
        XCTAssertTrue(second.automaticallyChecksForUpdates)
    }

    func testTogglingThePreferenceReachesTheUpdaterAndIsReadBack() {
        let backend = FakeBackend(true)
        let updater = AppUpdater(backend: backend)
        XCTAssertTrue(updater.automaticChecks)
        updater.setAutomaticChecks(false)
        XCTAssertFalse(backend.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticChecks, "画面の表示は、Sparkle の値を読む（二重に持たない）")
        updater.setAutomaticChecks(true)
        XCTAssertTrue(updater.automaticChecks)
    }

    func testManualCheckIsForwardedAndNothingHappensWithoutABackend() {
        let backend = FakeBackend(true)
        AppUpdater(backend: backend).checkForUpdates()
        XCTAssertEqual(backend.manualChecks, 1)

        let none = AppUpdater(backend: nil)   // feed を宣言していない .app（開発ビルド）
        none.start(); none.checkForUpdates(); none.setAutomaticChecks(false)   // 落ちない・何も起きない
        XCTAssertFalse(none.automaticChecks)
    }
}
