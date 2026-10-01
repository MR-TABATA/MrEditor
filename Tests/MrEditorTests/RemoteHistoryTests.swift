import XCTest
@testable import MrEditorCore

final class RemoteHistoryTests: XCTestCase {

    func testNewestFirstAndNoDuplicates() {
        var list: [String] = []
        list = RemoteHistory.adding("a:/1", to: list)
        list = RemoteHistory.adding("b:/2", to: list)
        list = RemoteHistory.adding("a:/1", to: list)
        XCTAssertEqual(list, ["a:/1", "b:/2"])
    }

    func testCapsAtLimitDroppingTheOldest() {
        var list: [String] = []
        for i in 0..<(RemoteHistory.limit + 3) { list = RemoteHistory.adding("h:/\(i)", to: list) }
        XCTAssertEqual(list.count, RemoteHistory.limit)
        XCTAssertEqual(list.first, "h:/\(RemoteHistory.limit + 2)")
        XCTAssertFalse(list.contains("h:/0"))
    }

    func testBlankIsIgnored() {
        XCTAssertEqual(RemoteHistory.adding("  ", to: ["a:/1"]), ["a:/1"])
    }

    func testPersistsThroughUserDefaults() {
        let suite = "remote-history-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        RemoteHistory.record("a:/1", d)
        RemoteHistory.record("b:/2", d)
        XCTAssertEqual(RemoteHistory.load(d), ["b:/2", "a:/1"])
        RemoteHistory.clear(d)
        XCTAssertEqual(RemoteHistory.load(d), [])
    }
}
