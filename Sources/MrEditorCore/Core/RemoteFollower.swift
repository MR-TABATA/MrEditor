import Foundation

/// 遠隔の末尾を追う（`tail -f` を向こうで走らせて流し込む）。
///
/// **手元の追従とは経路が別。** 手元は `fstat` で伸びを見て mmap を継ぎ足すが、
/// 遠隔でそれをやると、伸びを知るためだけに `wc -c` を投げ続けることになる。
/// 向こうの `tail -f` に流させるほうが素直で、しかも遅延が小さい。
///
/// **止めるのを忘れない。** ssh の子プロセスは、こちらが黙って窓を閉じても
/// 向こうで動き続ける。`stop()` を deinit でも呼ぶ。
public final class RemoteFollower {

    /// 完成した行が届いたときに呼ばれる。**呼ばれるのは main。**
    public var onLines: (([String]) -> Void)?
    /// 流れが切れたときに呼ばれる（向こうの終了・接続断・停止）。
    public var onEnd: (() -> Void)?

    private let target: RemoteFile.Target
    private var process: Process?
    private var accumulator = LineAccumulator()
    private let lock = NSLock()
    /// **開いたまま持っておく標準入力。** これが閉じると向こうの見張りが EOF を受け、
    /// `tail` を殺して終わる。/dev/null にすると即 EOF になり、追う前に終わってしまう。
    private var stdin: Pipe?

    public init(target: RemoteFile.Target) {
        self.target = target
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// 追い始める。`fromBytes` は最初に出す末尾の量（`tail -c N -f`）。
    ///
    /// 既に走っていれば何もしない ―― 二重に起動すると同じ行が 2 回並ぶ。
    public func start(fromBytes: Int = 0) {
        lock.lock()
        guard process == nil else { lock.unlock(); return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = RemoteFile.sshArguments(
            host: target.host,
            remoteCommand: RemoteFile.followCommand(target.path, bytes: fromBytes)
        )
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        let input = Pipe()
        proc.standardInput = input
        self.stdin = input
        self.process = proc
        lock.unlock()

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {                       // EOF
                handle.readabilityHandler = nil
                let rest = self.accumulator.flush()
                DispatchQueue.main.async {
                    if !rest.isEmpty { self.onLines?(rest) }
                    self.onEnd?()
                }
                return
            }
            let lines = self.accumulator.take(chunk)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { self.onLines?(lines) }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.process = nil; self.lock.unlock()
            DispatchQueue.main.async { self.onEnd?() }
        }

        do { try proc.run() } catch {
            lock.lock(); process = nil; lock.unlock()
            DispatchQueue.main.async { self.onEnd?() }
        }
    }

    /// 止める。**向こうの `tail -f` も一緒に終わらせる**（ssh を切れば道連れになる）。
    public func stop() {
        lock.lock()
        let proc = process
        process = nil
        lock.unlock()

        guard let proc, proc.isRunning else { stdin = nil; return }
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        // まず標準入力を閉じる ―― 向こうの見張りが EOF を受けて tail を殺す。
        // その後に ssh を終わらせる（順番が逆だと、向こうへ伝わる前に切れる）。
        try? stdin?.fileHandleForWriting.close()
        stdin = nil
        proc.terminate()
    }
}
