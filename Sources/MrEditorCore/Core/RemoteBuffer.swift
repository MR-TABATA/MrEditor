import Foundation

/// 遠隔のファイルを、**見たところだけ**手元の疎ファイルへ埋めながら読ませる緩衝。
///
/// `FileBuffer` と同じ面（`count` / `withBytes` / `data`）を出す。上に乗っている
/// 索引・検索・piece table・構造化表示は mmap されたバイト列しか見ていないので、
/// **ここが同じ形をしていれば、リモートでもそのまま動く。**
///
/// - **落として開くのは無し**（2026-08-30 決定）。作るのは中身が空の疎ファイルで、
///   実体を持つのは実際に読んだ範囲だけ。10GB を開いても、手元に落ちるのは見たぶん。
/// - **穴はゼロとして読めてしまう。** だから読み取りは必ず `FetchedRanges` を通し、
///   欠けていれば取りに行く。**取れなかったら、ゼロを見せずに空を返す** ──
///   ゼロで埋まった本文は、それらしく描けてしまうぶん、開けないより危ない。
/// - **閉じたら消す。** ログには秘密が入る。起動をまたいで残さない。
final class RemoteBuffer {

    /// 範囲を取ってくる係。`nil` は失敗（取れなかった）。返り値が短いのは EOF。
    /// **注入にしてあるのは、繋がずに試験するため**（手元のファイルを遠隔に見立てる）。
    typealias Fetch = (_ offset: Int, _ length: Int) -> Data?

    /// 遠隔での総バイト数。取れなければ呼び出し側が「不明」を出す（0 とは書かない）。
    private(set) var count: Int

    /// 手元の疎ファイル。閉じるときに消す。
    let cacheURL: URL

    /// 直近の取得が失敗したか。空を返した理由を人に出すための材料。
    private(set) var lastFetchFailed = false

    private let fetch: Fetch
    private let fd: Int32
    private var base: UnsafeMutableRawPointer
    private var fetched = FetchedRanges()
    private var lock = pthread_mutex_t()

    /// 一度に取りに行く最小の塊。1 バイト要求のたびに 1 往復すると使い物にならない。
    static let chunk = 1 << 16   // 64KB

    init?(count: Int, cacheURL: URL, fetch: @escaping Fetch) {
        guard count >= 0 else { return nil }
        self.count = count
        self.cacheURL = cacheURL
        self.fetch = fetch

        FileManager.default.createFile(atPath: cacheURL.path, contents: nil)
        let fd = open(cacheURL.path, O_RDWR)
        guard fd >= 0 else { return nil }

        // 疎ファイルとして必要な長さだけ確保する。ここではまだ 1 バイトも書かない
        // （ftruncate は穴を作るだけで、ディスクは消費しない）。
        guard count == 0 || ftruncate(fd, off_t(count)) == 0 else {
            close(fd)
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }
        self.fd = fd
        pthread_mutex_init(&lock, nil)

        if count == 0 {
            self.base = UnsafeMutableRawPointer(bitPattern: 0x1000)!  // 参照されない番地
            return
        }
        guard let p = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              p != MAP_FAILED else {
            close(fd)
            pthread_mutex_destroy(&lock)
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }
        self.base = p
    }

    deinit {
        if count > 0 { munmap(base, count) }
        close(fd)
        pthread_mutex_destroy(&lock)
        // 閉じたら消す。ログには秘密が入るので、起動をまたいで残さない。
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// その範囲を手元に揃える。揃えられたら true。
    ///
    /// 欠けているところだけを取りに行き、既に持っているぶんは引き直さない。
    /// 要求が小さくても `chunk` 単位に広げて取る（スクロールの先を巻き込んでおく）。
    @discardableResult
    func ensure(_ range: Range<Int>) -> Bool {
        let clamped = max(0, range.lowerBound)..<min(count, range.upperBound)
        guard !clamped.isEmpty else { return true }

        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        return fillLocked(clamped)
    }

    /// 先読み。**表示している場所の周りを、待たせる前に埋めておくため。**
    /// 取れなくても黙って諦める（先読みの失敗で人を止めない）。
    func prefetch(around range: Range<Int>, margin: Int = RemoteBuffer.chunk) {
        let lo = max(0, range.lowerBound - margin)
        let hi = min(count, range.upperBound + margin)
        guard lo < hi else { return }
        pthread_mutex_lock(&lock)
        _ = fillLocked(lo..<hi)
        pthread_mutex_unlock(&lock)
    }

    /// 取得済みの合計。「10GB のうち、手元にあるのは 3MB」を人へ出すため。
    var fetchedBytes: Int {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
        return fetched.fetchedBytes
    }

    /// 指定範囲を生バッファとして渡す（`FileBuffer` と同じ形）。
    ///
    /// **揃えられなかったら、空を渡す。** ゼロで埋まった本文を渡さないため ──
    /// 穴の空いた 10GB のログは、画面上ではそれらしく描けてしまう。
    func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        let lo = max(0, range.lowerBound)
        let hi = min(count, range.upperBound)
        guard lo < hi else { return body(UnsafeRawBufferPointer(start: nil, count: 0)) }

        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }

        guard fillLocked(lo..<hi) else {
            return body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return body(UnsafeRawBufferPointer(start: UnsafeRawPointer(base) + lo, count: hi - lo))
    }

    /// 指定範囲を Data としてコピーする。揃わなければ空（`FileBuffer` は範囲外で空を返す）。
    func data(in range: Range<Int>) -> Data {
        withBytes(in: range) { Data($0) }
    }

    // MARK: - 内部

    /// 欠けを埋める。**呼び出し側が lock を持っていること。**
    private func fillLocked(_ range: Range<Int>) -> Bool {
        let gaps = fetched.missing(in: range)
        if gaps.isEmpty { return true }

        for gap in gaps {
            // 塊に広げてから取る。ただしファイルの外へは出ない。
            let lo = (gap.lowerBound / Self.chunk) * Self.chunk
            let hi = min(count, ((gap.upperBound + Self.chunk - 1) / Self.chunk) * Self.chunk)
            guard lo < hi else { continue }

            // 広げた範囲のうち、まだ持っていないところだけを引く
            for want in fetched.missing(in: lo..<hi) {
                guard let data = fetch(want.lowerBound, want.count), !data.isEmpty else {
                    lastFetchFailed = true
                    return false
                }
                let wrote = min(data.count, count - want.lowerBound)
                data.withUnsafeBytes { src in
                    (base + want.lowerBound).copyMemory(from: src.baseAddress!, byteCount: wrote)
                }
                fetched.insert(want.lowerBound..<(want.lowerBound + wrote))

                // 頼んだより短い ＝ そこで終わり。以降は取りに行かない
                if wrote < want.count { break }
            }
        }

        lastFetchFailed = !fetched.contains(range)
        return !lastFetchFailed
    }
}
