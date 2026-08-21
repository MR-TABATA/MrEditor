import XCTest
import AppKit
@testable import MrEditorCore

/// 構造化表示（桁揃え）と検索・フィルタ・追従が併用できること。
///
/// もともと巨大ファイル側は構造化中に `supportsSearch` / `supportsFollow` を落としており、
/// 桁を揃えた瞬間に検索も追従もできなくなっていた（CSV を見に来た人が最初にやりたいのは
/// たいてい絞り込みなので、一番使いたい所で使えない状態だった）。
/// 検索はバイト位置の話、桁揃えは見せ方の話で互いに独立なので、併用できるようにしてある。
/// ただし置換だけは、整形した見た目のまま書き換えると見ているものとズレるので落とす。
final class StructuredSearchTests: XCTestCase {
    private func makeViewer(_ text: String) -> PieceTableViewer {
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(text.utf8))
        return v
    }

    private let csv = "id,name,level\n1,alpha,error\n2,bravo,info\n3,charlie,error\n"

    // MARK: 検索・追従は構造化中でも生きている

    /// `_testLoad` はインメモリ原本なので `searchEngine` / `fileBuffer` を持たず、
    /// 検索・追従の可否そのものはここでは false のまま。確かめるのは
    /// **構造化の有無でその可否が変わらない**こと（以前は構造化だけを理由に落としていた）。
    func testSearchAvailabilityIsUnaffectedByStructured() {
        let v = makeViewer(csv)
        let plain = v.supportsSearch
        v.setStructuredMode(.csv)
        XCTAssertEqual(v.supportsSearch, plain, "構造化を理由に検索を落とさないこと")
        v.setStructuredMode(nil)
        XCTAssertEqual(v.supportsSearch, plain)
    }

    func testFollowStaysAvailableWhileStructured() {
        let v = makeViewer(csv)
        v.setStructuredMode(.csv)
        // 追従はファイル実体が要るので _testLoad（インメモリ）では false のまま。
        // ここで確かめるのは「構造化そのものが理由で落ちない」こと。
        v.setStructuredMode(nil)
        let plain = v.supportsFollow
        v.setStructuredMode(.csv)
        XCTAssertEqual(v.supportsFollow, plain, "構造化の有無で追従の可否が変わらないこと")
    }

    // MARK: フィルタと構造化は排他ではない

    func testFilterSurvivesTurningStructuredOn() {
        let v = makeViewer(csv)
        v._testSetSearch(terms: ["error"], matchLines: [1, 3])
        v.setFilterMode(true)
        XCTAssertTrue(v._testFilterMode)

        v.setStructuredMode(.csv)
        XCTAssertTrue(v._testFilterMode, "桁を揃えたまま grep する（構造化に入ってもフィルタを落とさない）")
    }

    func testFilterSurvivesTurningStructuredOff() {
        let v = makeViewer(csv)
        v.setStructuredMode(.csv)
        v._testSetSearch(terms: ["error"], matchLines: [1, 3])
        v.setFilterMode(true)

        v.setStructuredMode(nil)
        XCTAssertTrue(v._testFilterMode, "構造化を解いてもフィルタは続く")
    }

    // MARK: 置換だけは落とす

    func testReplaceUnavailableWhileStructured() {
        let v = makeViewer(csv)
        XCTAssertTrue(v.supportsReplace)
        v.setStructuredMode(.csv)
        XCTAssertFalse(v.supportsReplace, "整形した見た目のまま書き換えさせない")
        v.setStructuredMode(nil)
        XCTAssertTrue(v.supportsReplace)
    }

    func testReplaceAllIsRefusedWhileStructured() {
        let v = makeViewer(csv)
        v.setStructuredMode(.csv)
        v._testSetSearch(terms: ["error"], matchLines: [1, 3])
        v._testReplaceAll("ERROR")
        XCTAssertEqual(v._testDocString, csv, "構造化中の置換は本文を変えないこと")
    }

    func testReplaceCurrentIsRefusedWhileStructured() {
        let v = makeViewer(csv)
        v.setStructuredMode(.csv)
        v._testSetSearch(terms: ["error"], matchLines: [1])
        v._testSelect(19..<24)
        v._testReplaceCurrent("ERROR")
        XCTAssertEqual(v._testDocString, csv, "構造化中の置換は本文を変えないこと")
    }

    // MARK: 絞り込んだら、絞り込んだ行に桁を合わせる

    /// 長い値が**中間の行にしか無い**ファイル。列幅を先頭と末尾から決めていた頃は、
    /// `long` で絞り込んだ結果が `x…` に潰れて読めなかった（2026-08-21・実機で確認）。
    /// 列幅は先頭 1000 行＋末尾 1000 行から決めるので、**両端に入らない行数**にする。
    private static let middleRow = 1500
    private func lopsided(_ middle: String) -> String {
        var lines = ["id,note"]
        for i in 1...3000 {
            lines.append(i == Self.middleRow ? "\(i),\(middle)" : "\(i),ok")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func testColumnWidthFollowsFilteredRows() {
        let middle = "connection reset by peer"      // 24 桁
        let v = makeViewer(lopsided(middle))
        v.setStructuredMode(.csv)
        let unfiltered = v._testStructuredColumnWidths
        XCTAssertLessThan(unfiltered[1], middle.count, "全体では 'ok' と見出しで決まる（前提）")

        // 中間の 1 行だけに一致するフィルタ。
        v._testSetSearch(terms: [middle], matchLines: [Self.middleRow])
        v.setFilterMode(true)
        XCTAssertEqual(v._testStructuredColumnWidths[1], middle.count,
                       "絞り込んだ行が切れずに出ること（桁を揃えたまま grep する）")
    }

    func testColumnWidthReturnsToWholeFileWhenFilterIsCleared() {
        let middle = "connection reset by peer"
        let v = makeViewer(lopsided(middle))
        v.setStructuredMode(.csv)
        let unfiltered = v._testStructuredColumnWidths
        v._testSetSearch(terms: [middle], matchLines: [Self.middleRow])
        v.setFilterMode(true)
        v.setFilterMode(false)
        XCTAssertEqual(v._testStructuredColumnWidths, unfiltered,
                       "フィルタを解いたら元の桁に戻ること")
    }

    /// 一致が 0 件でも列が消えたり落ちたりしない。
    func testEmptyFilterKeepsColumns() {
        let v = makeViewer(csv)
        v.setStructuredMode(.csv)
        let before = v._testStructuredColumnWidths
        v._testSetSearch(terms: ["nothing"], matchLines: [])
        v.setFilterMode(true)
        XCTAssertTrue(v._testFilterMode)
        XCTAssertEqual(v._testStructuredColumnWidths, before, "0 件でも列名の帯を空にしないこと")
    }
}
