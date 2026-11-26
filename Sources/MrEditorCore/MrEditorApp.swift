import AppKit

/// 実行ファイルの入口。
public enum MrEditorApp {

    /// `NSApplication.delegate` は弱参照なので、ここで持ち続ける。
    /// （従来は `main.swift` のトップレベル定数がこの役目を担っていた。）
    private static var delegate: AppDelegate?

    public static func main() {
        // 起動中の自分がいれば、2 つ目のアプリを立ち上げずに渡して終わる。
        //   2 回目の `| mreditor`（B15）／`mreditor file`／端末で引数なしの `mreditor`（前に出すだけ）。
        let route = Intake.route(stdinHandOff: Intake.handOffStdinToRunningInstance,
                                 files: Intake.fileArguments(),
                                 handOffFiles: Intake.handOffFilesToRunningInstance,
                                 isBareTerminalLaunch: Intake.isBareTerminalLaunch(),
                                 bringToFront: Intake.bringRunningInstanceToFront)
        if let status = route.exitStatus {
            // 返事が無いときは、渡せているかもしれない。自分で開くと同じファイルが二重に開くので、
            // 何もせず（理由だけ出して）終わる。
            if route == .noReply { FileHandle.standardError.write(Data(Intake.noReplyMessage.utf8)) }
            exit(status)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}