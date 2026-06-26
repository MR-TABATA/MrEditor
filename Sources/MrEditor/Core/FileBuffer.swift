import Foundation

/// ファイルを mmap で仮想アドレス空間に写像し、バイト範囲アクセスを提供する。
///
/// 全文をメモリに乗せない。OS のページングに任せ、実際に触れた箇所だけ
/// 物理メモリへ載る。10GB でも仮想空間に乗るだけなので破綻しない。
final class FileBuffer {
    let url: URL
    /// ファイルの総バイト数。
    let count: Int

    private let fd: Int32
    private let base: UnsafeRawPointer
    private let mapped: Bool

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

        if size == 0 {
            // mmap は長さ0で失敗するため、空ファイルはマップしない。
            self.base = UnsafeRawPointer(bitPattern: 0x1000)!  // 参照されない番地
            self.mapped = false
            return
        }

        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              p != MAP_FAILED else {
            close(fd)
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
    }

    /// 指定範囲を生バッファとして渡す（コピーなし）。範囲はファイル内にクランプされる。
    @inline(__always)
    func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        let lo = max(0, range.lowerBound)
        let hi = min(count, range.upperBound)
        let len = max(0, hi - lo)
        let ptr = len > 0 ? base + lo : nil
        return body(UnsafeRawBufferPointer(start: ptr, count: len))
    }

    /// 指定範囲を Data としてコピーする（小さなスライス向け）。
    func data(in range: Range<Int>) -> Data {
        let lo = max(0, range.lowerBound)
        let hi = min(count, range.upperBound)
        guard lo < hi else { return Data() }
        return Data(bytes: base + lo, count: hi - lo)
    }
}
