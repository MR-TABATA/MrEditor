import XCTest
import AppKit
@testable import MrEditor
@testable import MrEditorCore

/// `EditorFont` の種別・サイズの永続化と、変更通知・等幅列挙を検証する。
/// UserDefaults.standard を触るため、各テストで元の値へ復元する。
final class EditorFontTests: XCTestCase {

    private var savedSize: CGFloat!
    private var savedName: String?

    override func setUp() {
        super.setUp()
        savedSize = EditorFont.currentSize
        savedName = EditorFont.currentName
    }

    override func tearDown() {
        EditorFont.setSize(savedSize)
        EditorFont.setName(savedName)
        super.tearDown()
    }

    func testSizeClampsToRange() {
        XCTAssertEqual(EditorFont.setSize(1000), EditorFont.maxSize)
        XCTAssertEqual(EditorFont.setSize(1), EditorFont.minSize)
        XCTAssertEqual(EditorFont.setSize(14), 14)
        XCTAssertEqual(EditorFont.currentSize, 14)
    }

    func testNameDrivesCurrentFont() {
        EditorFont.setName("Menlo")
        EditorFont.setSize(15)
        let f = EditorFont.current()
        XCTAssertEqual(f.familyName, "Menlo")
        XCTAssertEqual(f.pointSize, 15)
    }

    func testNilNameFallsBackToMonospace() {
        EditorFont.setName(nil)
        XCTAssertNil(EditorFont.currentName)
        // フォールバック鎖のいずれか（or システム等幅）で必ずフォントが得られる。
        XCTAssertTrue(EditorFont.current().isFixedPitch)
    }

    func testUnknownNameFallsBack() {
        EditorFont.setName("No Such Font 12345")
        // 生成不能名でもクラッシュせずフォールバックする。
        XCTAssertNotNil(EditorFont.current())
    }

    func testAvailableFamiliesAreMonospacedAndSorted() {
        let families = EditorFont.availableMonospaceFamilies()
        XCTAssertFalse(families.isEmpty)
        // 全て等幅で生成できる。
        for name in families {
            let f = NSFont(name: name, size: 12)
            XCTAssertNotNil(f, "family \(name) should instantiate")
            XCTAssertTrue(f?.isFixedPitch ?? false, "family \(name) should be monospaced")
        }
        // 大小無視でソート済み。
        XCTAssertEqual(families, families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testChangePostsNotification() {
        let sizeExp = expectation(forNotification: .mrEditorFontChanged, object: nil)
        EditorFont.setSize(16)
        wait(for: [sizeExp], timeout: 1)

        let nameExp = expectation(forNotification: .mrEditorFontChanged, object: nil)
        EditorFont.setName("Menlo")
        wait(for: [nameExp], timeout: 1)
    }
}
