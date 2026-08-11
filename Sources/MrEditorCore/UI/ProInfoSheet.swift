import AppKit

/// Pro 機能を無料版で押したときに出す説明。**1 枚で終わらせる。**
///
/// 方針（2026-08-11 決定）:
/// - メニュー項目は**グレーアウトしない**。macOS でのグレーは「いま条件が揃っていない」の
///   意味なので、「有料である」を伝えられない。押せて、押したら理由が分かるほうが親切。
/// - **押し売りしない**。常時バナー・起動時の勧誘は出さない。出るのはここだけ。
/// - **値段を書かない**。変わるので、値段は 1 箇所（LP）だけが持つ。
enum ProInfoSheet {

    /// Pro 版の案内ページ。
    static let learnMoreURL = URL(string: "https://mr-tabata.github.io/MrEditor/#pro")!

    static func present(_ feature: ProFeature, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = L("pro.sheet.title", L("\(feature.localizationKey).name"))
        alert.informativeText = L("\(feature.localizationKey).blurb")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("pro.sheet.learnMore"))
        alert.addButton(withTitle: L("pro.sheet.later"))

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(learnMoreURL)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}