import XCTest
@testable import MrEditorCore

/// `RemoteBuffer` の検証。**手元のファイルを「遠隔」に見立てる**ので、サーバーは要らない。
///
/// 見ているのは 3 つ。
/// 1. 読んだ内容が原本と 1 バイトも違わないこと
/// 2. **見ていないところを取りに行かないこと**（範囲読みの看板そのもの）
/// 3. **取れなかったときにゼロを見せないこと**（穴の空いた本文はそれらしく描けてしまう）
final class RemoteBufferTests: XCTestCase {

    private var origin: Data!
    private var cacheURL: URL!
    /// 「遠隔」へ投げた要求の記録。何を取りに行ったかを後から数える。
    private var asked: [Range<Int>] = []

    override func setUp() {
        super.setUp()
        // 中身が位置で決まるので、ずれたらすぐ分かる
        var bytes = [UInt8]()
        bytes.reserveCapacity(256 * 1024)
        for i in 0..<(256 * 1024) {
            let v: Int = (i &* 31 &+ 7) & 0xFF
            bytes.append(UInt8(v))
        }
        origin = Data(bytes)
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-buffer-\(UUID().uuidString).cache")
        asked = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL)
        super.tearDown()
    }

    /// 原本から切り出して返す「遠隔」。要求を記録する。
    private func makeBuffer(failAfter: Int = .max) -> RemoteBuffer? {
        var served = 0
        return RemoteBuffer(count: origin.count, cacheURL: cacheURL) { [weak self] offset, length in
            self?.asked.append(offset..<(offset + length))
            served += 1
            if served > failAfter { return nil }
            let lo = min(offset, self?.origin.count ?? 0)
            let hi = min(offset + length, self?.origin.count ?? 0)
            guard lo < hi else { return Data() }
            return self?.origin.subdata(in: lo..<hi)
        }
    }

    // MARK: - 中身が合っているか

    func testReadsMatchTheOriginExactly() throws {
        let buf = try XCTUnwrap(makeBuffer())
        for probe in [0..<10, 1000..<2000, 65_000..<66_000, (origin.count - 5)..<origin.count] {
            XCTAssertEqual(buf.data(in: probe), origin.subdata(in: probe), "範囲 \(probe) がズレた")
        }
    }

    func testReadingTheWholeFileMatches() throws {
        let buf = try XCTUnwrap(makeBuffer())
        XCTAssertEqual(buf.data(in: 0..<origin.count), origin)
    }

    func testOutOfRangeIsClampedNotCrashed() throws {
        let buf = try XCTUnwrap(makeBuffer())
        XCTAssertEqual(buf.data(in: -50..<10), origin.subdata(in: 0..<10))
        XCTAssertTrue(buf.data(in: origin.count..<(origin.count + 100)).isEmpty)
        XCTAssertTrue(buf.data(in: 10..<10).isEmpty)
    }

    // MARK: - 見ていないところを取りに行かない

    /// **これが「落とさない」の実体。** 10 バイト読んだだけで全部引いたら、範囲読みではない。
    func testReadingASliceDoesNotFetchTheWholeFile() throws {
        let buf = try XCTUnwrap(makeBuffer())
        _ = buf.data(in: 100..<110)

        let total = asked.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, RemoteBuffer.chunk, "10 バイトのために \(total) バイト引いた")
        XCTAssertLessThan(buf.fetchedBytes, origin.count)
    }

    /// 同じところを読み直しても、二度は引かない。
    func testSecondReadOfTheSameRangeCostsNothing() throws {
        let buf = try XCTUnwrap(makeBuffer())
        _ = buf.data(in: 100..<110)
        let afterFirst = asked.count
        _ = buf.data(in: 100..<110)
        _ = buf.data(in: 102..<108)
        XCTAssertEqual(asked.count, afterFirst, "持っているものを引き直した")
    }

    /// 隣を読むときも、重なっているぶんは引き直さない。
    func testAdjacentReadOnlyFetchesTheGap() throws {
        let buf = try XCTUnwrap(makeBuffer())
        _ = buf.data(in: 0..<100)
        let before = asked.reduce(0) { $0 + $1.count }
        _ = buf.data(in: 50..<(RemoteBuffer.chunk + 100))
        let after = asked.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(after - before, RemoteBuffer.chunk * 2 + 1)
    }

    func testPrefetchWarmsTheNeighbourhood() throws {
        let buf = try XCTUnwrap(makeBuffer())
        buf.prefetch(around: 100_000..<100_100)
        let asksBefore = asked.count
        _ = buf.data(in: 100_000..<100_100)
        XCTAssertEqual(asked.count, asksBefore, "先読みしたのに引き直した")
    }

    // MARK: - 取れなかったとき

    /// **ゼロを見せない。** 穴の空いた本文はそれらしく描けてしまうぶん、開けないより危ない。
    func testFailedFetchYieldsEmptyNotZeros() throws {
        let buf = try XCTUnwrap(makeBuffer(failAfter: 0))
        let got = buf.data(in: 0..<100)
        XCTAssertTrue(got.isEmpty, "取れなかったのに \(got.count) バイト返した")
        XCTAssertTrue(buf.lastFetchFailed)
        // ゼロ埋めを返していないこと（0x00 が 100 個、ではない）
        XCTAssertNotEqual(got, Data(repeating: 0, count: 100))
    }

    func testFailureDoesNotPoisonLaterReads() throws {
        var failNext = true
        let buf = try XCTUnwrap(RemoteBuffer(count: origin.count, cacheURL: cacheURL) { offset, length in
            if failNext { failNext = false; return nil }
            let hi = min(offset + length, self.origin.count)
            guard offset < hi else { return Data() }
            return self.origin.subdata(in: offset..<hi)
        })
        XCTAssertTrue(buf.data(in: 0..<100).isEmpty)     // 1 回目は失敗
        XCTAssertEqual(buf.data(in: 0..<100), origin.subdata(in: 0..<100))  // 2 回目は取れる
    }

    // MARK: - 後始末

    /// 閉じたら消す。ログには秘密が入るので、起動をまたいで残さない。
    func testCacheFileIsRemovedOnDeinit() throws {
        let url = cacheURL!
        do {
            let buf = try XCTUnwrap(makeBuffer())
            _ = buf.data(in: 0..<10)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "キャッシュが残った")
    }

    /// 疎ファイルなので、見ていないぶんはディスクを食わない。
    func testCacheStaysSparseUntilRead() throws {
        let buf = try XCTUnwrap(makeBuffer())
        _ = buf.data(in: 0..<10)
        let attrs = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual(attrs[.size] as? Int, origin.count, "見かけの大きさは原本と同じ")
        XCTAssertLessThan(buf.fetchedBytes, origin.count, "実体は見たぶんだけ")
    }
}
