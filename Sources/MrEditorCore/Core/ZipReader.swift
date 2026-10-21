import Foundation
import zlib

/// ZIP 書庫の軽量リーダー（B16）。
///
/// 外部コマンド（`/usr/bin/unzip`）に依存せず、自前で Central Directory を解析して
/// Windows（CP932 / Shift-JIS）で作成された日本語ファイル名を正しく復元する。
///
/// **巨大な書庫でもメモリに載せない** —— 末尾の EOCD と Central Directory のヘッダ領域だけを
/// seek して読み、本文はストリーム（64KB チャンク）で一時ファイルへ展開する。
enum ZipReader {

    struct Entry: Sendable {
        let name: String
        let isDirectory: Bool
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    /// 書庫内のエントリ一覧を取得する。壊れているか読めない場合は nil。
    static func readEntries(at url: URL) -> [Entry]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22 else { return nil }

        // EOCD (PK\x05\x06) を末尾から探す（コメント長は最大 65,535 バイト、EOCD は 22 バイト）
        let maxSearch = min(fileSize, UInt64(65535 + 22))
        let searchStart = fileSize - maxSearch
        guard (try? handle.seek(toOffset: searchStart)) != nil,
              let tailData = try? handle.readToEnd(),
              tailData.count >= 22 else { return nil }

        var eocdRelOffset: Int?
        let tailCount = tailData.count
        for i in stride(from: tailCount - 22, through: 0, by: -1) {
            if tailData[i] == 0x50 && tailData[i + 1] == 0x4b &&
               tailData[i + 2] == 0x05 && tailData[i + 3] == 0x06 {
                eocdRelOffset = i
                break
            }
        }
        guard let eocdRel = eocdRelOffset else { return nil }

        let totalEntries = Int(readUInt16(tailData, at: eocdRel + 10))
        let cdSize = UInt64(readUInt32(tailData, at: eocdRel + 12))
        let cdOffset = UInt64(readUInt32(tailData, at: eocdRel + 16))

        guard cdOffset + cdSize <= fileSize else { return nil }
        guard (try? handle.seek(toOffset: cdOffset)) != nil,
              let cdData = try? handle.read(upToCount: Int(cdSize)),
              cdData.count == Int(cdSize) else { return nil }

        var entries: [Entry] = []
        entries.reserveCapacity(totalEntries)
        var cur = 0

        for _ in 0..<totalEntries {
            guard cur + 46 <= cdData.count else { break }
            guard cdData[cur] == 0x50 && cdData[cur + 1] == 0x4b &&
                  cdData[cur + 2] == 0x01 && cdData[cur + 3] == 0x02 else { break }

            let flags = readUInt16(cdData, at: cur + 8)
            let method = readUInt16(cdData, at: cur + 10)
            let compSize = readUInt32(cdData, at: cur + 20)
            let uncompSize = readUInt32(cdData, at: cur + 24)
            let nameLen = Int(readUInt16(cdData, at: cur + 28))
            let extraLen = Int(readUInt16(cdData, at: cur + 30))
            let commentLen = Int(readUInt16(cdData, at: cur + 32))
            let localOffset = readUInt32(cdData, at: cur + 42)

            guard cur + 46 + nameLen <= cdData.count else { break }
            let nameBytes = cdData.subdata(in: (cur + 46)..<(cur + 46 + nameLen))

            let extraBytes: Data
            if extraLen > 0 && cur + 46 + nameLen + extraLen <= cdData.count {
                extraBytes = cdData.subdata(in: (cur + 46 + nameLen)..<(cur + 46 + nameLen + extraLen))
            } else {
                extraBytes = Data()
            }

            let decodedName = decodeFileName(raw: nameBytes, extra: extraBytes, flags: flags)
            let isDir = decodedName.hasSuffix("/")

            entries.append(Entry(
                name: decodedName,
                isDirectory: isDir,
                compressionMethod: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset
            ))

            cur += 46 + nameLen + extraLen + commentLen
        }

        return entries
    }

    /// エントリを一時ファイルへ展開する。
    static func extract(entry: Entry, from archiveURL: URL, to destURL: URL) -> Bool {
        guard FileManager.default.createFile(atPath: destURL.path, contents: nil),
              let sink = try? FileHandle(forWritingTo: destURL),
              let source = try? FileHandle(forReadingFrom: archiveURL) else { return false }
        defer {
            try? sink.close()
            try? source.close()
        }

        // Local Header (PK\x03\x04) の先頭へ seek
        guard (try? source.seek(toOffset: UInt64(entry.localHeaderOffset))) != nil,
              let localHead = try? source.read(upToCount: 30),
              localHead.count == 30,
              localHead[0] == 0x50 && localHead[1] == 0x4b &&
              localHead[2] == 0x03 && localHead[3] == 0x04 else {
            try? FileManager.default.removeItem(at: destURL)
            return false
        }

        let localNameLen = Int(readUInt16(localHead, at: 26))
        let localExtraLen = Int(readUInt16(localHead, at: 28))
        let dataOffset = UInt64(entry.localHeaderOffset) + 30 + UInt64(localNameLen) + UInt64(localExtraLen)

        guard (try? source.seek(toOffset: dataOffset)) != nil else {
            try? FileManager.default.removeItem(at: destURL)
            return false
        }

        let success: Bool
        switch entry.compressionMethod {
        case 0:
            // 無圧縮 (Stored)
            success = copyStored(source: source, count: Int(entry.compressedSize), sink: sink)
        case 8:
            // Deflated (zlib raw inflate)
            success = inflateStream(source: source, compressedSize: Int(entry.compressedSize), sink: sink)
        default:
            success = false
        }

        guard success else {
            try? FileManager.default.removeItem(at: destURL)
            return false
        }

        let writtenSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        if entry.uncompressedSize > 0 && writtenSize == 0 {
            try? FileManager.default.removeItem(at: destURL)
            return false
        }
        return true
    }

    // MARK: - ファイル名デコード

    private static func decodeFileName(raw: Data, extra: Data, flags: UInt16) -> String {
        // 1. Info-ZIP Unicode Path Extra Field (Tag 0x7075 "up")
        if let unicodeName = extractUnicodePath(from: extra) {
            return unicodeName
        }

        // 2. フラグ bit 11 (0x0800: Language encoding flag) が立っていれば UTF-8
        let isUTF8 = (flags & (1 << 11)) != 0
        if isUTF8, let s = String(data: raw, encoding: .utf8) {
            return s
        }

        // 3. フラグが立っていない場合:
        // ASCII のみならそのまま UTF-8
        if raw.allSatisfy({ $0 < 0x80 }), let s = String(data: raw, encoding: .utf8) {
            return s
        }

        // 厳密な UTF-8 として有効か確認
        if let utf8String = String(data: raw, encoding: .utf8) {
            let detected = EncodingDetector.detect(raw)
            if detected == .shiftJIS, let sjis = decodeCP932(raw) {
                return sjis
            }
            return utf8String
        }

        // UTF-8 でデコードできなければ Shift-JIS (CP932)
        if let sjis = decodeCP932(raw) {
            return sjis
        }

        // 最後のフォールバック
        return String(decoding: raw, as: UTF8.self)
    }

    private static func decodeCP932(_ data: Data) -> String? {
        let cp932 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: cp932))
            ?? String(data: data, encoding: .shiftJIS)
    }

    private static func extractUnicodePath(from extra: Data) -> String? {
        var cur = 0
        while cur + 4 <= extra.count {
            let tag = readUInt16(extra, at: cur)
            let len = Int(readUInt16(extra, at: cur + 2))
            cur += 4
            guard cur + len <= extra.count else { break }
            if tag == 0x7075, len > 5 {
                // byte 0: version (1)
                // byte 1..4: crc32 of standard name
                // byte 5..: UTF-8 string
                let nameBytes = extra.subdata(in: (cur + 5)..<(cur + len))
                if let str = String(data: nameBytes, encoding: .utf8) {
                    return str
                }
            }
            cur += len
        }
        return nil
    }

    // MARK: - ストリーム展開

    private static func copyStored(source: FileHandle, count: Int, sink: FileHandle) -> Bool {
        var remaining = count
        let chunkSize = 64 * 1024
        while remaining > 0 {
            let toRead = min(remaining, chunkSize)
            guard let chunk = try? source.read(upToCount: toRead), !chunk.isEmpty else { return false }
            sink.write(chunk)
            remaining -= chunk.count
        }
        return true
    }

    private static func inflateStream(source: FileHandle, compressedSize: Int, sink: FileHandle) -> Bool {
        var stream = z_stream()
        let initRet = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initRet == Z_OK else { return false }
        defer { inflateEnd(&stream) }

        let inChunkSize = 64 * 1024
        let outChunkSize = 64 * 1024
        var outBuffer = [UInt8](repeating: 0, count: outChunkSize)

        var remainingIn = compressedSize
        var status = Z_OK

        while status == Z_OK && remainingIn > 0 {
            let toRead = min(remainingIn, inChunkSize)
            guard let inData = try? source.read(upToCount: toRead), !inData.isEmpty else { return false }
            remainingIn -= inData.count

            inData.withUnsafeBytes { rawIn in
                guard let inBase = rawIn.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                stream.next_in = UnsafeMutablePointer(mutating: inBase)
                stream.avail_in = uInt(inData.count)

                while stream.avail_in > 0 {
                    outBuffer.withUnsafeMutableBytes { rawOut in
                        guard let outBase = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        stream.next_out = outBase
                        stream.avail_out = uInt(outChunkSize)

                        status = inflate(&stream, Z_NO_FLUSH)
                    }

                    let produced = outChunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        sink.write(Data(outBuffer[0..<produced]))
                    }

                    if status == Z_STREAM_END { break }
                    guard status == Z_OK || status == Z_BUF_ERROR else { break }
                }
            }
        }

        while status == Z_OK {
            outBuffer.withUnsafeMutableBytes { rawOut in
                guard let outBase = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                stream.next_out = outBase
                stream.avail_out = uInt(outChunkSize)

                status = inflate(&stream, Z_FINISH)
            }
            let produced = outChunkSize - Int(stream.avail_out)
            if produced > 0 {
                sink.write(Data(outBuffer[0..<produced]))
            }
        }

        return status == Z_STREAM_END
    }

    // MARK: - バイナリ読み取り補助

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return b0 | (b1 << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
