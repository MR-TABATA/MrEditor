import Foundation

/// ファイルを mmap で仮想アドレス空間に写像し、バイト範囲アクセスを提供する。
///
/// 全文をメモリに乗せない。OS のページングに任せ、実際に触れた箇所だけ
/// 物理メモリへ載る。10GB でも仮想空間に乗るだけなので破綻しない。
///
/// tail -f 用に、ファイルが伸びたら再マップする（`remapIfGrownTry`）。
/// 読み取り（withBytes/data）と再マップ（munmap+mmap）を rwlock で排他する。
final class FileBuffer {
    let url: URL
    /// ファイルの総バイト数（再マップで増えうる）。
    private(set) var count: Int

    private let fd: Int32
    private var base: UnsafeRawPointer
    private var mapped: Bool
    private var lock = pthread_rwlock_t()

    init?(url: URL) {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            return nil
        }
        let size = Int(st.st_size)
        self.count = size
        self.fd = fd
        pthread_rwlock_init(&lock, nil)

        if size == 0 {
            self.base = UnsafeRawPointer(bitPattern: 0x1000)!  // 参照されない番地
            self.mapped = false
            return
        }

        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              p != MAP_FAILED else {
            close(fd)
            pthread_rwlock_destroy(&lock)
            return nil
        }
        self.base = UnsafeRawPointer(p)
        self.mapped = true
    }

    deinit {
        if mapped {
            munmap(UnsafeMutableRawPointer(mutating: base), count)
        }
        close(fd)
        pthread_rwlock_destroy(&lock)
    }

    /// 指定範囲を生バッファとして渡す（コピーなし）。範囲はファイル内にクランプされる。
    @inline(__always)
    func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        let lo = max(0, range.lowerBound)
        let hi = min(count, range.upperBound)
        let len = max(0, hi - lo)
        let ptr = len > 0 ? base + lo : nil
        return body(UnsafeRawBufferPointer(start: ptr, count: len))
    }

    /// 指定範囲を Data としてコピーする（小さなスライス向け）。
    func data(in range: Range<Int>) -> Data {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        let lo = max(0, range.lowerBound)
        let hi = min(count, range.upperBound)
        guard lo < hi else { return Data() }
        return Data(bytes: base + lo, count: hi - lo)
    }

    /// ファイルが伸びていれば再マップする（成長時のみ）。新サイズを返す。変化なし/取得不可は nil。
    ///
    /// 読み取り中（rdlock 保持）のときは再マップを諦めて nil を返す（次回に回す）。
    /// これで読み取りスレッドのポインタを munmap してしまう事故を防ぐ。
    /// 縮小・ローテーション（inode 入替）は対象外（成長のみ）。
    func remapIfGrownTry() -> Int? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let newSize = Int(st.st_size)
        guard newSize > count else { return nil }

        guard pthread_rwlock_trywrlock(&lock) == 0 else { return nil }  // 誰か読んでいる→諦め
        defer { pthread_rwlock_unlock(&lock) }

        if mapped {
            munmap(UnsafeMutableRawPointer(mutating: base), count)
            mapped = false
        }
        guard let p = mmap(nil, newSize, PROT_READ, MAP_PRIVATE, fd, 0),
              p != MAP_FAILED else {
            return nil
        }
        base = UnsafeRawPointer(p)
        mapped = true
        count = newSize
        return newSize
    }
}
