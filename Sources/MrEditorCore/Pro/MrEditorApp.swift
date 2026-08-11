import AppKit

/// 実行ファイルの入口。無料版（MrEditor）と Pro 版（MrkEditor）で**同じここ**を通る。
///
/// 違いは `pro` に何かを渡すかどうかだけ。無料ビルドは `nil` で呼ぶので、
/// Pro のコードはリンクすらされない（＝ public リポに Pro が混ざりようがない）。
public enum MrEditorApp {

    /// `NSApplication.delegate` は弱参照なので、ここで持ち続ける。
    /// （従来は `main.swift` のトップレベル定数がこの役目を担っていた。）
    private static var delegate: AppDelegate?

    public static func main(pro: ProProvider? = nil) {
        if let pro { Pro.install(pro) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}