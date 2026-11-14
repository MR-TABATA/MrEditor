import XCTest
import AppKit
@testable import MrEditorCore

/// 構造化表示（CSV）での、列数が合わない行の検出と「次へ / 前へ」のジャンプ。
/// 以前は有償判定（Pro）の内側にあり、判定を外したあとの挙動を固定する。
final class ColumnMismatchTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-mismatch-\(UUID().uuidString).csv")
    }

    /// 1 行目＝見出し（3 列）。3 行目は 4 列、4 行目は 2 列で、列数が合わない。
    private let uneven = "a,b,c\n1,2,3\n1,2,3,4\n5,6\n7,8,9\n"

    private func openStructured(_ text: String,
                                onChange: ((Int) -> Void)? = nil) throws -> (EditableViewer, URL) {
        let url = tempURL()
        try text.data(using: .utf8)!.write(to: url)
        let v = EditableViewer()
        v.onColumnMismatchChange = onChange
        XCTAssertTrue(v.open(url: url))
        v.setStructuredMode(.csv)
        XCTAssertEqual(v.structuredMode, .csv)
        return (v, url)
    }

    /// キャレットのある行（1 始まり）。
    private func caretLine(_ v: EditableViewer) -> Int {
        let ns = v._testText as NSString
        let location = min(v._testSelection.location, ns.length)
        let head = ns.substring(to: location)
        return head.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    func testCountsRowsWhoseColumnCountDiffers() throws {
        var reported: [Int] = []
        let (v, url) = try openStructured(uneven) { reported.append($0) }
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(v.columnMismatchCount, 2)
        XCTAssertEqual(reported.last, 2, "件数の変化が、ステータスバーへ通知される")
    }

    func testNextJumpVisitsMismatchesInOrderAndWraps() throws {
        let (v, url) = try openStructured(uneven)
        defer { try? FileManager.default.removeItem(at: url) }

        v.jumpToNextMismatchLine()
        XCTAssertEqual(caretLine(v), 3)
        v.jumpToNextMismatchLine()
        XCTAssertEqual(caretLine(v), 4)
        v.jumpToNextMismatchLine()
        XCTAssertEqual(caretLine(v), 3, "最後の次は、先頭の不一致行へ戻る")
    }

    func testPrevJumpStartsFromTheLastMismatchAndGoesBackwards() throws {
        let (v, url) = try openStructured(uneven)
        defer { try? FileManager.default.removeItem(at: url) }

        v.jumpToPrevMismatchLine()
        XCTAssertEqual(caretLine(v), 4, "最初の前は、最後の不一致行へ")
        v.jumpToPrevMismatchLine()
        XCTAssertEqual(caretLine(v), 3)
        v.jumpToPrevMismatchLine()
        XCTAssertEqual(caretLine(v), 4, "先頭の前は、最後へ戻る")
    }

    func testNoMismatchMeansZeroCountAndNoJump() throws {
        let (v, url) = try openStructured("a,b\n1,2\n3,4\n")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(v.columnMismatchCount, 0)
        let before = v._testSelection
        v.jumpToNextMismatchLine()
        v.jumpToPrevMismatchLine()
        XCTAssertEqual(v._testSelection, before, "不一致が無ければ、動かない")
    }
}
