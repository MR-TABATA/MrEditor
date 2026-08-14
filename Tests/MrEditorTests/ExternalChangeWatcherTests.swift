import XCTest
import AppKit
@testable import MrEditorCore

/// 他のアプリでファイルが書き換わったときの検知（版の指紋・落ち着き待ち・取り込み）を検証する。
final class ExternalChangeWatcherTests: XCTestCase {
    private func tempURL(_ ext: String = "txt") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mreditor-watch-\(UUID().uuidString).\(ext)")
    }

    private func stamp(size: Int64 = 1, modified: TimeInterval = 1, inode: UInt64 = 7) -> FileStamp {
        FileStamp(size: size, modified: modified, inode: inode)
    }

    private func entry() -> FileWatchEntry {
        FileWatchEntry(url: URL(fileURLWithPath: "/tmp/x"), known: stamp())
    }

    // MARK: 指紋（FileStamp）

    func testStampReflectsWrites() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "one\n".write(to: url, atomically: true, encoding: .utf8)
        let first = try XCTUnwrap(FileStamp.read(url))

        try "one\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        let second = try XCTUnwrap(FileStamp.read(url))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.size, 8)
    }

    /// atomic save（別ファイルへ書いて置き換え）はサイズも更新時刻も同じことがありうる。
    /// inode を見ているので、それでも「変わった」と分かる。
    func testStampCatchesAtomicReplaceOfIdenticalContent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "same\n".write(to: url, atomically: true, encoding: .utf8)
        let before = try XCTUnwrap(FileStamp.read(url))

        let tmp = tempURL()
        try "same\n".write(to: tmp, atomically: true, encoding: .utf8)
        // 更新時刻まで揃えて置き換える（サイズも内容も同じ＝inode だけが違う状況を作る）。
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: before.modified)],
                                              ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)

        let after = try XCTUnwrap(FileStamp.read(url))
        XCTAssertEqual(after.size, before.size)
        XCTAssertNotEqual(after.inode, before.inode)
        XCTAssertNotEqual(after, before)
    }

    func testStampIsNilForMissingFile() {
        XCTAssertNil(FileStamp.read(tempURL()))
    }

    // MARK: 落ち着き待ち（decide）

    func testUnchangedNeverFires() {
        var e = entry()
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: stamp()))
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: stamp()))
        XCTAssertNil(e.pending)
    }

    /// 書き込み途中を掴まないため、同じ版を 2 回見てから取り込む。
    func testFiresOnlyAfterStamperSettles() {
        var e = entry()
        let changed = stamp(size: 99, modified: 2)
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: changed))   // 1 回目は様子見
        XCTAssertTrue(ExternalChangeWatcher.decide(&e, current: changed))    // 落ち着いた
        XCTAssertEqual(e.known, changed)
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: changed))   // 同じ版では鳴らない
    }

    /// 書かれ続けるログ（毎回サイズが違う）でも、待ちが長引けば観念して取り込む。
    func testFiresEventuallyWhileFileKeepsGrowing() {
        var e = entry()
        var fired = false
        for i in 1...ExternalChangeWatcher.forceAfterTicks {
            fired = ExternalChangeWatcher.decide(&e, current: stamp(size: Int64(100 + i), modified: Double(i)))
        }
        XCTAssertTrue(fired)
        XCTAssertEqual(e.pendingTicks, 0)
    }

    /// 消えている間は何もしない（非 atomic な書き手は書いている最中に一瞬消える）。
    /// 知っている版は残るので、書き終わって現れた時点で差分として拾える。
    func testVanishedFileIsIgnoredButRemembered() {
        var e = entry()
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: nil))
        XCTAssertEqual(e.known, stamp())

        let rewritten = stamp(size: 42, modified: 9, inode: 8)
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: rewritten))
        XCTAssertTrue(ExternalChangeWatcher.decide(&e, current: rewritten))
    }

    // MARK: 監視（実ファイル・tick を手で回す）

    func testWatcherReportsExternalWriteOnce() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "before\n".write(to: url, atomically: true, encoding: .utf8)

        let watcher = ExternalChangeWatcher()
        let key = ObjectIdentifier(self)
        var hits = 0
        watcher.onChange = { _ in hits += 1 }
        watcher.note(key: key, url: url)

        watcher.tick()
        XCTAssertEqual(hits, 0)                     // 何も起きていない

        try "after\n".write(to: url, atomically: true, encoding: .utf8)
        watcher.tick()                              // 1 回目は様子見
        watcher.tick()                              // 落ち着いたので通知
        XCTAssertEqual(hits, 1)

        watcher.tick()
        watcher.tick()
        XCTAssertEqual(hits, 1)                     // 同じ版では鳴り続けない
    }

    /// 保存した直後に `note` すれば、自分の書き込みは外部変更として鳴らない。
    func testNoteAfterOwnWriteSuppressesChange() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "v1\n".write(to: url, atomically: true, encoding: .utf8)

        let watcher = ExternalChangeWatcher()
        let key = ObjectIdentifier(self)
        var hits = 0
        watcher.onChange = { _ in hits += 1 }
        watcher.note(key: key, url: url)

        try "v2\n".write(to: url, atomically: true, encoding: .utf8)   // 自分の保存に相当
        watcher.note(key: key, url: url)                               // 保存直後の取り込み
        watcher.tick()
        watcher.tick()
        XCTAssertEqual(hits, 0)
    }

    /// 一覧合わせは、見ている最中のものの版を取り直さない（取り込み前の変更を握り潰さない）。
    func testSyncKeepsKnownVersionOfWatchedFiles() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "a\n".write(to: url, atomically: true, encoding: .utf8)

        let watcher = ExternalChangeWatcher()
        let key = ObjectIdentifier(self)
        var hits = 0
        watcher.onChange = { _ in hits += 1 }
        watcher.note(key: key, url: url)

        try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)
        watcher.sync([(key: key, url: url)])        // 別のドキュメントを開いた等で走る
        watcher.tick()
        watcher.tick()
        XCTAssertEqual(hits, 1)                     // 握り潰されていない

        watcher.sync([])                            // 閉じたら見なくなる
        XCTAssertTrue(watcher.entries.isEmpty)
    }

    // MARK: 取り込み（編集ペイン）

    /// 外部の変更を読み込んでも、キャレット位置は保つ（自動で走るので先頭へ飛ばされたら困る）。
    func testReloadFromDiskKeepsCaret() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "1行目\n2行目\n3行目\n".write(to: url, atomically: true, encoding: .utf8)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v._testSelect(NSRange(location: 8, length: 0))

        try "1行目\n2行目 追記\n3行目\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(v.reloadFromDisk())

        XCTAssertEqual(v._testText, "1行目\n2行目 追記\n3行目\n")
        XCTAssertEqual(v._testSelection.location, 8)
        XCTAssertFalse(v.isDirty)                   // ディスクと同じ内容＝未保存ではない
    }

    /// 短くなったファイルを読み込んでも、キャレットは本文の長さへ丸められる（範囲外にしない）。
    func testReloadFromDiskClampsCaretWhenFileShrinks() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "aaaa\nbbbb\ncccc\n".write(to: url, atomically: true, encoding: .utf8)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v._testSelect(NSRange(location: 12, length: 3))

        try "aa\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(v.reloadFromDisk())
        XCTAssertEqual(v._testSelection.location, 3)
        XCTAssertEqual(v._testSelection.length, 0)
    }

    /// 「エンコーディングを指定して開き直す」で選んだ文字コードは、読み込み直しでも引き継ぐ
    /// （自動判定に戻すと、直したはずの文字化けがひとりでに再発する）。
    func testReloadFromDiskKeepsUserChosenEncoding() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "日本語\n".data(using: .shiftJIS)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url, forcedEncoding: .utf8))    // わざと誤って開く
        XCTAssertTrue(v.reopen(withEncoding: .shiftJIS))          // 指定して直す

        try "日本語 追記\n".data(using: .shiftJIS)!.write(to: url)
        XCTAssertTrue(v.reloadFromDisk())
        XCTAssertEqual(v._testEncoding, .shiftJIS)
        XCTAssertEqual(v._testText, "日本語 追記\n")
    }

    func testReloadFromDiskFailsWithoutFile() {
        let v = EditableViewer()
        v.newDocument()
        XCTAssertFalse(v.reloadFromDisk())
    }

    // MARK: 取り込み（巨大ファイルペイン＝追記は索引を伸ばすだけ）

    /// ログに追記された分を取り込んだあとで編集しても、追記分が消えない。
    ///
    /// piece table は生成時の原本の長さを焼き込んでいるので、索引だけ伸ばすと
    /// **編集を始めた瞬間に追記分が本文から消える**（保存すればディスクからも消える）。
    /// 追記の取り込みで piece table を張り直しているのは、そこを塞ぐため。
    func testGrowthReloadKeepsAppendedLinesAfterEdit() throws {
        let url = tempURL("log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)

        let v = PieceTableViewer()
        XCTAssertTrue(v.open(url: url))
        // 索引が完成すると piece table が作られる（編集が有効になる）。
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in v._testLineCount > 0 },
                                              object: nil)
        wait(for: [ready], timeout: 5)

        // 他のアプリが末尾へ追記した（同じ inode のまま伸びる＝追従と同じ形）。
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("c\n".utf8))
        try handle.close()

        XCTAssertTrue(v.reloadFromDisk())

        v._testSetCaret(0)
        v._testInsert("X")                       // ここで表示の真実が piece table へ移る
        XCTAssertEqual(v._testDocString, "Xa\nb\nc\n")
    }
}