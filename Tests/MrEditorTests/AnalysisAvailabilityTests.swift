import XCTest
@testable import MrEditorCore

/// 1.28.0 では、分析メニューとビュープリセットのボタンを出さない。
/// 入口を出すかどうかは `AnalysisAvailability.isEnabled` 1 か所で決まる。
/// これを true にするときは、同時にこのテストを直す（出すと決めた、という記録になる）。
final class AnalysisAvailabilityTests: XCTestCase {
    func testAnalysisEntryPointsAreHiddenInThisRelease() {
        XCTAssertFalse(AnalysisAvailability.isEnabled)
    }
}
