import Foundation

/// 実際に `/usr/bin/ssh` を起動して、1 本の遠隔ファイルを開けるところまで持ってくる係。
///
/// `RemoteFile` が「何を向こうで走らせるか」を決め、ここが「走らせて受け取る」。
/// 分けてあるのは、**組み立てた文字列はサーバー無しで試験できる**から
/// （`RemoteFileTests` は手元の `/bin/sh` に同じ文字列を通して確かめている）。
///
/// **受け取りは `Data` で行う。** 範囲読みが返すのはテキストとは限らず、
/// 文字列に通すと不正なバイト列が置換文字に化けて、**取ってきた中身が静かに変わる。**
public final class RemoteSession {

    public let target: RemoteFile.Target
    /// 向こうに在ったコマンド。欠けていれば、その機能を畳む材料（`degraded`）。
    public let capabilities: RemoteFile.Capabilities

    public enum Failure: Error, Equatable {
        /// ssh が起動できない（`/usr/bin/ssh` が無い等）。
        case launchFailed(String)
        /// 応答が無い。**遠隔では「遅い」と「死んだ」が見分けられない**ので時間で切る。
        case timedOut
        /// ssh か向こうのコマンドが失敗した。stderr をそのまま持つ ――
        /// 「Permission denied」「No such file」は人が読めば分かるので、こちらで言い換えない。
        case failed(status: Int32, stderr: String)
        /// 繋がったが、読み出しに要るコマンドが向こうに無い。
        case cannotRead
    }

    private init(target: RemoteFile.Target, capabilities: RemoteFile.Capabilities) {
        self.target = target
        self.capabilities = capabilities
    }

    /// 繋いで能力を検出する。**1 往復で全部訊く。**
    public static func connect(
        to target: RemoteFile.Target,
        timeout: TimeInterval = 20
    ) throws -> RemoteSession {
        let out = try run(host: target.host, command: RemoteFile.capabilityCommand(), timeout: timeout)
        let caps = RemoteFile.Capabilities.parse(String(decoding: out, as: UTF8.self))
        guard caps.canRead else { throw Failure.cannotRead }
        return RemoteSession(target: target, capabilities: caps)
    }

    /// 総バイト数。訊けなければ nil ＝ **「不明」**（0 とは書かない）。
    public func size(timeout: TimeInterval = 20) -> Int? {
        guard capabilities.canSize else { return nil }
        guard let out = try? Self.run(
            host: target.host,
            command: RemoteFile.sizeCommand(target.path),
            timeout: timeout
        ) else { return nil }
        return RemoteFile.parseSize(String(decoding: out, as: UTF8.self))
    }

    /// 総行数。**向こうで数えるので転送はゼロ**だが、10GB なら向こうで数秒かかる。
    /// だから開くのを待たせず、後から埋める使い方をする。
    public func lineCount(timeout: TimeInterval = 180) -> Int? {
        guard capabilities.canSize else { return nil }
        guard let out = try? Self.run(
            host: target.host,
            command: RemoteFile.lineCountCommand(target.path),
            timeout: timeout
        ) else { return nil }
        return RemoteFile.parseSize(String(decoding: out, as: UTF8.self))
    }

    /// 末尾の N バイトを行にして返す。**最初に見せるのはここ** ―― 障害は末尾にある。
    ///
    /// サイズが訊けるなら範囲読み（`count - N ..< count`）で取り、
    /// 訊けなければ `tail -c` に落とす。`totalLines` を渡せば本物の行番号が付く。
    public func tailLines(bytes: Int = 64 << 10, totalLines: Int? = nil) -> [RemoteLine] {
        let total = size()
        let data: Data?
        let endsAt: Int
        if let total, total > 0 {
            let from = max(0, total - bytes)
            data = read(offset: from, length: total - from)
            endsAt = total
        } else {
            data = tail(bytes: bytes)
            endsAt = data?.count ?? 0     // 全体の位置が分からない ＝ 欠けの判定もできない
        }
        guard let data else { return [] }

        var dropped = false
        return RemoteLines.fromTail(data, endsAtByte: endsAt, totalLines: totalLines, droppedLeadingPartial: &dropped)
    }

    /// 絞り込みの結果を、並べる行として返す。
    public func searchLines(pattern: String, context: Int = 0, ignoreCase: Bool = false, regex: Bool = false) -> [RemoteLine]? {
        guard let matches = grep(pattern: pattern, context: context, ignoreCase: ignoreCase, regex: regex) else {
            return nil
        }
        return RemoteLines.fromMatches(matches)
    }

    /// 範囲を 1 回取ってくる。返りが短いのは EOF。失敗は nil。
    public func read(offset: Int, length: Int, timeout: TimeInterval = 30) -> Data? {
        guard length > 0 else { return Data() }
        return try? Self.run(
            host: target.host,
            command: RemoteFile.readCommand(target.path, offset: offset, length: length),
            timeout: timeout
        )
    }

    /// **向こうで絞る。** 遠隔で一番効く一手 ―― 10GB を 1 バイトも転送せずに、
    /// 一致行と行番号だけが返る。手元の mmap 走査より速い（送らないので）。
    ///
    /// `grep` が無ければ nil。呼び出し側は手元へ引いて絞ることになる（`degraded` に出る）。
    public func grep(
        pattern: String,
        context: Int = 0,
        ignoreCase: Bool = false,
        regex: Bool = false,
        maxMatches: Int = 5000,
        timeout: TimeInterval = 120
    ) -> [RemoteFile.Match]? {
        guard capabilities.canFilter, !pattern.isEmpty else { return nil }
        let command = RemoteFile.grepCommand(
            target.path, pattern: pattern, context: context,
            ignoreCase: ignoreCase, regex: regex, maxMatches: maxMatches
        )
        // 大きなファイルを舐めるので時間は長め。それでも切るのは、
        // 遠隔では「遅い」と「死んだ」が見分けられないため。
        guard let out = try? Self.run(host: target.host, command: command, timeout: timeout) else {
            return nil
        }
        return RemoteFile.parseGrep(String(decoding: out, as: UTF8.self))
    }

    /// 末尾から N バイト。**サイズが訊けないときの逃げ道**（訊けるなら範囲読みで足りる）。
    public func tail(bytes: Int, timeout: TimeInterval = 30) -> Data? {
        guard capabilities.canFollow, bytes > 0 else { return nil }
        return try? Self.run(
            host: target.host,
            command: RemoteFile.tailCommand(target.path, bytes: bytes),
            timeout: timeout
        )
    }

    /// ビューアに渡す緩衝を開く。**ここで初めて手元に疎ファイルができる。**
    /// サイズが訊けなければ開かない ―― 長さの分からないものは、疎ファイルに写せない。
    /// （`FileBuffer` と同じく internal。ビューアの内側でしか使わない）
    func openBuffer() -> RemoteBuffer? {
        guard let total = size() else { return nil }
        let name = "remote-\(abs(target.host.hashValue &+ target.path.hashValue)).cache"
        let url = Intake.scratchURL(named: name)
        return RemoteBuffer(count: total, cacheURL: url) { [weak self] offset, length in
            self?.read(offset: offset, length: length)
        }
    }

    // MARK: - ssh を起動する

    /// `/usr/bin/ssh` を直接起動する。**`/bin/sh -c` を挟まない** ――
    /// 挟むと引数がもう一段シェルに解釈され、こちらで包んだ引用符が意味を失う。
    /// 向こう側で 1 回だけシェルに渡るのが正しい（`RemoteFile.shellQuote` はそのための包み）。
    static func run(host: String, command: String, timeout: TimeInterval) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = RemoteFile.sshArguments(host: host, remoteCommand: command)

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardInput = FileHandle.nullDevice   // 端末を要求させない
        proc.standardError = errPipe

        do { try proc.run() }
        catch { throw Failure.launchFailed(error.localizedDescription) }

        // stdout/stderr を並行に読み切る（パイプが詰まって相互ブロックするのを防ぐ）。
        var outData = Data(), errData = Data()
        let io = DispatchGroup()
        io.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); io.leave() }
        io.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); io.leave() }

        if io.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = io.wait(timeout: .now() + 2)
            throw Failure.timedOut
        }
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw Failure.failed(
                status: proc.terminationStatus,
                stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return outData
    }
}
