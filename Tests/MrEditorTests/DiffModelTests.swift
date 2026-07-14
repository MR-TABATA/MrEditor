import XCTest
@testable import MrEditor

/// 並べて見るときの行モデルと、選択範囲のコピー。
final class DiffModelTests: XCTestCase {

    /// 左 [a, b, c, d] → 右 [a, X, c, d, e] 相当の手。
    /// 表示行: 0=a(equal) 1=b↔X(replace) 2=c(equal) 3=d(equal) 4=e(insert)
    private func sampleModel() -> DiffModel {
        DiffModel(ops: [
            .equal(left: 0, right: 0, count: 1),
            .replace(left: 1, leftCount: 1, right: 1, rightCount: 1),
            .equal(left: 2, right: 2, count: 2),
            .insert(right: 4, count: 1),
        ])
    }

    func testRowMapping() {
        let m = sampleModel()
        XCTAssertEqual(m.rowCount, 5)

        XCTAssertEqual(m.row(at: 0)?.left, 0)
        XCTAssertEqual(m.row(at: 0)?.right, 0)

        XCTAssertEqual(m.row(at: 1)?.kind, .replace)
        XCTAssertEqual(m.row(at: 1)?.left, 1)
        XCTAssertEqual(m.row(at: 1)?.right, 1)

        XCTAssertEqual(m.row(at: 3)?.left, 3)

        // 右にしかない行。左は埋め草（nil）。
        XCTAssertEqual(m.row(at: 4)?.kind, .insert)
        XCTAssertNil(m.row(at: 4)?.left)
        XCTAssertEqual(m.row(at: 4)?.right, 4)

        XCTAssertNil(m.row(at: 5))
    }

    /// 差分の頭（表示行）。
    func testHunkStarts() {
        let m = sampleModel()
        XCTAssertEqual(m.hunkStarts, [1, 4])
    }

    /// 「次の差分へ」は**選んでいるハンク**を基準に進む。
    ///
    /// 最初はスクロール位置（topRow）を基準にしていたため、画面に収まる小さなファイルでは
    /// topRow が 0 のまま動かず、**何度押しても同じ差分に戻った**。GUI でしか気づけなかった
    /// バグなので、ここで固定する。
    func testHunkNavigationAdvancesFromCurrentHunk() {
        let m = sampleModel()
        let hunks = m.hunkOpIndices          // [1(replace), 3(insert)]
        XCTAssertEqual(hunks, [1, 3])

        // 何も選んでいなければ最初のハンク。
        XCTAssertEqual(m.hunk(after: nil), 1)
        // 1 つ目 → 2 つ目へ**進む**（同じ所に戻らない）。
        XCTAssertEqual(m.hunk(after: 1), 3)
        // 末尾の先は無い。
        XCTAssertNil(m.hunk(after: 3))

        // 戻りも同様。
        XCTAssertEqual(m.hunk(before: 3), 1)
        XCTAssertNil(m.hunk(before: 1))
        XCTAssertEqual(m.hunk(before: nil), 3)
    }

    /// ハンクの先頭表示行（移動先の行）。
    func testStartRowOfOp() {
        let m = sampleModel()
        XCTAssertEqual(m.startRow(ofOp: 0), 0)   // equal
        XCTAssertEqual(m.startRow(ofOp: 1), 1)   // replace
        XCTAssertEqual(m.startRow(ofOp: 2), 2)   // equal(2 行)
        XCTAssertEqual(m.startRow(ofOp: 3), 4)   // insert
    }

    func testChangedCounts() {
        let m = sampleModel()
        XCTAssertEqual(m.changedRowCount, 2)   // replace 1 行 ＋ insert 1 行
        XCTAssertFalse(m.isIdentical)
    }

    // MARK: - コピー

    /// 左の列でコピーする。行 4 は右にしか無い＝左では埋め草なので、**空行を混ぜない**。
    func testCopySkipsFillerRows() {
        let m = sampleModel()
        let leftLines = ["a", "b", "c", "d"]
        let text = m.selectedText(from: (row: 2, idx: 0), to: (row: 4, idx: 0)) { row in
            m.row(at: row)?.left.map { leftLines[$0] }     // 左に無ければ nil
        }
        // 行 2(c) と 3(d) だけ。行 4 は左に存在しないので飛ばす（"c\nd\n" にしない）。
        XCTAssertEqual(text, "c\nd")
    }

    /// 行の途中から途中まで（ドラッグ選択）。
    func testCopyPartialRange() {
        let m = sampleModel()
        let lines = ["alpha", "bravo", "charlie", "delta"]
        let text = m.selectedText(from: (row: 0, idx: 2), to: (row: 2, idx: 4)) { row in
            m.row(at: row)?.left.map { lines[$0] }
        }
        XCTAssertEqual(text, "pha\nbravo\nchar")
    }

    /// 日本語（サロゲートペアを含む）を割らない。
    func testCopyDoesNotSplitSurrogatePairs() {
        let m = DiffModel(ops: [.equal(left: 0, right: 0, count: 1)])
        let line = "あ👨‍👩‍👦い"
        let all = m.selectedText(from: (row: 0, idx: 0), to: (row: 0, idx: line.utf16.count)) { _ in line }
        XCTAssertEqual(all, line)
    }

    /// 選択が空、範囲外でも落ちない。
    func testCopyDegenerateRanges() {
        let m = sampleModel()
        XCTAssertEqual(m.selectedText(from: (row: 1, idx: 0), to: (row: 0, idx: 0)) { _ in "x" }, "")
        XCTAssertEqual(m.selectedText(from: (row: 0, idx: 0), to: (row: 99, idx: 0)) { _ in "x" }, "")
    }

    /// スクロールバーの差分マーカーは、差分の位置（0...1）に立つ。
    func testMarkers() {
        let m = sampleModel()
        let markers = m.markers()
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].kind, .replace)
        XCTAssertEqual(markers[0].position, 1.0 / 5.0, accuracy: 0.001)
        XCTAssertEqual(markers[1].kind, .insert)
        XCTAssertEqual(markers[1].position, 4.0 / 5.0, accuracy: 0.001)
    }
}
