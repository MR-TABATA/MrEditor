import XCTest
import AppKit
@testable import MrEditorCore

/// サイドバーの 1 行だけの名前の差し替え（`setName`）。未保存の新規ドキュメントの先頭行が変わったときに使う。
final class SidebarViewSetNameTests: XCTestCase {
    private func names(in sidebar: SidebarView) -> [String] {
        var rows: [SidebarRow] = []
        var queue: [NSView] = [sidebar]
        while let view = queue.popLast() {
            if let row = view as? SidebarRow { rows.append(row) }
            queue.append(contentsOf: view.subviews)
        }
        return rows.sorted { $0.index < $1.index }.map { $0.label.stringValue }
    }

    private func makeSidebar() -> SidebarView {
        let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        sidebar.reload(names: ["alpha", "beta", "gamma"], dirty: [false, true, false], active: 0)
        return sidebar
    }

    func testSetNameChangesOnlyThatRow() {
        let sidebar = makeSidebar()
        sidebar.setName(1, "beta renamed")
        XCTAssertEqual(names(in: sidebar), ["alpha", "beta renamed", "gamma"])
    }

    func testOutOfRangeIndexesChangeNothing() {
        let sidebar = makeSidebar()
        sidebar.setName(-1, "x")
        sidebar.setName(3, "x")
        sidebar.setName(99, "x")
        XCTAssertEqual(names(in: sidebar), ["alpha", "beta", "gamma"])
    }

    /// 名前だけを替える。行は作り直さない（未保存の目印は、そのまま）。
    func testSetNameKeepsTheRowsAndTheirState() {
        let sidebar = makeSidebar()
        let before = Set(sidebar.subviews.flatMap { $0.subviews }.map { ObjectIdentifier($0) })
        sidebar.setName(1, "beta renamed")
        let after = Set(sidebar.subviews.flatMap { $0.subviews }.map { ObjectIdentifier($0) })
        XCTAssertEqual(before, after, "setName は行を作り直さない")
    }
}
