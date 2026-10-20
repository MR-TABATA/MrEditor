import XCTest
import zlib
@testable import MrEditorCore

/// 入口 —— パイプと圧縮。
///
/// 「巨大なログを見る」道具なのに、そのログは素のファイルとして転がっていないことが
/// 多い。ここが塞がっていると、中の機能はどれも届かない。
final class IntakeTests: XCTestCase {

    // MARK: 標準入力がパイプかどうか

    func testAPipeIsAccepted() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertTrue(Intake.stdinIsPiped(fds[0]))
    }

    func testARedirectedFileIsAccepted() throws {
        // `mreditor < app.log` も受ける。パイプと同じく「渡された」なので。
        let url = Intake.scratchURL(named: "intake-test-\(UUID().uuidString)")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY)
        defer { close(fd) }
        XCTAssertTrue(Intake.stdinIsPiped(fd))
    }

    func testDevNullIsNotAPipe() throws {
        // **これが本題。** Finder や Dock から起動すると標準入力は /dev/null で、
        // 端末ではないので isatty だけでは真になる。受け取ってしまうと、毎回の起動で
        // 空のタブが増える。
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        XCTAssertFalse(Intake.stdinIsPiped(fd))
    }

    // MARK: gzip の判定は中身で

    func testGzipIsDetectedByItsMagicNumber() {
        XCTAssertTrue(Intake.isGzip([0x1f, 0x8b, 0x08, 0x00]))
    }

    func testExtensionsAreNotTrusted() {
        // `.gz` なのに素のテキスト（展開済みなのに名前だけ残っている）は実際にある。
        // 中身で見るので、そういうファイルはそのまま開く。
        XCTAssertFalse(Intake.isGzip(Array("2026-08-28 ERROR".utf8)))
        XCTAssertFalse(Intake.isGzip([0x1f]))          // 1 バイトしか読めなかった
        XCTAssertFalse(Intake.isGzip([]))              // 空ファイル
    }

    // MARK: 展開

    func testGunzipExpandsAndKeepsTheOriginalName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plain = dir.appendingPathComponent("app.log")
        try "2026-08-28 ERROR boom\n".write(to: plain, atomically: true, encoding: .utf8)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = [plain.path]
        try gzip.run(); gzip.waitUntilExit()

        let expanded = try XCTUnwrap(Intake.gunzip(dir.appendingPathComponent("app.log.gz")))
        defer { try? FileManager.default.removeItem(at: expanded) }
        XCTAssertEqual(try String(contentsOf: expanded, encoding: .utf8), "2026-08-28 ERROR boom\n")
        // タブに出る名前は元のまま。一時ファイルの乱数名だと何を見ているか分からない。
        XCTAssertEqual(expanded.lastPathComponent, "app.log")
    }

    // MARK: zip

    private func makeZip(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            let file = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: file, atomically: true, encoding: .utf8)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qr", "archive.zip"] + files.keys.sorted()
        zip.currentDirectoryURL = dir
        try zip.run(); zip.waitUntilExit()
        return dir.appendingPathComponent("archive.zip")
    }

    func testZipIsDetectedByItsMagicNumber() {
        XCTAssertTrue(Intake.isZip([0x50, 0x4b, 0x03, 0x04]))
        XCTAssertTrue(Intake.isZip([0x50, 0x4b, 0x05, 0x06]))   // 空の書庫
        XCTAssertFalse(Intake.isZip([0x50, 0x4b]))              // 2 バイトしか読めなかった
        XCTAssertFalse(Intake.isZip(Array("PK is not it".utf8)))
    }

    func testEntriesSkipDirectoriesAndFinderJunk() throws {
        // Finder で圧縮すると __MACOSX/ と .DS_Store が必ず入る。一覧に出すと
        // 選択肢が実際の倍になり、しかも中身は誰も読みたくないもの。
        let url = try makeZip(["app.log": "a\n",
                               "logs/db.log": "b\n",
                               "__MACOSX/._app.log": "junk",
                               ".DS_Store": "junk"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(Intake.zipEntries(url).sorted(), ["app.log", "logs/db.log"])
    }

    func testUnzipTakesTheNameFromInsideTheArchive() throws {
        // タブに archive.zip と出ても、その中のどれを見ているのか分からない。
        let url = try makeZip(["logs/db.log": "2026-08-28 slow query\n"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let out = try XCTUnwrap(Intake.unzip(url, entry: "logs/db.log"))
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(out.lastPathComponent, "db.log")
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "2026-08-28 slow query\n")
    }

    func testUnzipReturnsNilForAnEntryThatIsNotThere() throws {
        let url = try makeZip(["app.log": "a\n"])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(Intake.unzip(url, entry: "nope.log"))
    }

    // MARK: Windows製zip（Shift-JIS / CP932）の日本語ファイル名（B16）

    private func makeZipWithShiftJIS(entryName: String, body: String, method: UInt16 = 8) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("windows.zip")

        let cp932 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
        let nameEncoding = String.Encoding(rawValue: cp932)
        guard let nameBytes = entryName.data(using: nameEncoding) else {
            throw NSError(domain: "test", code: 1)
        }
        let bodyData = Data(body.utf8)

        let compressed: Data
        if method == 8 {
            var stream = z_stream()
            deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            var comp = Data(count: bodyData.count + 64)
            bodyData.withUnsafeBytes { inBytes in
                comp.withUnsafeMutableBytes { outBytes in
                    stream.next_in = UnsafeMutablePointer(mutating: inBytes.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(inBytes.count)
                    stream.next_out = outBytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outBytes.count)
                    deflate(&stream, Z_FINISH)
                }
            }
            deflateEnd(&stream)
            comp.count = Int(stream.total_out)
            compressed = comp
        } else {
            compressed = bodyData
        }

        let crc = UInt32(crc32(0, [UInt8](bodyData), uInt(bodyData.count)))

        func appendUInt16(_ val: UInt16, to data: inout Data) {
            var v = val.littleEndian
            data.append(Data(bytes: &v, count: 2))
        }
        func appendUInt32(_ val: UInt32, to data: inout Data) {
            var v = val.littleEndian
            data.append(Data(bytes: &v, count: 4))
        }

        var zipData = Data()

        // 1. Local File Header (PK\x03\x04)
        zipData.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
        appendUInt16(20, to: &zipData) // version needed
        appendUInt16(0, to: &zipData)  // flags (bit 11 = 0 => not UTF-8)
        appendUInt16(method, to: &zipData)
        appendUInt16(0, to: &zipData)  // mod time
        appendUInt16(0, to: &zipData)  // mod date
        appendUInt32(crc, to: &zipData)
        appendUInt32(UInt32(compressed.count), to: &zipData)
        appendUInt32(UInt32(bodyData.count), to: &zipData)
        appendUInt16(UInt16(nameBytes.count), to: &zipData)
        appendUInt16(0, to: &zipData)  // extra len
        zipData.append(nameBytes)
        zipData.append(compressed)

        let localHeaderOffset: UInt32 = 0
        let cdOffset = UInt32(zipData.count)

        // 2. Central Directory File Header (PK\x01\x02)
        var cdData = Data()
        cdData.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
        appendUInt16(20, to: &cdData) // version made by
        appendUInt16(20, to: &cdData) // version needed
        appendUInt16(0, to: &cdData)  // flags (bit 11 = 0)
        appendUInt16(method, to: &cdData)
        appendUInt16(0, to: &cdData)  // mod time
        appendUInt16(0, to: &cdData)  // mod date
        appendUInt32(crc, to: &cdData)
        appendUInt32(UInt32(compressed.count), to: &cdData)
        appendUInt32(UInt32(bodyData.count), to: &cdData)
        appendUInt16(UInt16(nameBytes.count), to: &cdData)
        appendUInt16(0, to: &cdData)  // extra len
        appendUInt16(0, to: &cdData)  // comment len
        appendUInt16(0, to: &cdData)  // disk start
        appendUInt16(0, to: &cdData)  // int attrs
        appendUInt32(0, to: &cdData)  // ext attrs
        appendUInt32(localHeaderOffset, to: &cdData)
        cdData.append(nameBytes)

        zipData.append(cdData)
        let cdSize = UInt32(cdData.count)

        // 3. End of Central Directory Record (PK\x05\x06)
        zipData.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        appendUInt16(0, to: &zipData)  // disk
        appendUInt16(0, to: &zipData)  // start disk
        appendUInt16(1, to: &zipData)  // disk entries
        appendUInt16(1, to: &zipData)  // total entries
        appendUInt32(cdSize, to: &zipData)
        appendUInt32(cdOffset, to: &zipData)
        appendUInt16(0, to: &zipData)  // comment len

        try zipData.write(to: zipURL)
        return zipURL
    }

    func testZipEntriesDecodesShiftJISFileNameFromWindows() throws {
        // Windows 製 zip（UTF-8 フラグなし・Shift-JIS / CP932）の日本語ファイル名が化けずに取れること
        let japaneseName = "売上報告_2026年10月.csv"
        let url = try makeZipWithShiftJIS(entryName: japaneseName, body: "1,りんご,150\n2,みかん,100\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let entries = Intake.zipEntries(url)
        XCTAssertEqual(entries, [japaneseName])
    }

    func testUnzipExtractsShiftJISFileNameEntry() throws {
        let japaneseName = "ログ_障害調査.txt"
        let content = "2026-10-21 ERROR Database timeout\n"
        let url = try makeZipWithShiftJIS(entryName: japaneseName, body: content)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let out = try XCTUnwrap(Intake.unzip(url, entry: japaneseName))
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertEqual(out.lastPathComponent, japaneseName)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), content)
    }

    func testUnzipExtractsStoredEntry() throws {
        // 無圧縮（method 0）のエントリも正しく展開できること
        let japaneseName = "無圧縮_設定.ini"
        let content = "[Settings]\nTimeout=30\n"
        let url = try makeZipWithShiftJIS(entryName: japaneseName, body: content, method: 0)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let out = try XCTUnwrap(Intake.unzip(url, entry: japaneseName))
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertEqual(out.lastPathComponent, japaneseName)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), content)
    }

    func testGunzipReturnsNilForSomethingThatIsNotGzip() throws {
        let url = Intake.scratchURL(named: "not-gzip-\(UUID().uuidString).gz")
        try "plain text".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(Intake.gunzip(url))
    }

    // MARK: 起動中の自分への受け渡し（B15）

    func testOnlyOurScratchFolderIsAcceptedFromANotification() {
        // 分散通知は誰でも投げられる。置き場の外のパスを開かされない。
        XCTAssertTrue(Intake.isScratchFile(Intake.scratchURL(named: "stdin-1-2.log")))
        XCTAssertFalse(Intake.isScratchFile(URL(fileURLWithPath: "/etc/hosts")))
        XCTAssertFalse(Intake.isScratchFile(
            Intake.scratchURL(named: "x").deletingLastPathComponent()
                .appendingPathComponent("../../etc/hosts")))
    }

    /// 流し込みの合図は、アプリ（バンドル ID）ごとに名前が違う。同じ名前だと、無料版と Pro 版を
    /// 両方開いているとき、片方へ流した内容が両方で開いてしまう。
    func testPipeNotificationNamesAreScopedPerApp() {
        let free = Intake.pipeNotificationName("pipe", bundleID: "com.aaedit.MrEditor")
        let pro = Intake.pipeNotificationName("pipe", bundleID: "com.aaedit.MrkEditor")
        XCTAssertNotEqual(free, pro)
        XCTAssertNotEqual(Intake.pipeNotificationName("pipe", bundleID: "com.aaedit.MrEditor"),
                          Intake.pipeNotificationName("pipeEnd", bundleID: "com.aaedit.MrEditor"))
        // 同じアプリ同士（流し込む側と受ける側）は一致する。
        XCTAssertEqual(free, Intake.pipeNotificationName("pipe", bundleID: "com.aaedit.MrEditor"))
        // バンドルが無い開発起動でも名前は作れる。
        XCTAssertEqual(Intake.pipeNotificationName("pipe", bundleID: nil).rawValue, "app.aaedit.MrEditor.pipe")
    }
}
