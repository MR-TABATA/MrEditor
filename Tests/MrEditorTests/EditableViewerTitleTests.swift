import XCTest
import AppKit
@testable import MrEditorCore

/// 未保存の新規ドキュメントのタブ名（先頭行）が、いつ・何回、通知されるか。要望 #133。
final class EditableViewerTitleTests: XCTestCase {
    private var viewer: EditableViewer!
    private var notified = 0

    override func setUp() {
        super.setUp()
        viewer = EditableViewer()
        notified = 0
        viewer.onTitleChange = { [unowned self] in notified += 1 }
    }

    private func end(of text: String) -> Int { (text as NSString).length }

    // MARK: 先頭行が変わったときだけ通知する

    func testTypingOnTheFirstLineNotifiesOnce() {
        viewer.newDocument()
        viewer._testEdit(range: NSRange(location: 0, length: 0), with: "hello")
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(viewer.autoTitle, "hello")
    }

    func testEditingALaterLineDoesNotNotify() {
        viewer.restoreUntitled(text: "title\nbody", dirty: false)
        viewer._testEdit(range: NSRange(location: end(of: "title\nbody"), length: 0), with: " more")
        XCTAssertEqual(notified, 0)
        XCTAssertEqual(viewer.autoTitle, "title")
    }

    func testEditingTheFirstLineAfterwardsNotifies() {
        viewer.restoreUntitled(text: "title\nbody", dirty: false)
        viewer._testEdit(range: NSRange(location: 0, length: 0), with: "X")
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(viewer.autoTitle, "Xtitle")
    }

    /// 先頭の空白行は飛ばして、最初の中身のある行が名前になる。その行より後ろの編集では通知しない。
    func testLeadingBlankLinesAreSkippedAndLaterEditsStaySilent() {
        let text = "\n\n  \nreal title\nrest"
        viewer.restoreUntitled(text: text, dirty: false)
        XCTAssertEqual(viewer.autoTitle, "real title")
        viewer._testEdit(range: NSRange(location: end(of: text), length: 0), with: "!")
        XCTAssertEqual(notified, 0)
    }

    /// 空白だけを打っても、名前は付かない（nil のまま変わらない）ので、通知しない。
    func testBlankTypingOnAnEmptyDocumentDoesNotNotify() {
        viewer.newDocument()
        viewer._testEdit(range: NSRange(location: 0, length: 0), with: "   ")
        XCTAssertNil(viewer.autoTitle)
        XCTAssertEqual(notified, 0)
    }

    /// 先頭行を消すと名前が無くなる（呼び出し側が「名称未設定」に戻す）。そのとき 1 回通知する。
    func testClearingTheFirstLineNotifiesAndLeavesNoTitle() {
        viewer.restoreUntitled(text: "title", dirty: false)
        viewer._testEdit(range: NSRange(location: 0, length: 5), with: "")
        XCTAssertEqual(notified, 1)
        XCTAssertNil(viewer.autoTitle)
    }

    // MARK: 下書きの復元（lastAutoTitle の初期化）

    /// 復元そのものでは通知しない。復元した本文の先頭行が、そのまま「いまの名前」になる。
    func testRestoringADraftDoesNotNotifyAndSeedsTheTitle() {
        viewer.restoreDraft(id: "draft-id", text: "Draft title\nrest", dirty: true)
        XCTAssertEqual(notified, 0)
        XCTAssertEqual(viewer.autoTitle, "Draft title")
    }

    /// 復元した本文の先頭行を変えない編集では、通知しない（復元時の値を覚えているから）。
    func testAfterARestoreAnEditThatKeepsTheFirstLineDoesNotNotify() {
        viewer.restoreDraft(id: "draft-id", text: "Draft title\nrest", dirty: true)
        viewer._testEdit(range: NSRange(location: end(of: "Draft title\nrest"), length: 0), with: "\nmore")
        XCTAssertEqual(notified, 0)
    }

    func testAfterARestoreChangingTheFirstLineNotifies() {
        viewer.restoreDraft(id: "draft-id", text: "Draft title\nrest", dirty: true)
        viewer._testEdit(range: NSRange(location: 5, length: 0), with: "!")
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(viewer.autoTitle, "Draft! title")
    }

    // MARK: 保存先のあるドキュメントは対象外

    func testADocumentWithAFileHasNoAutoTitleAndNeverNotifies() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mreditor-title-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "saved name\nbody".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(viewer.open(url: url))

        XCTAssertNil(viewer.autoTitle)
        viewer._testEdit(range: NSRange(location: 0, length: 0), with: "X")
        XCTAssertEqual(notified, 0)
    }
}
