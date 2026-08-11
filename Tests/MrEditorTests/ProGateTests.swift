import XCTest
@testable import MrEditorCore

/// 課金境界の不変条件。
///
/// 2026-08-04 に時刻マージが「Pro のつもり」のまま無料版で出荷された事故の再発防止。
/// 判定が 1 箇所（`Pro`）に集まっていること自体をここで固定する。
final class ProGateTests: XCTestCase {

    private final class FakePro: ProProvider {
        var entitlement: ProEntitlement
        private(set) var activatedCount = 0
        init(_ e: ProEntitlement) { entitlement = e }
        func activate() { activatedCount += 1 }
    }

    override func tearDown() {
        Pro.resetForTesting()
        super.tearDown()
    }

    /// 無料ビルド（Pro を差し込まない）では、宣言済みの Pro 機能が 1 つも通らない。
    func testFreeBuildAllowsNoProFeature() {
        Pro.resetForTesting()
        XCTAssertFalse(Pro.isUnlocked)
        for feature in ProFeature.allCases {
            XCTAssertFalse(Pro.allows(feature), "無料ビルドで \(feature.rawValue) が通ってしまった")
        }
    }

    /// 差し込んでも、未ライセンス（買う前の Pro ビルド）なら無料と同じ。
    func testUnlicensedProBuildBehavesLikeFree() {
        Pro.install(FakePro(.free))
        XCTAssertFalse(Pro.isUnlocked)
        for feature in ProFeature.allCases {
            XCTAssertFalse(Pro.allows(feature))
        }
    }

    /// アクティベート済みなら全機能が通る。
    func testUnlockedAllowsEveryFeature() {
        Pro.install(FakePro(.unlocked(until: nil)))
        XCTAssertTrue(Pro.isUnlocked)
        for feature in ProFeature.allCases {
            XCTAssertTrue(Pro.allows(feature))
        }
    }

    /// `install` の時点ではまだ UI が無い。`activate()` は core が起動処理の最後で呼ぶ。
    func testActivateIsDeferredUntilCoreCallsIt() {
        let fake = FakePro(.unlocked(until: nil))
        Pro.install(fake)
        XCTAssertEqual(fake.activatedCount, 0, "install だけで activate してはいけない（メニューがまだ無い）")
        Pro.activateProvider()
        XCTAssertEqual(fake.activatedCount, 1)
    }

    /// 時刻マージは **Pro 機能ではない**（v1.11 で無料版として出荷済み・取り上げない）。
    /// Pro 側にあるのは「束ねる先がリモート」の `crossHostMerge` だけ。
    func testLocalTimeMergeIsNotGated() {
        XCTAssertFalse(ProFeature.allCases.contains { $0.rawValue.lowercased() == "timemerge" })
        XCTAssertTrue(ProFeature.allCases.contains(.crossHostMerge))
    }
}