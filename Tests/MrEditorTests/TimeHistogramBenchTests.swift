import XCTest
@testable import MrEditorCore

/// C3 のベンチ。普段は skip。
/// `MREDITOR_BENCH=1 swift test -c release --filter TimeHistogramBench` で走る。
///
/// 使うのは **`testdata/test_10gb_time.log`**（2026-08-11 に作り直した版）。
/// 旧 `test_10gb.log` は時刻が 0.4 秒しか進まないので、時間分布のベンチにならない。
final class TimeHistogramBenchTests: XCTestCase {

    private func benchOnly() throws -> URL {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1 で実データのベンチを実行")
        }
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/testdata/test_10gb_time.log")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("testdata/test_10gb_time.log がない（scripts/gen_testdata.py で作る）")
        }
        return url
    }

    private func document(_ url: URL) -> ActiveDocument {
        ActiveDocument(fileURL: url, encoding: .utf8, structuredMode: nil,
                       columnNames: [], columnWidths: [:], columnOriginalIndices: [], text: nil, filterMatchLines: nil)
    }

    func testTenGBHistogram() throws {
        let url = try benchOnly()
        let runner = TimeHistogramRunner()
        var options = TimeHistogramRunner.Options()
        options.timeZoneOffset = 9 * 3600
        options.displayOffset = 9 * 3600

        let exp = expectation(description: "histogram")
        var result = TimeHistogramRunner.Result()
        runner.run(document: document(url), options: options,
                   progress: { _ in }, completion: { result = $0; exp.fulfill() })
        wait(for: [exp], timeout: 900)

        let peak = result.peak
        print(String(format: "[bench] 10GB 時間分布: %.2f 秒 / %d 行（時刻あり %d・時刻なし %d）/ %d 本 × %d 秒 / footprint %.0f MB",
                     result.elapsed, result.scannedLines, result.timedLines, result.untimedLines,
                     result.buckets.count, result.bucketSeconds, Self.footprintMB()))
        if let peak {
            print(String(format: "[bench]   ピーク %@ = %d 件",
                         S.timeLabel(peak.start, width: result.bucketSeconds, offset: options.displayOffset),
                         peak.count))
        }
        // 生成側が数えた値（testdata/test_10gb_time.log.stats.txt）と突き合わせる。
        XCTAssertEqual(result.scannedLines, 67_156_671)
        XCTAssertEqual(result.untimedLines, 1_720_950)
        XCTAssertEqual(result.timedLines, 65_435_721)
    }

    /// ピークの時間帯を選び直す走査（ドラッグしたときに走るもの）。
    func testTenGBRangeSelection() throws {
        let url = try benchOnly()
        let runner = TimeHistogramRunner()
        var options = TimeHistogramRunner.Options()
        options.timeZoneOffset = 9 * 3600
        options.displayOffset = 9 * 3600

        let exp = expectation(description: "histogram")
        var result = TimeHistogramRunner.Result()
        runner.run(document: document(url), options: options,
                   progress: { _ in }, completion: { result = $0; exp.fulfill() })
        wait(for: [exp], timeout: 900)
        guard let peak = result.peak else { return XCTFail("ピークが無い") }

        let picker = TimeHistogramRunner()
        let exp2 = expectation(description: "lines")
        var lines: [Int] = []
        var capped = false
        let t0 = Date()
        picker.lines(in: peak.start..<(peak.start + result.bucketSeconds),
                     document: document(url), options: options,
                     progress: { _ in }, completion: { lines = $0; capped = $1; exp2.fulfill() })
        wait(for: [exp2], timeout: 900)
        print(String(format: "[bench] 10GB 時間帯の行を集める: %.2f 秒 / %d 行%@",
                     Date().timeIntervalSince(t0), lines.count, capped ? "（上限で打ち切り）" : ""))
        XCTAssertEqual(lines, lines.sorted())
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024 / 1024
    }
}
