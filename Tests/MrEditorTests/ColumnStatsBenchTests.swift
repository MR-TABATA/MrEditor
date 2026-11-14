import XCTest
@testable import MrEditorCore

/// C2 のベンチ。普段は skip。
/// `MREDITOR_BENCH=1 swift test -c release --filter ColumnStatsBench` で走る。
///
/// ⚠️ **性能は `-c release` でしか測らない。** debug は同じコードが 7 倍遅く、
/// Slice B ではそれで「製品は 12 倍遅い」と誤診した。
final class ColumnStatsBenchTests: XCTestCase {

    private func benchOnly() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BENCH"] == "1" else {
            throw XCTSkip("MREDITOR_BENCH=1 で実データのベンチを実行")
        }
    }

    /// ヘッダ行から列名を作る（本番は構造化表示が持っているもの）。
    private func columnNames(of url: URL, sep: Character = ",") -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 << 10)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let first = text.components(separatedBy: "\n").first else { return [] }
        return TabularFormatter.splitDelimited(first, sep: sep, csvQuotes: sep == ",")
    }

    func testHoujinAllColumns() throws {
        try benchOnly()
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/testdata/houjin_zenken_utf8.csv")
        let names = columnNames(of: url)
        XCTAssertFalse(names.isEmpty, "列が取れていない")

        let doc = ActiveDocument(fileURL: url, encoding: .utf8, structuredMode: .csv,
                                 columnNames: names, columnWidths: [:], columnOriginalIndices: Array(names.indices), text: nil, filterMatchLines: nil)
        let runner = ColumnStatsRunner()
        let exp = expectation(description: "columns")
        var result = ColumnStatsRunner.Result()
        runner.run(document: doc, progress: { _ in }, completion: { result = $0; exp.fulfill() })
        wait(for: [exp], timeout: 900)

        print(String(format: "[bench] 法人番号CSV 全 %d 列: %.2f 秒 / %d 行 / footprint %.0f MB",
                     result.columns.count, result.elapsed, result.scannedLines, Self.footprintMB()))
        for c in result.columns {
            let top = c.top.first.map { "\($0.value)=\($0.count)" } ?? "-"
            print(String(format: "[bench]   %2d %@ kind=%@ present=%d blank=%d distinct=%d%@ top=%@",
                         c.index, c.name, String(describing: c.kind), c.present, c.blank,
                         c.distinct, c.distinctTruncated ? "+" : "", top))
        }
    }

    // MARK: - 床（何が遅いのかを当てずに切り分ける）

    /// ①走査だけ ②欄に切るだけ ③文字列にする ④＋数値判定と最小最大 ⑤＋数える（＝本番）
    func testFloors() throws {
        try benchOnly()
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Git/MrEditor/testdata/houjin_zenken_utf8.csv")
        let limit = columnNames(of: url).count

        measureFloor("①走査だけ", url) { _, _ in }
        measureFloor("②欄に切る", url) { line, n in
            CSVRowScanner.forEachField(in: line, separator: UInt8(ascii: ","),
                                       quoted: true, limit: limit) { _, r in n += r.count }
        }
        measureFloor("③文字列にする", url) { line, n in
            CSVRowScanner.forEachField(in: line, separator: UInt8(ascii: ","),
                                       quoted: true, limit: limit) { _, r in
                n += CSVFieldScanner.decode(line, range: r, unquote: true).utf8.count
            }
        }
        measureFloor("④＋数値判定と最小最大", url) { line, n in
            var minText: String?
            CSVRowScanner.forEachField(in: line, separator: UInt8(ascii: ","),
                                       quoted: true, limit: limit) { _, r in
                let text = CSVFieldScanner.decode(line, range: r, unquote: true)
                if NumericField.parse(text) != nil { n += 1 }
                if minText == nil || text < minText! { minText = text }
            }
        }
        measureFloor("⑤＋ローカル辞書（共有の器へ流さない）", url) { line, n in
            var local = [String: Int]()
            CSVRowScanner.forEachField(in: line, separator: UInt8(ascii: ","),
                                       quoted: true, limit: limit) { _, r in
                local[CSVFieldScanner.decode(line, range: r, unquote: true), default: 0] += 1
            }
            n += local.count
        }
    }

    private func measureFloor(_ label: String, _ url: URL,
                              _ body: @escaping (UnsafeBufferPointer<UInt8>, inout Int) -> Void) {
        let engine = ScanEngine()
        let exp = expectation(description: label)
        engine.scan(url: url, makeSink: { _ in 0 },
                    consume: { (n: inout Int, bytes, _) in body(bytes, &n) },
                    progress: { _ in },
                    completion: { _, _, s in
                        print(String(format: "[bench] %@: %.2f 秒", label, s.elapsed))
                        exp.fulfill()
                    })
        wait(for: [exp], timeout: 900)
    }

    /// いま使っている物理メモリ（`vmmap` の footprint と同じ値）。
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