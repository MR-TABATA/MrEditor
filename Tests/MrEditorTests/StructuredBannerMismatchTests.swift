import XCTest
import AppKit
@testable import MrEditorCore

/// 構造化バナーの「列数が合わない行」の警告。ステータスバーより目に入る位置に出す。
final class StructuredBannerMismatchTests: XCTestCase {

    func testWarningAppearsOnlyWhenThereAreMismatchedRows() {
        let banner = StructuredBanner()
        banner.configure(mode: .csv)
        XCTAssertFalse(banner.mismatchVisibleForTesting, "不一致が無ければ、警告は出ない")

        banner.setMismatchCount(3)
        XCTAssertTrue(banner.mismatchVisibleForTesting)
        XCTAssertTrue(banner.mismatchTextForTesting.contains("3"), "件数が、文言に入る: \(banner.mismatchTextForTesting)")

        banner.setMismatchCount(0)
        XCTAssertFalse(banner.mismatchVisibleForTesting, "直して 0 件になったら、消える")
        XCTAssertEqual(banner.mismatchTextForTesting, "")
    }

    func testNextAndPrevCallbacksAreWired() {
        let banner = StructuredBanner()
        var next = 0, prev = 0
        banner.onMismatchNext = { next += 1 }
        banner.onMismatchPrev = { prev += 1 }
        banner.tapNextForTesting(); banner.tapNextForTesting(); banner.tapPrevForTesting()
        XCTAssertEqual(next, 2)
        XCTAssertEqual(prev, 1)
    }

    func testBannerStillFitsItsContentWithTheWarningShown() {
        let banner = StructuredBanner()
        banner.configure(mode: .csv)
        banner.setMismatchCount(12)
        banner.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(banner.fittingSize.width, 150, "警告を足しても、帯の幅が内容から決まる")
    }
}

/// タブを切り替えたとき、バナーの件数が、前のタブのまま残らないこと。
final class StructuredBannerTabSwitchTests: XCTestCase {

    private func structuredViewer(_ text: String, in dir: URL, name: String) throws -> EditableViewer {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let viewer = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(viewer.open(url: url))
        viewer.setStructuredMode(.csv)
        return viewer
    }

    func testBannerFollowsTheActiveTabAndIgnoresInactiveOnes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let uneven = try structuredViewer("a,b,c\n1,2,3\n1,2,3,4\n5,6\n", in: dir, name: "uneven.csv")
        let even = try structuredViewer("a,b\n1,2\n3,4\n", in: dir, name: "even.csv")

        let controller = MainWindowController()
        _ = controller.window
        controller.viewers = [uneven, even]
        controller.wire(uneven)
        controller.wire(even)

        controller.activate(0)
        XCTAssertTrue(controller.structuredBanner.mismatchVisibleForTesting, "不一致のある書類では、警告が出る")
        XCTAssertTrue(controller.structuredBanner.mismatchTextForTesting.contains("2"))

        controller.activate(1)
        XCTAssertFalse(controller.structuredBanner.mismatchVisibleForTesting, "合っている書類へ切り替えたら、警告が消える")

        // 見えていない書類からの通知で、いまの画面が書き換わらない。
        uneven.onColumnMismatchChange?(7)
        XCTAssertFalse(controller.structuredBanner.mismatchVisibleForTesting)

        controller.activate(0)
        XCTAssertTrue(controller.structuredBanner.mismatchVisibleForTesting, "戻ったら、また出る")
    }
}
