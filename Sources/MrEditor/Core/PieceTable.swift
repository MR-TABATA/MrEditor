import Foundation

/// piece table のバイト供給源（原本ファイル or テスト用インメモリ）。
/// 全文をメモリに載せないため、必要な範囲だけ `read` で取り出す。
protocol PieceSource {
    var count: Int { get }
    /// 範囲 `r`（ファイル内にクランプ）を生バイトで返す。
    func read(_ r: Range<Int>) -> [UInt8]
}

/// インメモリのバイト供給源（テスト・小バッファ用）。
struct InMemorySource: PieceSource {
    private let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var count: Int { bytes.count }
    func read(_ r: Range<Int>) -> [UInt8] {
        let lo = max(0, r.lowerBound), hi = min(bytes.count, r.upperBound)
        guard lo < hi else { return [] }
        return Array(bytes[lo..<hi])
    }
}

/// 既存の mmap 済み `FileBuffer` を piece table のバイト供給源にするラッパ（B1で使用）。
/// 全文をメモリへ載せず、要求された範囲だけ `FileBuffer` 経由で読む。
struct FileBufferSource: PieceSource {
    private let buffer: FileBuffer
    init(_ buffer: FileBuffer) { self.buffer = buffer }
    var count: Int { buffer.count }
    func read(_ r: Range<Int>) -> [UInt8] {
        let lo = max(0, r.lowerBound), hi = min(buffer.count, r.upperBound)
        guard lo < hi else { return [] }
        return [UInt8](buffer.data(in: lo..<hi))
    }
}

/// 決定的な擬似乱数（treap の優先度用。木の形だけに影響し、正しさには無関係）。
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// バイト空間で文書を表す piece table。
///
/// 原本（不変・mmap など）と追記バッファ（入力分）の2供給源を、ピース列として
/// 並べて論理文書を表現する。途中挿入は「ピースを分割して差し込む」だけで、
/// 以降の全バイトをシフトしない。ピースは treap（split / merge）で平衡を保ち、
/// 各ノードに部分木のバイト数・改行数を集計しておくことで、行↔バイト変換を
/// O(log n) で解く。
///
/// 行分割はバイト 0x0A のみ（UTF-8 / Shift-JIS / EUC-JP のいずれも 0x0A は
/// マルチバイト文字の途中に現れない）。行数の数え方は `LineIndex.displayLineCount`
/// と整合（空文書=0、末尾に改行が無ければその行も1行と数える）。
final class PieceTable {
    private enum Source { case original, add }

    private struct Piece {
        var source: Source
        var start: Int      // 供給源内の開始バイト
        var length: Int     // バイト長
        var newlines: Int   // この範囲に含まれる 0x0A の数（生成時に確定）
    }

    private final class Node {
        var piece: Piece
        var priority: UInt64
        var left: Node?
        var right: Node?
        var subtreeBytes: Int
        var subtreeNewlines: Int
        init(_ piece: Piece, priority: UInt64) {
            self.piece = piece
            self.priority = priority
            self.subtreeBytes = piece.length
            self.subtreeNewlines = piece.newlines
        }
    }

    private let original: PieceSource
    private var add: [UInt8] = []
    private var root: Node?
    private var rng = SplitMix64(seed: 0x1234_5678_9ABC_DEF0)

    /// 改行走査・部分読み取りのチャンク幅（巨大ピースを一度に読まないため）。
    private let scanChunk = 64 * 1024

    /// 原本から初期化する。`originalNewlines` を渡せば初回スキャンを省略できる（B1で利用）。
    init(original: PieceSource, originalNewlines: Int? = nil) {
        self.original = original
        if original.count > 0 {
            let nl = originalNewlines ?? countNewlines(in: .original, 0..<original.count)
            let piece = Piece(source: .original, start: 0, length: original.count, newlines: nl)
            root = Node(piece, priority: rng.next())
        }
    }

    /// テスト用：バイト列から直接作る。
    convenience init(bytes: [UInt8]) {
        self.init(original: InMemorySource(bytes))
    }

    // MARK: - 集計

    var byteCount: Int { root?.subtreeBytes ?? 0 }

    /// 論理行数（空=0、末尾に改行が無ければ最終行も数える）。
    var lineCount: Int {
        let n = byteCount
        guard n > 0 else { return 0 }
        let nl = root?.subtreeNewlines ?? 0
        let lastIsNewline = bytes(in: (n - 1)..<n).first == 0x0A
        return nl + (lastIsNewline ? 0 : 1)
    }

    private func bytesOf(_ n: Node?) -> Int { n?.subtreeBytes ?? 0 }
    private func newlinesOf(_ n: Node?) -> Int { n?.subtreeNewlines ?? 0 }

    private func update(_ n: Node) {
        n.subtreeBytes = bytesOf(n.left) + n.piece.length + bytesOf(n.right)
        n.subtreeNewlines = newlinesOf(n.left) + n.piece.newlines + newlinesOf(n.right)
    }

    // MARK: - 編集

    /// `offset` バイト目に `bytes` を挿入する。
    func insert(_ bytes: [UInt8], at offset: Int) {
        guard !bytes.isEmpty else { return }
        let clamped = min(max(0, offset), byteCount)
        let addStart = add.count
        add.append(contentsOf: bytes)
        let piece = Piece(source: .add, start: addStart,
                          length: bytes.count, newlines: countNewlines(bytes))
        let (l, r) = split(root, at: clamped)
        let mid = Node(piece, priority: rng.next())
        root = merge(merge(l, mid), r)
    }

    /// `range` のバイトを削除する。
    func delete(_ range: Range<Int>) {
        let lo = max(0, range.lowerBound), hi = min(byteCount, range.upperBound)
        guard lo < hi else { return }
        let (l, rest) = split(root, at: lo)
        let (_, r) = split(rest, at: hi - lo)
        root = merge(l, r)
    }

    // MARK: - 読み出し

    /// `range` のバイトを取り出す。
    func bytes(in range: Range<Int>) -> [UInt8] {
        let lo = max(0, range.lowerBound), hi = min(byteCount, range.upperBound)
        guard lo < hi else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(hi - lo)
        collect(root, base: 0, lo: lo, hi: hi, into: &out)
        return out
    }

    private func collect(_ node: Node?, base: Int, lo: Int, hi: Int, into out: inout [UInt8]) {
        guard let node = node else { return }
        let nodeStart = base + bytesOf(node.left)
        let nodeEnd = nodeStart + node.piece.length
        if lo < nodeStart {
            collect(node.left, base: base, lo: lo, hi: hi, into: &out)
        }
        if lo < nodeEnd && hi > nodeStart {
            let a = max(lo, nodeStart) - nodeStart
            let b = min(hi, nodeEnd) - nodeStart
            out.append(contentsOf: read(node.piece.source,
                                        (node.piece.start + a)..<(node.piece.start + b)))
        }
        if hi > nodeEnd {
            collect(node.right, base: nodeEnd, lo: lo, hi: hi, into: &out)
        }
    }

    // MARK: - 行 ↔ バイト

    /// 行 `line`（0始まり）の内容バイト範囲（終端の 0x0A は含めない）。
    /// CRLF の CR 除去は呼び出し側（描画）で行う。
    func byteRange(ofLine line: Int) -> Range<Int> {
        let total = lineCount
        guard total > 0, line >= 0, line < total else { return 0..<0 }
        let nl = root?.subtreeNewlines ?? 0
        let start = (line == 0) ? 0 : afterNewline(line - 1)
        let end = (line < nl) ? afterNewline(line) - 1 : byteCount
        return start..<max(start, end)
    }

    /// 行 `line`（0始まり）の先頭バイトオフセット。
    func byteOffset(ofLineStart line: Int) -> Int {
        let total = lineCount
        let clamped = min(max(0, line), total)
        if clamped == 0 { return 0 }
        let nl = root?.subtreeNewlines ?? 0
        if clamped - 1 < nl { return afterNewline(clamped - 1) }
        return byteCount
    }

    /// バイトオフセット `off` を含む行（0始まり）＝ `[0, off)` の改行数。
    func line(ofByteOffset off: Int) -> Int {
        let target = min(max(0, off), byteCount)
        var node = root
        var count = 0
        var base = 0
        while let n = node {
            let nodeStart = base + bytesOf(n.left)
            let nodeEnd = nodeStart + n.piece.length
            if target <= nodeStart {
                node = n.left
            } else if target >= nodeEnd {
                count += newlinesOf(n.left) + n.piece.newlines
                base = nodeEnd
                node = n.right
            } else {
                count += newlinesOf(n.left)
                let within = target - nodeStart
                count += countNewlines(in: n.piece.source,
                                       n.piece.start..<(n.piece.start + within))
                break
            }
        }
        return count
    }

    /// `j` 番目（0始まり）の改行の直後のバイトオフセット。前提: 0 <= j < 改行数。
    private func afterNewline(_ j: Int) -> Int {
        var node = root
        var j = j
        var base = 0
        while let n = node {
            let leftNL = newlinesOf(n.left)
            if j < leftNL {
                node = n.left
            } else {
                let inThisOrRight = j - leftNL
                let nodeStart = base + bytesOf(n.left)
                if inThisOrRight < n.piece.newlines {
                    let local = nthNewlineOffset(in: n.piece, ordinal: inThisOrRight)
                    return nodeStart + local + 1
                }
                j = inThisOrRight - n.piece.newlines
                base = nodeStart + n.piece.length
                node = n.right
            }
        }
        return byteCount   // 到達しない
    }

    // MARK: - treap（split / merge）

    /// バイト位置 `k` で木を二分する。`k` がピース内部に落ちればそのピースを割る。
    private func split(_ node: Node?, at k: Int) -> (Node?, Node?) {
        guard let node = node else { return (nil, nil) }
        let leftBytes = bytesOf(node.left)
        if k <= leftBytes {
            let (l, r) = split(node.left, at: k)
            node.left = r
            update(node)
            return (l, node)
        } else if k >= leftBytes + node.piece.length {
            let (l, r) = split(node.right, at: k - leftBytes - node.piece.length)
            node.right = l
            update(node)
            return (node, r)
        } else {
            // k がこのノードのピース内部 → ピースを2つに割る
            let offsetInPiece = k - leftBytes
            let leftPiece = subPiece(node.piece, 0, offsetInPiece)
            let rightPiece = subPiece(node.piece, offsetInPiece, node.piece.length - offsetInPiece)
            let leftTree = merge(node.left, Node(leftPiece, priority: rng.next()))
            let rightTree = merge(Node(rightPiece, priority: rng.next()), node.right)
            return (leftTree, rightTree)
        }
    }

    /// 位置順に隣接する2つの treap を結合する（`a` の全キー < `b` の全キー）。
    private func merge(_ a: Node?, _ b: Node?) -> Node? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        if a.priority > b.priority {
            a.right = merge(a.right, b)
            update(a)
            return a
        } else {
            b.left = merge(a, b.left)
            update(b)
            return b
        }
    }

    /// ピースの部分ピースを作る（改行数は部分範囲を走査して数え直す）。
    private func subPiece(_ p: Piece, _ from: Int, _ len: Int) -> Piece {
        let r = (p.start + from)..<(p.start + from + len)
        return Piece(source: p.source, start: p.start + from, length: len,
                     newlines: countNewlines(in: p.source, r))
    }

    // MARK: - バイト供給・改行走査

    private func read(_ s: Source, _ r: Range<Int>) -> [UInt8] {
        switch s {
        case .original:
            return original.read(r)
        case .add:
            let lo = max(0, r.lowerBound), hi = min(add.count, r.upperBound)
            guard lo < hi else { return [] }
            return Array(add[lo..<hi])
        }
    }

    private func countNewlines(_ bytes: [UInt8]) -> Int {
        var c = 0
        for b in bytes where b == 0x0A { c += 1 }
        return c
    }

    /// 供給源の範囲をチャンク読みしながら 0x0A を数える（巨大範囲でもメモリ O(1)）。
    private func countNewlines(in s: Source, _ range: Range<Int>) -> Int {
        var count = 0
        var pos = range.lowerBound
        while pos < range.upperBound {
            let len = min(scanChunk, range.upperBound - pos)
            count += countNewlines(read(s, pos..<(pos + len)))
            pos += len
        }
        return count
    }

    /// ピース内で `ordinal` 番目（0始まり）の 0x0A のピース内オフセットを返す。
    private func nthNewlineOffset(in piece: Piece, ordinal: Int) -> Int {
        var remaining = ordinal
        var pos = 0
        while pos < piece.length {
            let len = min(scanChunk, piece.length - pos)
            let chunk = read(piece.source, (piece.start + pos)..<(piece.start + pos + len))
            for (i, b) in chunk.enumerated() where b == 0x0A {
                if remaining == 0 { return pos + i }
                remaining -= 1
            }
            pos += len
        }
        return max(0, piece.length - 1)   // 到達しない
    }
}
