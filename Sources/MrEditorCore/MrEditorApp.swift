import AppKit

/// 実行ファイルの入口。
public enum MrEditorApp {

    /// `NSApplication.delegate` は弱参照なので、ここで持ち続ける。
    /// （従来は `main.swift` のトップレベル定数がこの役目を担っていた。）
    private static var delegate: AppDelegate?

    public static func main() {
        // 2 回目の `| mreditor`：起動中の自分へ渡して終わる（B15）。
        if Intake.handOffStdinToRunningInstance() { exit(0) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}