import Foundation

/// 選択テキストを外部コマンド（`/bin/sh -c`）に stdin で渡し、stdout を受け取る。
/// vim の `!` フィルタ / BBEdit の Filter 相当。純粋な文字列 in → 文字列 out で、
/// UI やビューアには依存しない。デッドロック回避のため stdin 書き込みと stdout/stderr
/// 読み出しを別スレッドで並行させ、全体を timeout で打ち切る。
enum ShellFilter {
    enum Failure: Error, Equatable {
        case launchFailed(String)
        case timedOut
        case nonZeroExit(code: Int32, stderr: String)
    }

    /// `command` を実行し、`input` を stdin へ、stdout を文字列で返す。
    /// - 非ゼロ終了は `nonZeroExit`（stderr 付き）を投げる＝呼び出し側は本文を壊さず中止できる。
    /// - `timeout` 超過は子プロセスを terminate して `timedOut`。
    static func run(command: String, input: String, timeout: TimeInterval = 20) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do { try proc.run() }
        catch { throw Failure.launchFailed(error.localizedDescription) }

        // stdin 書き込み・stdout/stderr 読み出しを並行実行（パイプバッファ満杯での相互ブロックを防ぐ）。
        let io = DispatchGroup()
        io.enter()
        DispatchQueue.global().async {
            let handle = stdinPipe.fileHandleForWriting
            if !input.isEmpty { try? handle.write(contentsOf: Data(input.utf8)) }
            try? handle.close()
            io.leave()
        }
        var outData = Data(), errData = Data()
        io.enter()
        DispatchQueue.global().async { outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); io.leave() }
        io.enter()
        DispatchQueue.global().async { errData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); io.leave() }

        if io.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = io.wait(timeout: .now() + 2)   // 読み出しスレッドの後始末を待つ
            throw Failure.timedOut
        }
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let stderr = String(decoding: errData, as: UTF8.self)
            throw Failure.nonZeroExit(code: proc.terminationStatus, stderr: stderr)
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
