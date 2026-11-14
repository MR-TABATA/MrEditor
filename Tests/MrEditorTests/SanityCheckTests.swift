import XCTest
@testable import MrEditorCore

/// データの嘘発見器（Data Sanity Check / 構造歪み検知）の試験。
final class SanityCheckTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrkpro-sanity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ text: String, name: String = "t.csv") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func doc(_ url: URL?,
                     text: String? = nil,
                     columns: [String],
                     structured: StructuredMode = .csv) -> ActiveDocument {
        ActiveDocument(fileURL: url, encoding: .utf8, structuredMode: structured,
                       columnNames: columns, columnWidths: [:],
                       columnOriginalIndices: Array(columns.indices),
                       text: text, filterMatchLines: nil)
    }

    private func run(_ document: ActiveDocument) -> ColumnStatsRunner.Result {
        let runner = ColumnStatsRunner()
        let exp = expectation(description: "columnStats")
        var out = ColumnStatsRunner.Result()
        runner.run(document: document, progress: { _ in }, completion: { out = $0; exp.fulfill() })
        wait(for: [exp], timeout: 10)
        return out
    }

    /// 正常なCSVでは異常が検出されないこと。
    func testNoIssuesOnCleanCSV() throws {
        let csv = """
        id,name,score
        1,Alice,100
        2,Bob,90
        3,Charlie,85
        """
        let file = try write(csv)
        let res = run(doc(file, columns: ["id", "name", "score"]))
        XCTAssertTrue(res.sanityIssues.isEmpty)
    }

    /// カラム数不一致（多すぎる/少なすぎる行）を正しく行番号つきで検出すること。
    func testDetectsColumnCountMismatch() throws {
        let csv = """
        id,name,score
        1,Alice,100
        2,Bob,90,extra_column
        3,Charlie,85
        4,Dave
        5,Eve,95
        """
        let file = try write(csv)
        let res = run(doc(file, columns: ["id", "name", "score"]))

        let mismatches = res.sanityIssues.filter { $0.kind == .columnMismatch }
        XCTAssertEqual(mismatches.count, 2)

        // 1行目はヘッダ、2行目はAlice(OK)、3行目はBob(4列でNG)
        XCTAssertEqual(mismatches[0].line, 3)
        XCTAssertEqual(mismatches[0].actual, "4 列")
        XCTAssertEqual(mismatches[0].expected, "3 列")

        // 5行目はDave(2列でNG)
        XCTAssertEqual(mismatches[1].line, 5)
        XCTAssertEqual(mismatches[1].actual, "2 列")
        XCTAssertEqual(mismatches[1].expected, "3 列")
    }

    /// 数値列への文字列混入（型汚染）を行番号つきで検出すること。
    func testDetectsNumericTypeContamination() throws {
        let csv = """
        id,price
        1,1000
        2,2000
        3,N/A
        4,4000
        5,5000
        """
        let file = try write(csv)
        let res = run(doc(file, columns: ["id", "price"]))

        let contam = res.sanityIssues.filter { $0.kind == .typeContamination }
        XCTAssertEqual(contam.count, 1)
        XCTAssertEqual(contam[0].line, 4) // 4行目の "3,N/A"
        XCTAssertEqual(contam[0].columnName, "price")
        XCTAssertEqual(contam[0].actual, "'N/A'")
    }

    /// メモリ上の本文（runOverText）でもカラム数不一致と型混入が正しく検出されること。
    func testDetectsIssuesInMemoryText() throws {
        let csv = """
        id,price
        1,100
        2,200,extra
        3,300
        4,N/A
        """
        let res = run(doc(nil, text: csv, columns: ["id", "price"]))
        XCTAssertEqual(res.sanityIssues.count, 2)

        let mismatch = res.sanityIssues.first { $0.kind == .columnMismatch }
        XCTAssertNotNil(mismatch)
        XCTAssertEqual(mismatch?.line, 3)

        let contam = res.sanityIssues.first { $0.kind == .typeContamination }
        XCTAssertNotNil(contam)
        XCTAssertEqual(contam?.line, 5)
    }

    /// TabularFormatter が最大列数（5列）に合わせて空名列を付与していても、
    /// ヘッダ行（4列）が期待値として判定されること。
    func testExpectedColumnsBasedOnHeaderNotMaxColumns() throws {
        let csv = """
        id,name,role,age
        1,Alice,Engineer,30
        2,Bob,Manager,45,EXTRA_FIELD
        3,Charlie,Designer
        4,David,Sales,50
        """
        let file = try write(csv)
        // TabularFormatter は Bob の 5 列に合わせて 5 列分の枠（末尾が空名 ""）を作る
        let res = run(doc(file, columns: ["id", "name", "role", "age", ""]))

        let mismatches = res.sanityIssues.filter { $0.kind == .columnMismatch }
        XCTAssertEqual(mismatches.count, 2)

        // Bob (3行目): 5列 (期待値 4列) -> 列過剰
        XCTAssertEqual(mismatches[0].line, 3)
        XCTAssertEqual(mismatches[0].expected, "4 列")
        XCTAssertEqual(mismatches[0].actual, "5 列")

        // Charlie (4行目): 3列 (期待値 4列) -> 列不足
        XCTAssertEqual(mismatches[1].line, 4)
        XCTAssertEqual(mismatches[1].expected, "4 列")
        XCTAssertEqual(mismatches[1].actual, "3 列")
    }

    /// チャンク境界を跨ぐ巨大ファイルで、第2チャンク以降の異常行の行番号が正しくファイル絶対行番号になること。
    func testSanityIssuesAcrossChunkBoundary() throws {
        var text = "id,name,val\n"
        // 1 チャンクは 16MB。1行約15バイトで約1,200,000行 = 約18MB（2チャンク）
        for i in 1...1_200_000 {
            if i == 1_100_000 {
                // 第2チャンクにある列数不一致行
                text += "\(i),BadRow\n"
            } else {
                text += "\(i),ok,100\n"
            }
        }
        let file = try write(text, name: "big_sanity.csv")
        let res = run(doc(file, columns: ["id", "name", "val"]))

        let mismatches = res.sanityIssues.filter { $0.kind == .columnMismatch }
        XCTAssertEqual(mismatches.count, 1)
        // ヘッダ1行 + 1,100,000行目 = 1,100,001行目
        XCTAssertEqual(mismatches.first?.line, 1_100_001)
    }
}
