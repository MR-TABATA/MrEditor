import XCTest
@testable import MrEditor

/// 10GB 実ファイルでのストリーム保存を検証する（生命線）。
/// 普段は skip。`MREDITOR_BIG_SAVE_TEST=1` を立てたときだけ走る（別ボリューム・時間がかかるため）。
///   swift test --filter BigFileSaveTests  （環境変数付きで）
final class BigFileSaveTests: XCTestCase {
    /// 本番の肝: mmap している当のファイルへ「その場保存」しても、mmap が生き続けて
    /// 以降の読み出しが壊れないこと（atomic 差し替えで原本 inode が保持される）。小ファイルで検証。
    func testSaveInPlaceKeepsMmapValid() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-inplace-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "hello world\n".write(to: url, atomically: true, encoding: .utf8)

        guard let buffer = FileBuffer(url: url) else { return XCTFail("mmap 失敗") }
        let pt = PieceTable(original: FileBufferSource(buffer), originalNewlines: 0)
        pt.insert(Array("X-".utf8), at: 0)                 // "X-hello world\n"

        // mmap している当の url へ書き戻す（viewer.write と同じ手順を再現）。
        func saveInPlace() throws {
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".mreditor-save-\(UUID().uuidString)")
            XCTAssertTrue(FileManager.default.createFile(atPath: tmp.path, contents: nil))
            let h = try FileHandle(forWritingTo: tmp)
            try pt.writeAll { try h.write(contentsOf: Data($0)) }
            try h.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        }
        try saveInPlace()

        // ディスクの中身が編集後になっている。
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "X-hello world\n")
        // mmap 経由の原本読みが差し替え後も生きている（＝原本 inode が保持されている）。
        let viaMmap = pt.bytes(in: 0..<pt.byteCount)
        XCTAssertEqual(viaMmap, Array("X-hello world\n".utf8))

        // 2 回目の編集＋その場保存も通る（追記バッファ＋保持された原本から再構成）。
        pt.insert(Array("Y-".utf8), at: 0)                 // "Y-X-hello world\n"
        try saveInPlace()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Y-X-hello world\n")
    }

    func testStreamSave10GB() throws {
        guard ProcessInfo.processInfo.environment["MREDITOR_BIG_SAVE_TEST"] == "1" else {
            throw XCTSkip("MREDITOR_BIG_SAVE_TEST=1 で 10GB 保存テストを実行")
        }
        let src = URL(fileURLWithPath: "/Users/hitoshi/Git/MrEditor/testdata/test_10gb.log")
        guard let buffer = FileBuffer(url: src) else { return XCTFail("mmap 失敗") }
        let originalSize = buffer.count

        // 原本に mmap を被せ、先頭と末尾に編集を差し込む（全文はメモリに載せない）。
        let pt = PieceTable(original: FileBufferSource(buffer), originalNewlines: 0)
        let head = Array("EDITED-HEAD\n".utf8)
        let tail = Array("\nEDITED-TAIL".utf8)
        pt.insert(head, at: 0)
        pt.insert(tail, at: pt.byteCount)
        XCTAssertEqual(pt.byteCount, originalSize + head.count + tail.count)

        // 別ボリュームを避けるため同ディレクトリ（testdata/ は gitignore）へ書く。
        let out = src.deletingLastPathComponent().appendingPathComponent("b3-10gb-out.log")
        try? FileManager.default.removeItem(at: out)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertTrue(FileManager.default.createFile(atPath: out.path, contents: nil))
        let handle = try FileHandle(forWritingTo: out)

        let t0 = Date()
        var written = 0
        try pt.writeAll(chunk: 4 << 20) { slice in
            try handle.write(contentsOf: Data(slice))
            written += slice.count
        }
        try handle.close()
        let dt = Date().timeIntervalSince(t0)

        let outSize = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? -1
        print(String(format: "[B3] 10GB stream-save: %.1fs, %.1f MB/s, out=%ld bytes",
                     dt, Double(written) / 1e6 / dt, outSize))

        XCTAssertEqual(written, pt.byteCount)
        XCTAssertEqual(outSize, pt.byteCount)

        // 先頭・末尾を実読みして編集が載っているか確認（全文は読まない）。
        let outBuf = try FileHandle(forReadingFrom: out)
        let first = try outBuf.read(upToCount: head.count).map { Array($0) }
        XCTAssertEqual(first, head)
        try outBuf.seek(toOffset: UInt64(outSize - tail.count))
        let last = try outBuf.readToEnd().map { Array($0) }
        XCTAssertEqual(last, tail)
        try outBuf.close()
    }
}
