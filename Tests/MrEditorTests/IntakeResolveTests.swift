import XCTest
@testable import MrEditorCore

/// 開く先の解決。**判定を 1 か所に閉じる**ための入口なので、ここで固定する。
/// 割れると、コマンドライン・ドラッグ＆ドロップ・最近使った項目で挙動が食い違う。
final class IntakeResolveTests: XCTestCase {

    func testRemoteFormsResolveToRemote() {
        XCTAssertEqual(
            Intake.resolve("ssh web01:/var/log/app.log"),
            .remote(RemoteFile.Target(host: "web01", path: "/var/log/app.log"))
        )
        XCTAssertEqual(
            Intake.resolve("deploy@web01:/srv/app/current/log/production.log"),
            .remote(RemoteFile.Target(host: "deploy@web01", path: "/srv/app/current/log/production.log"))
        )
    }

    func testPlainPathsStayLocal() {
        XCTAssertEqual(Intake.resolve("/var/log/app.log"), .local(URL(fileURLWithPath: "/var/log/app.log")))
    }

    /// **曖昧なものは手元に倒す。** 遠隔に倒すと、うっかり ssh へ飛んでいく。
    func testAmbiguousStringsStayLocal() {
        for text in ["C:/Users/x/app.log", "web01:relative/path.log", "12:34:56.log", "app.log"] {
            guard case .local = Intake.resolve(text) else {
                return XCTFail("\(text) を遠隔と判定した")
            }
        }
    }

    func testTildeIsExpandedForLocalPaths() {
        guard case .local(let url) = Intake.resolve("~/app.log") else { return XCTFail("local を期待") }
        XCTAssertFalse(url.path.hasPrefix("~"))
        XCTAssertTrue(url.path.hasSuffix("/app.log"))
    }
}
