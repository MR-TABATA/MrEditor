import XCTest
@testable import MrEditorCore

/// 要望の受け口。**宣言したバンドルだけがメニューに出す**（同じ core から包む Pro 版に、
/// 無料版の要望ページを出さない）。URL の組み立ては、Issue フォームの欄に最初から入る値になる。
final class RequestURLTests: XCTestCase {

    func testUndeclaredOrBlankMeansNoRequestMenu() {
        XCTAssertNil(AppInfo.declaredURL(from: nil))        // 宣言なし（Pro の .app）
        XCTAssertNil(AppInfo.declaredURL(from: ""))
        XCTAssertNil(AppInfo.declaredURL(from: "   \n"))
        XCTAssertNil(AppInfo.declaredURL(from: 42))         // 文字列でない
        XCTAssertEqual(AppInfo.declaredURL(from: " https://example.com/x ")?.absoluteString, "https://example.com/x")
    }

    func testTheUpdateFeedStillBehavesTheSame() {
        XCTAssertNil(AppInfo.updateFeed(from: nil))
        XCTAssertNil(AppInfo.updateFeed(from: "  "))
        XCTAssertEqual(AppInfo.updateFeed(from: "https://api.github.com/x")?.absoluteString, "https://api.github.com/x")
    }

    func testVersionAndOSAreAddedAndTheTemplateIsKept() throws {
        let form = URL(string: "https://github.com/MR-TABATA/MrEditor/issues/new?template=request.yml")!
        let url = try XCTUnwrap(AppInfo.requestURL(form: form, version: "1.20.0", os: "macOS 26.0"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "template" }?.value, "request.yml")
        XCTAssertEqual(items.first { $0.name == "version" }?.value, "1.20.0")
        XCTAssertEqual(items.first { $0.name == "os" }?.value, "macOS 26.0")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/MR-TABATA/MrEditor/issues/new?"))
    }

    func testTheListPageFollowsTheLanguage() {
        let en = URL(string: "https://mr-tabata.github.io/MrEditor/requests.html")!
        XCTAssertEqual(AppInfo.requestListURL(base: en, japanese: false), en)
        XCTAssertEqual(AppInfo.requestListURL(base: en, japanese: true).absoluteString,
                       "https://mr-tabata.github.io/MrEditor/requests.ja.html")
        // .html でないものは、いじらない
        let other = URL(string: "https://example.com/requests")!
        XCTAssertEqual(AppInfo.requestListURL(base: other, japanese: true), other)
    }

    func testOSDescriptionOmitsAZeroPatch() {
        XCTAssertEqual(AppInfo.osDescription(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)), "macOS 26.0")
        XCTAssertEqual(AppInfo.osDescription(OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)), "macOS 15.6.1")
    }
}
