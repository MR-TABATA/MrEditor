import Foundation

/// 入口 —— 中身がファイルとして手元に無い場合に、開けるところまで持ってくる係。
///
/// この道具は「巨大なログを見る」ためのものなのに、**そのログは素のファイルとして
/// 転がっていないことが多い**。パイプの向こうにあるか、圧縮されている。入口が塞がって
/// いると、中でどれだけ機能を作っても届かない。
///
/// 変換した中身は一時ファイルに落とす。ビューアは mmap と索引でファイルを扱うので、
/// メモリ上のバイト列ではなく**実体のあるファイル**が要る（そのおかげで 10 GB でも開ける）。
public enum Intake {

    /// 標準入力がパイプ（あるいはリダイレクトされたファイル）として繋がっているか。
    ///
    /// `isatty` だけでは判定にならない —— Finder や Dock から起動したときも端末では
    /// ないので、常に真になってしまう。そのとき標準入力は `/dev/null`（キャラクタ
    /// デバイス）なので、**FIFO か通常ファイルのときだけ**受け取る。
    public static func stdinIsPiped(_ fd: Int32 = STDIN_FILENO) -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        let mode = st.st_mode & S_IFMT
        return mode == S_IFIFO || mode == S_IFREG
    }

    /// gzip かどうかを**中身で**見る。拡張子は嘘をつく（`.log` のまま gzip されたもの、
    /// `.gz` なのに素のテキスト、どちらも実際にある）。先頭 2 バイトが魔法の数。
    public static func isGzip(_ head: [UInt8]) -> Bool {
        head.count >= 2 && head[0] == 0x1f && head[1] == 0x8b
    }

    /// 一時ファイルの置き場。名前に元の名前を残す —— タブに `stdin-3f2a.tmp` と出ても
    /// 何を見ているのか分からない。
    public static func scratchURL(named name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MrEditor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}

extension Intake {

    /// 標準入力を読み切って一時ファイルに落とし、その URL を返す。
    ///
    /// 全部読んでから開く。伸びていくファイルを開く（`tail -f` 相当）のは別の機能で、
    /// **途中まで見せて「これで全部です」という顔をするほうが危ない**。
    /// 1 バイトも来なければ nil ＝ 何も開かない（空のタブだけが残るのを避ける）。
    public static func drainStdin(chunk: Int = 1 << 20) -> URL? {
        let url = scratchURL(named: "stdin-\(Int(Date().timeIntervalSince1970)).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let out = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? out.close() }

        let input = FileHandle.standardInput
        var total = 0
        while true {
            guard let data = try? input.read(upToCount: chunk), !data.isEmpty else { break }
            do { try out.write(contentsOf: data) } catch { break }
            total += data.count
        }
        guard total > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// gzip を展開して一時ファイルに落とす。展開できなければ nil（呼び手は元のまま開く）。
    ///
    /// `/usr/bin/gzip` に任せる。同じことを zlib で書くと、ヘッダ・複数メンバ・
    /// 破損時の扱いまで自分で持つことになる —— macOS に必ずある実装より正しく書ける
    /// 見込みが無い。**ストリームで渡すので、展開後が大きくてもメモリには載らない。**
    public static func gunzip(_ url: URL) -> URL? {
        let name = url.deletingPathExtension().lastPathComponent
        let out = scratchURL(named: name.isEmpty ? "gunzipped" : name)
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let sink = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? sink.close() }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        task.arguments = ["-dc", url.path]
        task.standardOutput = sink
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        task.waitUntilExit()
        // gzip は末尾が欠けた壊れたファイルでも、そこまでは展開して非 0 で終わる。
        // 出せたぶんがあるならそれを開く —— 落ちたログの尻尾が切れているのは日常で、
        // 「壊れているので何も見せません」は、この道具が一番してはいけない返事。
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        guard (size ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }
}
