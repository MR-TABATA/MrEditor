import Foundation

/// ビューアが読むバイト列の出どころ。
///
/// 索引・検索・piece table は**バイト範囲しか見ていない**。だから、その範囲を
/// 渡せるものなら何でも上に載る ―― 手元のファイル（`FileBuffer`）でも、
/// 遠隔を範囲読みで埋める疎キャッシュ（`RemoteBuffer`）でも同じ。
///
/// **この継ぎ目があるおかげで、リモート対応が viewer の書き直しにならない。**
/// 面を増やさないこと自体が設計で、`FileBuffer` が既に持っていた 4 つだけを写した。
protocol ByteSource: AnyObject {
    /// 総バイト数（伸びうる）。
    var count: Int { get }
    /// 指定範囲を生バッファとして渡す。範囲は内側にクランプされる。
    func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) -> R) -> R
    /// 指定範囲のコピー。
    func data(in range: Range<Int>) -> Data
    /// 伸びていれば取り込んで新しい大きさを返す。変化なし・できないなら nil。
    func remapIfGrownTry() -> Int?
}

extension FileBuffer: ByteSource {}

extension RemoteBuffer: ByteSource {
    /// 遠隔では**再マップで伸びを追わない。**
    ///
    /// 手元のファイルは `fstat` で伸びが分かるが、遠隔でそれをやると
    /// スクロールのたびに `wc -c` を投げることになる。伸びを追うのは
    /// 末尾追従（`tail -f` を向こうで走らせて流し込む）側の仕事で、経路が別。
    func remapIfGrownTry() -> Int? { nil }
}
