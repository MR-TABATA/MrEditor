import XCTest
@testable import MrEditorCore

/// 実データのベンチ。普段は skip。
/// `MREDITOR_BENCH=1 swift test --filter AggregateBench` で走る。
/// **公表値はここで測った数字だけを使う**（使い捨てベンチの値は製品の値ではない）。
final class AggregateBenchTests: XCTestCase {

    private func benchOnly() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1 で実データのベンチを実行")
        }
    }

    private func measureRun(_ label: String, _ document: ActiveDocument, _ mode: ValueExtractor.Mode) {
        let runner = AggregateRunner()
        let exp = expectation(description: label)
        var result = AggregateRunner.Result()
        runner.run(document: document, mode: mode, options: .init(),
                   progress: { _ in }, completion: { result = $0; exp.fulfill() })
        wait(for: [exp], timeout: 600)
        let top = result.rows.prefix(3).map { "\($0.value)=\($0.count)" }.joined(separator: " / ")
        print(String(format: "[bench] %@: %.2f 秒 / %d 行 / 異なる値 %d / 上位 %@",
                     label, result.elapsed, result.scannedLines, result.distinctCount, top))
    }

    func testTenGBKeyValue() throws {
        try benchOnly()
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/testdata/test_10gb.log")
        let doc = ActiveDocument(fileURL: url, encoding: .utf8, structuredMode: nil,
                                 columnNames: [], columnWidths: [:], columnOriginalIndices: [], text: nil, filterMatchLines: nil)
        measureRun("10GB status=", doc, .keyValue(key: "status"))
    }

    func testHoujinPrefectureColumn() throws {
        try benchOnly()
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/testdata/houjin_zenken_utf8.csv")
        let doc = ActiveDocument(fileURL: url, encoding: .utf8, structuredMode: .csv,
                                 columnNames: [], columnWidths: [:], columnOriginalIndices: [], text: nil, filterMatchLines: nil)
        measureRun("法人番号CSV 都道府県列", doc, .column(index: 9, mode: .csv))
    }

    func testHoujinUniqueColumn() throws {
        try benchOnly()
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/testdata/houjin_zenken_utf8.csv")
        let doc = ActiveDocument(fileURL: url, encoding: .utf8, structuredMode: .csv,
                                 columnNames: [], columnWidths: [:], columnOriginalIndices: [], text: nil, filterMatchLines: nil)
        measureRun("法人番号CSV 法人番号列(581万種)", doc, .column(index: 1, mode: .csv))
    }
}

/// 土台だけの床を測る（何が遅いのかを当てずに切り分けるため）。
extension AggregateBenchTests {

    /// ① 走査だけ（1 行あたり何もしない）
    func testScanFloor() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1")
        }
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/testdata/test_10gb.log")
        let engine = ScanEngine()
        let exp = expectation(description: "floor")
        engine.scan(url: url, makeSink: { _ in 0 },
                    consume: { (n: inout Int, _, _) in n += 1 },
                    progress: { _ in },
                    completion: { _, _, s in
                        print(String(format: "[bench] ①走査だけ: %.2f 秒 / %d 行", s.elapsed, s.lines))
                        exp.fulfill()
                    })
        wait(for: [exp], timeout: 600)
    }

    /// ② 走査 ＋ 値の取り出し（数えない）
    func testScanPlusExtract() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1")
        }
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/testdata/test_10gb.log")
        let engine = ScanEngine()
        let extractor = ValueExtractor.Compiled(mode: .keyValue(key: "status"), options: .init())
        let exp = expectation(description: "extract")
        engine.scan(url: url, makeSink: { _ in 0 },
                    consume: { (n: inout Int, bytes, _) in
                        n += extractor.value(from: bytes).utf8.count
                    },
                    progress: { _ in },
                    completion: { _, _, s in
                        print(String(format: "[bench] ②走査＋取り出し: %.2f 秒", s.elapsed))
                        exp.fulfill()
                    })
        wait(for: [exp], timeout: 600)
    }

    /// ③ 走査 ＋ 取り出し ＋ ローカル辞書（共有の器へは流さない）
    func testScanPlusExtractPlusDictionary() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1")
        }
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/testdata/test_10gb.log")
        let engine = ScanEngine()
        let extractor = ValueExtractor.Compiled(mode: .keyValue(key: "status"), options: .init())
        let exp = expectation(description: "dict")
        engine.scan(url: url, makeSink: { _ in [String: Int]() },
                    consume: { (d: inout [String: Int], bytes, _) in
                        d[extractor.value(from: bytes), default: 0] += 1
                    },
                    progress: { _ in },
                    completion: { _, _, s in
                        print(String(format: "[bench] ③走査＋取り出し＋辞書: %.2f 秒", s.elapsed))
                        exp.fulfill()
                    })
        wait(for: [exp], timeout: 600)
    }
}
