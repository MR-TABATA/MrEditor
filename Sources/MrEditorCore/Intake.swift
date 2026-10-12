import AppKit

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

    /// 開けと言われたものが、手元か遠隔か。
    ///
    /// **判定は 1 か所に閉じる。** 「ssh っぽい文字列」をあちこちで見分け始めると、
    /// コマンドラインとドラッグ＆ドロップと「最近使った項目」で挙動が割れる。
    public enum Source: Equatable {
        case local(URL)
        case remote(RemoteFile.Target)
    }

    /// 文字列を、開く先に解決する。
    ///
    /// `ssh host:/path` と `host:/path` だけが遠隔。それ以外は**すべて手元のパス**として
    /// 扱う ―― 曖昧なものを遠隔に倒すと、`C:/…` や時刻を含む名前が ssh に飛んでいく。
    public static func resolve(_ text: String) -> Source {
        if let target = RemoteFile.parse(text) { return .remote(target) }
        return .local(URL(fileURLWithPath: (text as NSString).expandingTildeInPath))
    }

    /// 標準入力を読み切って一時ファイルに落とし、その URL を返す。
    ///
    /// 全部読んでから開く。伸びていくファイルを開く（`tail -f` 相当）のは別の機能で、
    /// **途中まで見せて「これで全部です」という顔をするほうが危ない**。
    /// 1 バイトも来なければ nil ＝ 何も開かない（空のタブだけが残るのを避ける）。
    public static func drainStdin(chunk: Int = 1 << 20) -> URL? {
        let url = scratchURL(named: "stdin-\(Int(Date().timeIntervalSince1970))-\(getpid()).log")
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

    /// 標準入力を一時ファイルへ書き足しながら読む（`tail -f … | mreditor`・B15）。
    ///
    /// **最初のデータが届いた時点で `onFirstData` を呼ぶ**（終わらない入力でも画面に出す）。
    /// 読み切る（EOF）まで戻らない。呼び手は読み終わりを `onEnd` で知る。
    /// 何も来なければ一時ファイルを消して、どちらも呼ばない。
    public static func streamStdin(chunk: Int = 1 << 16,
                                   onFirstData: (URL) -> Void,
                                   onEnd: (URL) -> Void) {
        let url = scratchURL(named: "stdin-\(Int(Date().timeIntervalSince1970))-\(getpid()).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let out = try? FileHandle(forWritingTo: url) else { return }
        defer { try? out.close() }

        // `FileHandle.read(upToCount:)` は指定バイト数が溜まるか EOF まで戻らない。
        // `tail -f` のように少しずつ来る入力では、届いた分で返る read(2) を直接使う。
        var buf = [UInt8](repeating: 0, count: chunk)
        var started = false
        while true {
            let n = buf.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, chunk) }
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { break }
            do { try out.write(contentsOf: Data(buf[0..<n])) } catch { break }
            if !started { started = true; onFirstData(url) }
        }
        if started { onEnd(url) } else { try? FileManager.default.removeItem(at: url) }
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

extension Intake {

    /// zip かどうかを中身で見る。`PK\x03\x04` が通常、`PK\x05\x06` は空の書庫。
    public static func isZip(_ head: [UInt8]) -> Bool {
        guard head.count >= 4, head[0] == 0x50, head[1] == 0x4b else { return false }
        return (head[2] == 0x03 && head[3] == 0x04) || (head[2] == 0x05 && head[3] == 0x06)
    }

    /// 書庫に入っているファイルの名前。**ディレクトリと macOS の付属物は落とす。**
    ///
    /// `__MACOSX/` と `.DS_Store` は、Finder で圧縮すると必ず入る。それを一覧に出すと
    /// 「どれを開くか」の選択肢が実際の倍になり、しかも中身は誰も読みたくないもの。
    public static func zipEntries(_ url: URL) -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-Z1", url.path]          // 1 行 1 名前
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { name in
                !name.hasSuffix("/")                        // ディレクトリ
                    && !name.hasPrefix("__MACOSX/")         // Finder の付属物
                    && !name.hasSuffix(".DS_Store")
                    && !name.isEmpty
            }
    }

    /// 書庫から 1 つ取り出して一時ファイルに落とす。名前は**書庫の中の名前**を使う ——
    /// タブに `archive.zip` と出ても、その中のどれを見ているのか分からない。
    public static func unzip(_ url: URL, entry: String) -> URL? {
        let leaf = entry.split(separator: "/").last.map(String.init) ?? entry
        let out = scratchURL(named: leaf.isEmpty ? "unzipped" : leaf)
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let sink = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? sink.close() }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", url.path, entry]    // -p = 標準出力へ流す（展開先を汚さない）
        task.standardOutput = sink
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        task.waitUntilExit()
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        guard (size ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }
}


extension Intake {

    /// 起動中の自分（同じバンドル ID）へ流し込むための合図。
    ///
    /// `| mreditor` はアプリの実行ファイルを直接起動するので、放っておくと叩くたびに
    /// 別のプロセスと別のウィンドウになる（下書きも二重に読む）。**2 回目以降は、
    /// 読み切った一時ファイルのパスだけを先に起きている自分へ渡して、自分は終わる。**
    public static let pipeNotification = Notification.Name("app.aaedit.MrEditor.pipe")
    /// 入力が終わった合図（追従をやめてよい）。
    public static let pipeEndNotification = Notification.Name("app.aaedit.MrEditor.pipeEnd")

    /// 自分以外に、同じバンドル ID で起動しているプロセスがあるか。
    public static func otherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// 渡された一時ファイルが、こちらの置き場の中のものか。分散通知は誰でも投げられるので、
    /// 置き場の外のパスを開かされないようにする。
    public static func isScratchFile(_ url: URL) -> Bool {
        let dir = scratchURL(named: "x").deletingLastPathComponent().resolvingSymlinksInPath()
        return url.resolvingSymlinksInPath().deletingLastPathComponent() == dir
    }

    /// 流し込み（`| mreditor`）の一時ファイルか。元のパイプが終われば二度と増えない断片なので、
    /// 前回のセッションには残さない（復元しても止まったログが出るだけ）。
    public static func isPipedStream(_ url: URL) -> Bool {
        isScratchFile(url) && url.lastPathComponent.hasPrefix("stdin-")
    }

    /// 標準入力がパイプで、かつ起動中の自分がいるなら、読み切って渡して true を返す
    /// （呼び手はそのまま終わる）。渡せなかった・1 バイトも来なかったときは false。
    public static func handOffStdinToRunningInstance() -> Bool {
        guard stdinIsPiped(), otherInstanceRunning() else { return false }
        // 最初のデータで渡し、終わるまで書き足し続ける（終わらない入力でも画面に出る）。
        // 空入力は何も開かずに終わる。
        let center = DistributedNotificationCenter.default()
        streamStdin(onFirstData: { url in
            center.postNotificationName(pipeNotification, object: nil,
                                        userInfo: ["path": url.path], deliverImmediately: true)
        }, onEnd: { url in
            center.postNotificationName(pipeEndNotification, object: nil,
                                        userInfo: ["path": url.path], deliverImmediately: true)
        })
        return true
    }
}
