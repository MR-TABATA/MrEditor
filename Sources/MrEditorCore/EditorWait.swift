import AppKit

/// `mreditor --wait <file>...` —— `$EDITOR` として呼ばれたとき、**タブを閉じるまで戻らない**ための仕組み。
///
/// `git commit` や `crontab -e` は、`$EDITOR` が終わるまで待ち、戻ったらファイルを読み直す。
/// 設計: `~/Git/Spec/MrEditor/editor-wait/design.md`。
///
/// - 待つ側（CLI）は、**GUI を作らない別プロセス**。アプリ本体が待ち手を兼ねると、初回起動のとき、
///   アプリが終わるまで呼び出し元が戻らなくなる。
/// - 依頼は**ファイル**で渡す（`wait-<id>.json`）。分散通知は、アプリが起動途中だと取りこぼすので、
///   通知は「見に来て」の合図にすぎず、アプリは起動時にも置き場を走査する。
/// - 完了は `wait-<id>.done`（終了コードを書く）。待つ側はこれを待つ。
public enum EditorWait {

    // MARK: 終了コード

    /// タブを閉じた（保存した・保存せず閉じた、どちらも）。
    public static let exitDone: Int32 = 0
    /// 使い方の間違い・存在しないパス・開けない種類・アプリが終了した、など。
    public static let exitFailure: Int32 = 1
    /// 待っている最中の Ctrl-C（128 + SIGINT）。
    public static let exitInterrupted: Int32 = 130

    // MARK: 依頼

    public struct Request: Codable, Equatable {
        public var id: String
        /// 待っている CLI の pid。死んでいれば、依頼は古い（アプリは開かない）。
        public var waiterPID: Int32
        /// 絶対パス。
        public var paths: [String]

        public init(id: String, waiterPID: Int32, paths: [String]) {
            self.id = id
            self.waiterPID = waiterPID
            self.paths = paths
        }
    }

    // MARK: 引数の解釈

    public enum Invocation: Equatable {
        /// `--wait` / `-w` が無い。通常の起動。
        case normal
        /// 待つ。`paths` はフラグを除いたもの（`--` の後ろは、`-` で始まっていてもパス）。
        case wait(paths: [String])
    }

    public static func parse(_ args: [String]) -> Invocation {
        var wait = false
        var paths: [String] = []
        var onlyPaths = false
        for a in args {
            if onlyPaths { paths.append(a); continue }
            if a == "--" { onlyPaths = true; continue }
            if a == "--wait" || a == "-w" { wait = true; continue }
            if a.hasPrefix("-") { continue }
            paths.append(a)
        }
        return wait ? .wait(paths: paths) : .normal
    }

    // MARK: パスの検査

    public enum PathProblem: Equatable {
        case missing(String)
        case directory(String)
        /// gzip・zip。開くと「展開した別ファイル」のタブになり、渡されたパスと結びつかない。
        case compressed(String)
        /// 開けない・先頭を読めない（権限など）。**検査を素通りさせない** —— 通すと、アプリ側で原因の分からない失敗になる。
        case unreadable(String)

        public var message: String {
            switch self {
            case .missing(let p): return "mreditor: ファイルが見つかりません: \(p)"
            case .directory(let p): return "mreditor: フォルダは編集できません: \(p)"
            case .compressed(let p): return "mreditor: 圧縮ファイル（gzip・zip）は --wait では開けません: \(p)"
            case .unreadable(let p): return "mreditor: ファイルを読めません（権限などを確かめてください）: \(p)"
            }
        }
    }

    /// 渡されたパスを、呼んだ側のカレントディレクトリで絶対パスにして、問題を集める。
    /// 問題が 1 つでもあれば、呼び手は何も開かずに終了コード 1 で終わる。
    public static func validate(_ paths: [String]) -> (urls: [URL], problems: [PathProblem]) {
        var urls: [URL] = []
        var problems: [PathProblem] = []
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                problems.append(.missing(p)); continue
            }
            if isDir.boolValue { problems.append(.directory(p)); continue }
            let head: [UInt8]
            do {
                let h = try FileHandle(forReadingFrom: url)
                defer { try? h.close() }
                // 空のファイルは `nil`（EOF）。空の COMMIT_EDITMSG はあり得るので、問題にしない。
                head = [UInt8](try h.read(upToCount: 4) ?? Data())
            } catch {
                problems.append(.unreadable(p)); continue
            }
            if Intake.isGzip(head) || Intake.isZip(head) { problems.append(.compressed(p)); continue }
            urls.append(url)
        }
        return (urls, problems)
    }

    // MARK: 依頼ファイル

    /// 依頼の置き場。自分だけが読み書きできるようにする（0700）。
    public static func defaultDirectory() -> URL {
        let dir = Intake.scratchURL(named: "wait")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func requestURL(_ id: String, in dir: URL) -> URL { dir.appendingPathComponent("wait-\(id).json") }
    static func doneURL(_ id: String, in dir: URL) -> URL { dir.appendingPathComponent("wait-\(id).done") }

    /// 依頼を書く。**書き終えてから名前を付ける**（アプリが書きかけを読まないように）。
    public static func write(_ request: Request, in dir: URL) throws {
        let data = try JSONEncoder().encode(request)
        let tmp = dir.appendingPathComponent(".wait-\(request.id).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dest = requestURL(request.id, in: dir)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// 置き場にある、有効な依頼。
    /// - **自分が持ち主でないファイルは読まない**（他のユーザーが依頼を置いて、任意のファイルを開かせないため）。
    /// - 待ち手（CLI）がもう死んでいる依頼は、古いので消して、返さない。
    public static func pending(
        in dir: URL,
        ownerID: uid_t = getuid(),
        isAlive: (Int32) -> Bool = processIsAlive
    ) -> [Request] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var result: [Request] = []
        for name in names.sorted() where name.hasPrefix("wait-") && name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == ownerID,
                  let data = try? Data(contentsOf: url),
                  let req = try? JSONDecoder().decode(Request.self, from: data),
                  // ファイル名と中身の id が食い違うものは、信用しない。
                  name == "wait-\(req.id).json" else { continue }
            if !isAlive(req.waiterPID) {
                cleanup(id: req.id, in: dir)
                continue
            }
            result.append(req)
        }
        return result
    }

    static func claimedURL(_ id: String, in dir: URL) -> URL { dir.appendingPathComponent("wait-\(id).claimed") }

    /// 完了を知らせる（アプリ側）。依頼がもう無い（待ち手が Ctrl-C で消えた）なら、何も書かず false。
    /// 書く中身は「終了コードの行」＋（あれば）待ち手が標準エラーに出す文言。
    @discardableResult
    public static func complete(id: String, status: Int32, message: String = "", in dir: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: requestURL(id, in: dir).path) else { return false }
        let body = message.isEmpty ? "\(status)\n" : "\(status)\n\(message)\n"
        return (try? Data(body.utf8).write(to: doneURL(id, in: dir), options: .atomic)) != nil
    }

    /// 完了を知らせる。**書けなかったときに、待ち手を黙って待たせ続けない。**
    /// 3 回まで試し、それでも書けなければ、依頼を取り下げる（待ち手は「依頼が取り下げられた」として 1 で戻る）。
    /// 待ち手がもういない（依頼が無い）ときは false。書けたら true。
    @discardableResult
    public static func finish(id: String, status: Int32, message: String = "", in dir: URL,
                              attempts: Int = 3) -> Bool {
        for _ in 0..<attempts {
            guard requestExists(id: id, in: dir) else { return false }
            if complete(id: id, status: status, message: message, in: dir) { return true }
        }
        NSLog("mreditor: 完了の合図を書けませんでした。依頼を取り下げます: %@", doneURL(id, in: dir).path)
        removeLoggingFailure(requestURL(id, in: dir))
        return false
    }

    /// アプリ側が「この依頼を受け取った」と知らせる。待ち手は、受け取られないまま長く待たない。
    public static func claim(id: String, in dir: URL) {
        FileManager.default.createFile(atPath: claimedURL(id, in: dir).path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
    }

    public static func isClaimed(id: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: claimedURL(id, in: dir).path)
    }

    private static func parseDone(id: String, in dir: URL) -> (status: Int32, message: String)? {
        guard let data = try? Data(contentsOf: doneURL(id, in: dir)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let first = lines.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        // 読めない中身は、失敗として扱う（0 と取り違えて、git に commit を続けさせない）。
        let status = Int32(first) ?? exitFailure
        let message = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (status, message)
    }

    public static func readStatus(id: String, in dir: URL) -> Int32? {
        parseDone(id: id, in: dir)?.status
    }

    /// 完了ファイルに添えられた文言（無ければ空）。
    public static func readMessage(id: String, in dir: URL) -> String {
        parseDone(id: id, in: dir)?.message ?? ""
    }

    /// 依頼ファイルがまだあるか。無ければ、待ち手はもういない（Ctrl-C・強制終了で片付けた）。
    public static func requestExists(id: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: requestURL(id, in: dir).path)
    }

    /// 消す。**「もう無い」以外の失敗は、記録する**（黙って捨てると、依頼が残り続けても気づけない）。
    @discardableResult
    private static func removeLoggingFailure(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile {
            return true   // もう無い
        } catch {
            NSLog("mreditor: 依頼のファイルを消せませんでした: %@ (%@)", url.path, "\(error)")
            return false
        }
    }

    /// 依頼に関わるファイルを全部消す。全部消せたら true。
    @discardableResult
    public static func cleanup(id: String, in dir: URL) -> Bool {
        let a = removeLoggingFailure(requestURL(id, in: dir))
        let b = removeLoggingFailure(doneURL(id, in: dir))
        let c = removeLoggingFailure(claimedURL(id, in: dir))
        return a && b && c
    }

    // MARK: 待つ

    public enum Completion: Equatable {
        case done(Int32)
        /// アプリが（待っている最中に）いなくなった。
        case appGone
        /// 完了の合図が無いまま、依頼ファイルが消えた（アプリが合図を書けず、取り下げた）。
        case requestGone
        /// アプリは生きているのに、一定時間たっても、依頼を受け取らない。
        case notPickedUp
    }

    /// 受け取られない依頼を待つ上限（秒）。コールドスタートの起動に十分な長さ。
    /// **編集に使える時間の上限ではない**（受け取られたあとは、いくらでも待つ）。
    static let claimTimeout: TimeInterval = 60

    /// 完了ファイルが現れるまで待つ。アプリが `deadLimit` 回続けていないと見えたら、`.appGone`。
    /// 起動の直後は、アプリがまだ見えないことがあるので、1 回の「いない」では諦めない。
    static func awaitCompletion(
        id: String,
        in dir: URL,
        appAlive: () -> Bool,
        deadLimit: Int = 3,
        claimTimeout: TimeInterval = EditorWait.claimTimeout,
        interval: TimeInterval = 0.2,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Completion {
        var dead = 0
        var waited: TimeInterval = 0
        while true {
            if let s = readStatus(id: id, in: dir) { return .done(s) }
            if !requestExists(id: id, in: dir) { return .requestGone }
            if !isClaimed(id: id, in: dir), waited >= claimTimeout { return .notPickedUp }
            if appAlive() { dead = 0 } else {
                dead += 1
                if dead >= deadLimit {
                    // 最後に、完了と入れ違いになっていないか見る。
                    if let s = readStatus(id: id, in: dir) { return .done(s) }
                    return .appGone
                }
            }
            sleep(interval)
            waited += interval
        }
    }

    /// 待った結果を、終了コードと、標準エラーに出す文言にする（画面にも通信にも触れない）。
    static func outcome(of completion: Completion, id: String, in dir: URL) -> (status: Int32, stderr: String?) {
        switch completion {
        case .done(let status):
            let m = readMessage(id: id, in: dir)
            return (status, m.isEmpty ? nil : m)
        case .appGone:
            return (exitFailure, "mreditor: MrEditor が終了しました。編集は完了していない可能性があります")
        case .requestGone:
            return (exitFailure, "mreditor: MrEditor が完了の合図を書けず、依頼が取り下げられました")
        case .notPickedUp:
            return (exitFailure, "mreditor: MrEditor が依頼を受け取りませんでした（応答がありません）")
        }
    }

    /// `.app` の位置。実行ファイル（symlink かもしれない）から、親をたどって探す。
    /// 見つからなければ nil（バンドル無しの開発起動）。
    static func appBundle(forExecutable url: URL) -> URL? {
        var u = url.resolvingSymlinksInPath()
        while u.path != "/" && !u.path.isEmpty {
            if u.pathExtension == "app" { return u }
            u.deleteLastPathComponent()
        }
        return nil
    }

    /// アプリへ「依頼を見に来て」と知らせる合図。バンドル ID を含める（配布版と開発ビルドが混ざらない）。
    public static var notificationName: Notification.Name {
        Intake.pipeNotificationName("wait", bundleID: Intake.bundleIdentifier)
    }

    // MARK: 入口（待つ側）

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// `--wait` で呼ばれたときの本体。`--wait` でなければ nil（通常どおり起動する）。
    /// 返した値が終了コード。**GUI は作らない。**
    public static func runIfRequested(
        args: [String] = Array(CommandLine.arguments.dropFirst())
    ) -> Int32? {
        guard case .wait(let given) = parse(args) else { return nil }
        guard !given.isEmpty else {
            say("mreditor: --wait にはファイルが要ります（例: mreditor --wait COMMIT_EDITMSG）")
            return exitFailure
        }
        let checked = validate(given)
        guard checked.problems.isEmpty else {
            checked.problems.forEach { say($0.message) }
            return exitFailure
        }

        let dir = defaultDirectory()
        let id = UUID().uuidString.lowercased()
        let request = Request(id: id, waiterPID: ProcessInfo.processInfo.processIdentifier,
                              paths: checked.urls.map(\.path))
        do { try write(request, in: dir) } catch {
            say("mreditor: 依頼を書けませんでした: \(error.localizedDescription)")
            return exitFailure
        }

        // Ctrl-C などで終わるときは、依頼を残さない（タブは残る）。
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler {
                cleanup(id: id, in: dir)
                exit(sig == SIGINT ? exitInterrupted : 128 + sig)
            }
            s.resume()
            sources.append(s)
        }
        defer { sources.forEach { $0.cancel() }; cleanup(id: id, in: dir) }

        // 起動中のアプリがあれば合図、無ければ起動する（起動したアプリは、起動時に置き場を走査する）。
        if Intake.otherInstanceRunning() {
            DistributedNotificationCenter.default().postNotificationName(
                notificationName, object: nil, userInfo: nil, deliverImmediately: true)
        } else {
            guard let exe = Intake.currentExecutableURL(), let app = appBundle(forExecutable: exe) else {
                say("mreditor: MrEditor を起動できません（アプリのバンドルが見つかりません）。先に MrEditor を起動してください")
                return exitFailure
            }
            guard launch(app) else {
                say("mreditor: MrEditor を起動できませんでした")
                return exitFailure
            }
        }

        let result = outcome(of: awaitCompletion(id: id, in: dir, appAlive: Intake.otherInstanceRunning),
                             id: id, in: dir)
        if let message = result.stderr { say(message) }
        return result.status
    }

    /// アプリを起動する（`open -W` は使わない。アプリが終わるまで戻らず、タブ単位では待てないため）。
    private static func launch(_ app: URL) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let ok = LaunchOK()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            ok.set(error == nil)
            done.signal()
        }
        return done.wait(timeout: .now() + 15) == .success && ok.get()
    }

    private final class LaunchOK: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}

/// アプリ側の帳簿: どの依頼が、どのタブ（ペイン）の閉じるのを待っているか。
/// 画面に触れない（ペインは `ObjectIdentifier` で持つ）ので、単体で確かめられる。
struct WaitBook {
    private var pending: [String: Set<ObjectIdentifier>] = [:]
    private var requestsOfPane: [ObjectIdentifier: Set<String>] = [:]
    /// 一度でも扱った依頼。**完了しても残す** —— 依頼ファイルは、待ち手が片付けるまで置き場に残るので、
    /// そのあいだに通知で再走査されても、同じファイルを開き直さないため。
    private var handled: Set<String> = []

    func hasRequest(_ id: String) -> Bool { pending[id] != nil }

    /// 待っている最中の依頼。
    var pendingIDs: [String] { pending.keys.sorted() }

    /// 扱い済み（待っている最中・完了・失敗のどれでも）。走査で、これは飛ばす。
    func isKnown(_ id: String) -> Bool { handled.contains(id) }

    /// 開けなくて失敗にした依頼を、扱い済みにする（待ち手が片付けるまで、再走査で開き直さない）。
    mutating func markFailed(request id: String) { handled.insert(id) }

    /// このペインを、誰かが待っているか（セッション復元・帯・⌘⇧T の判定に使う）。
    func isWaited(_ pane: ObjectIdentifier) -> Bool { requestsOfPane[pane] != nil }

    /// 依頼を登録する。`panes` が空なら登録しない（待つものが無い）。
    /// 同じ依頼を 2 度登録しても、何も起きない（通知と起動時の走査が重なるため）。
    @discardableResult
    mutating func register(request id: String, panes: [ObjectIdentifier]) -> Bool {
        guard !handled.contains(id), !panes.isEmpty else { return false }
        handled.insert(id)
        pending[id] = Set(panes)
        for p in panes { requestsOfPane[p, default: []].insert(id) }
        return true
    }

    /// ペインが閉じた。これで**全部閉じた**ことになった依頼の id を返す。
    /// 同じファイルを待つ依頼が複数あれば、閉じたとき全員が解放される。
    mutating func paneClosed(_ pane: ObjectIdentifier) -> [String] {
        guard let ids = requestsOfPane.removeValue(forKey: pane) else { return [] }
        var finished: [String] = []
        for id in ids.sorted() {
            pending[id]?.remove(pane)
            if pending[id]?.isEmpty == true {
                pending[id] = nil
                finished.append(id)
            }
        }
        return finished
    }

    /// アプリを（利用者の操作で）終了するとき: 待っている依頼を**全部**終わりにする。
    /// 「書き終わったからエディタを終了する」は自然な操作（vim の `:wq`）で、タブを閉じたのと同じ意味。
    /// 返した id の呼び出し元は、終了コード 0 で戻る。落ちたときは、ここを通らず、待ち手がアプリの消失で 1 を返す。
    mutating func releaseAll() -> [String] {
        let ids = pending.keys.sorted()
        pending.removeAll()
        requestsOfPane.removeAll()
        return ids
    }

    /// 依頼を取り下げる（開けなかったとき）。
    mutating func forget(request id: String) {
        guard let panes = pending.removeValue(forKey: id) else { return }
        for p in panes {
            requestsOfPane[p]?.remove(id)
            if requestsOfPane[p]?.isEmpty == true { requestsOfPane[p] = nil }
        }
    }
}
