import XCTest
@testable import MrEditorCore

/// 「絞り込んで、直して、**元の形式のまま**保存できるのか」を byte で示す。
///
/// 2026-09-05 に Threads で聞かれた:
///   「このエディターで CSV のフィルター、加工、形式を踏襲したまま保存できるんですか？
///     開いて見るだけなら選択肢多そうなんですが。」
///
/// 実物（法人全件 CSV）は **Shift-JIS ＋ CRLF ＋ 引用符つき**で、この 3 つが崩れやすい。
/// Excel で開いて保存すると、文字コードが変わり、改行が変わり、引用符が付け直される。
///
/// ここで示すのは「壊れない」ではなく**「触っていないところは 1 バイトも通り抜けている」**。
/// piece table が原本を生バイトのまま持ち、保存が原本の断片をそのまま書き出す構造なので、
/// 編集した行の外は**変換を通らない**。だから BOM も CRLF も引用符も「保持する処理」が要らない。
final class CsvRoundTripTests: XCTestCase {

    /// Shift-JIS ＋ CRLF ＋ 引用符の CSV を組む（実物と同じ形）。
    private func makeSjisCsv(rows: Int) -> [UInt8] {
        var out: [UInt8] = []
        let prefectures = ["北海道", "青森県", "東京都", "大阪府", "沖縄県"]
        let names = ["釧路検察審査会", "伊達簡易裁判所", "株式会社テスト", "有限会社サンプル"]
        for i in 0..<rows {
            let line = "\(i + 1),100001216\(i % 10)153,01,1,2018-04-02,2015-10-05,"
                + "\"\(names[i % names.count])\",,101,\"\(prefectures[i % prefectures.count])\","
                + "\"釧路市\",\"柏木町４−７\",,01,206,0850824\r\n"
            out += Array(line.data(using: .shiftJIS)!)
        }
        return out
    }

    private func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-csv-\(UUID().uuidString).csv")
        try Data(bytes).write(to: url)
        return url
    }

    /// 行の「中身」の範囲。`PieceTable.byteRange(ofLine:)` は LF は外すが **CR は含む**ので、
    /// アプリと同じく末尾の CR を落とす（`PieceTableViewer.contentRange(ofLine:)` と同じ規則）。
    /// **CRLF が保たれるのは、CR が編集範囲の外にあるから**で、保存時に足しているのではない。
    private func contentRange(_ pt: PieceTable, line: Int) -> Range<Int> {
        var r = pt.byteRange(ofLine: line)
        if r.upperBound > r.lowerBound,
           pt.bytes(in: (r.upperBound - 1)..<r.upperBound).first == 0x0D {
            r = r.lowerBound..<(r.upperBound - 1)
        }
        return r
    }

    /// piece table の保存経路（`writeAll`）をそのまま通して書き出す。
    private func save(_ pt: PieceTable, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".mreditor-save-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: tmp.path, contents: nil))
        let handle = try FileHandle(forWritingTo: tmp)
        try pt.writeAll { try handle.write(contentsOf: Data($0)) }
        try handle.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// 絞り込み → 一致した行の 1 つを書き換え → 保存。
    /// 書き換えた行の外は原本と 1 バイトも違わない。
    func testFilterEditSaveKeepsEveryOtherByte() throws {
        let original = makeSjisCsv(rows: 2_000)
        let url = try write(original)
        defer { try? FileManager.default.removeItem(at: url) }

        // 開く（実アプリと同じ mmap 経路）。
        guard let buffer = FileBuffer(url: url) else { return XCTFail("mmap 失敗") }
        let encoding = EncodingDetector.detect(Data(original.prefix(64 << 10)))
        XCTAssertEqual(encoding, .shiftJIS, "実物と同じく Shift-JIS と判定される")

        let pt = PieceTable(original: FileBufferSource(buffer))

        // ── 1. 絞り込む（Shift-JIS のまま照合する検索エンジンを通す）──────────────
        let engine = SearchEngine(buffer: buffer, encoding: encoding)
        var matched: [Int] = []
        let done = expectation(description: "search")
        engine.search(SearchMode.terms(["東京都"]), progress: { _, _ in }, completion: { result in
            matched = result.lines
            done.fulfill()
        })
        wait(for: [done], timeout: 30)
        XCTAssertEqual(matched.count, 400, "5 県を回しているので 2000 行中 400 行が東京都")

        // ── 2. 一致した行の 1 つを書き換える ────────────────────────────────
        let target = matched[10]
        let range = contentRange(pt, line: target)
        let before = pt.bytes(in: range)
        XCTAssertTrue(String(data: Data(before), encoding: .shiftJIS)!.contains("東京都"))

        // 書き換えも Shift-JIS のバイトで入れる（アプリの入力経路と同じ）。
        let replacement = Array("\"東京都\",\"千代田区\"".data(using: .shiftJIS)!)
        pt.delete(range)
        pt.insert(replacement, at: range.lowerBound)

        // ── 3. 保存する ───────────────────────────────────────────────
        try save(pt, to: url)
        let saved = [UInt8](try Data(contentsOf: url))

        // ── 4. 触っていないところが 1 バイトも変わっていないこと ──────────────
        let head = range.lowerBound
        let tailFrom = range.upperBound                       // 原本側の続き
        let savedTailFrom = range.lowerBound + replacement.count
        XCTAssertEqual(Array(saved[0..<head]), Array(original[0..<head]),
                       "書き換えた行より前が原本と一致する")
        XCTAssertEqual(Array(saved[savedTailFrom...]), Array(original[tailFrom...]),
                       "書き換えた行より後ろが原本と一致する")

        // ── 5. 形式が保たれていること（結果として確かめる）────────────────────
        XCTAssertEqual(EncodingDetector.detect(Data(saved.prefix(64 << 10))), .shiftJIS,
                       "Shift-JIS のまま（UTF-8 に化けない）")
        XCTAssertEqual(saved.filter { $0 == 0x0D }.count, original.filter { $0 == 0x0D }.count,
                       "CRLF の CR が減っていない（LF だけに落ちていない）")
        XCTAssertEqual(saved.filter { $0 == 0x22 }.count,
                       original.filter { $0 == 0x22 }.count - before.filter { $0 == 0x22 }.count
                           + replacement.filter { $0 == 0x22 }.count,
                       "引用符が付け直されていない（書き換えた行のぶんだけ増減する）")
        XCTAssertNil(String(data: Data(saved.prefix(3)), encoding: .utf8).flatMap {
                        $0.hasPrefix("\u{FEFF}") ? $0 : nil },
                     "無かった BOM が足されていない")
    }

    /// BOM つき UTF-8 でも同じ。BOM は「保持する処理」ではなく、原本の先頭 3 バイトが
    /// そのまま通り抜けるだけ。
    func testUtf8BomSurvivesAnEdit() throws {
        var original: [UInt8] = [0xEF, 0xBB, 0xBF]
        original += Array("id,name\r\n1,\"あ\"\r\n2,\"い\"\r\n".utf8)
        let url = try write(original)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let buffer = FileBuffer(url: url) else { return XCTFail("mmap 失敗") }
        let pt = PieceTable(original: FileBufferSource(buffer))
        let range = contentRange(pt, line: 2)                  // 3 行目（0 始まり）
        pt.delete(range)
        pt.insert(Array("2,\"う\"".utf8), at: range.lowerBound)
        try save(pt, to: url)

        let saved = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(saved.prefix(3)), [0xEF, 0xBB, 0xBF], "BOM がそのまま残る")
        XCTAssertEqual(saved.filter { $0 == 0x0D }.count, 3, "CRLF が 3 本のまま")
        // 突き合わせは byte で行う。`String(data:encoding:.utf8)` は **BOM を食う**ので、
        // 文字列に直すと「BOM が残っているか」を見るテストにならない。
        var expected: [UInt8] = [0xEF, 0xBB, 0xBF]
        expected += Array("id,name\r\n1,\"あ\"\r\n2,\"う\"\r\n".utf8)
        XCTAssertEqual(saved, expected)
    }

    /// 実物（1.06GB の法人全件 CSV）で同じことをする。testdata が無ければ skip。
    ///   MREDITOR_REAL_CSV_TEST=1 swift test --filter CsvRoundTripTests
    func testRealHoujinCsvSlice() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_REAL_CSV_TEST"] == "1" else {
            throw XCTSkip("MREDITOR_REAL_CSV_TEST=1 のときだけ走る（実ファイルが要る）")
        }
        let source = URL(fileURLWithPath: "testdata/houjin_zenken_sjis.csv")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("testdata/houjin_zenken_sjis.csv が無い")
        }
        // 先頭 64MB を切り出す（行の途中で切らないよう最後の CRLF まで）。
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var slice = [UInt8](handle.readData(ofLength: 64 << 20))
        while let last = slice.last, last != 0x0A { slice.removeLast() }

        let url = try write(slice)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let buffer = FileBuffer(url: url) else { return XCTFail("mmap 失敗") }

        XCTAssertEqual(EncodingDetector.detect(Data(slice.prefix(64 << 10))), .shiftJIS)
        let pt = PieceTable(original: FileBufferSource(buffer))
        let range = contentRange(pt, line: 1_000)
        pt.delete(range)
        pt.insert(Array("EDITED".utf8), at: range.lowerBound)
        try save(pt, to: url)

        let saved = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(saved[0..<range.lowerBound]), Array(slice[0..<range.lowerBound]))
        XCTAssertEqual(Array(saved[(range.lowerBound + 6)...]), Array(slice[range.upperBound...]))
        XCTAssertEqual(saved.filter { $0 == 0x0D }.count, slice.filter { $0 == 0x0D }.count)
    }
}
