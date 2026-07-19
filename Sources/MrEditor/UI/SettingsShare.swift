import AppKit
import UniformTypeIdentifiers

/// 外観設定（[[SettingsBundle]]）の書き出し・読み込み・共有リンクの UI 側配線。
/// 環境設定「配色」ペインのボタンと、`mreditor://` リンクを開いたときの `AppDelegate`
/// から呼ばれる。適用は必ず確認をはさむ（他人のリンク／ファイルで見た目が黙って変わらないため）。
enum SettingsShare {

    /// 書き出し用ファイルの UTType（未登録拡張子なので動的型・無ければ JSON 扱い）。
    private static var fileType: UTType {
        UTType(filenameExtension: SettingsBundle.fileExtension) ?? .json
    }

    // MARK: - 書き出し

    /// 現在の外観をファイル（.mreditortheme）へ書き出す。
    static func export(presenting window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [fileType]
        panel.nameFieldStringValue = "\(L("prefs.share.export.defaultName")).\(SettingsBundle.fileExtension)"
        let write: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? SettingsBundle.capture().jsonData().write(to: url, options: .atomic)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) }
        else { write(panel.runModal()) }
    }

    // MARK: - 読み込み（ファイル）

    /// ファイルから外観を読み込み、確認のうえ適用する。
    static func importFromFile(presenting window: NSWindow?, onApplied: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType, .json]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        let read: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let bundle = try SettingsBundle.decode(fromJSON: data)
                confirmAndApply(bundle, presenting: window, onApplied: onApplied)
            } catch {
                showFailure(presenting: window)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: read) }
        else { read(panel.runModal()) }
    }

    // MARK: - 共有リンク

    /// 現在の外観を共有リンク（`mreditor://theme?d=…`）にしてクリップボードへ。
    static func copyShareLink() {
        let url = SettingsBundle.capture().shareURL()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// クリップボードの文字列を共有リンク（または base64url）として読み込み、確認のうえ適用する。
    static func importFromClipboard(presenting window: NSWindow?, onApplied: (() -> Void)? = nil) {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            showEmptyClipboard(presenting: window)
            return
        }
        let bundle: SettingsBundle?
        if let url = URL(string: raw), SettingsBundle.isSettingsURL(url) {
            bundle = try? SettingsBundle.decode(fromURL: url)
        } else {
            bundle = try? SettingsBundle.decode(fromEncoded: raw)
        }
        if let bundle {
            confirmAndApply(bundle, presenting: window, onApplied: onApplied)
        } else {
            showFailure(presenting: window)
        }
    }

    /// `mreditor://` リンクを開いたとき（`AppDelegate`）に確認のうえ適用する。
    static func apply(url: URL, presenting window: NSWindow?, onApplied: (() -> Void)? = nil) {
        do {
            let bundle = try SettingsBundle.decode(fromURL: url)
            confirmAndApply(bundle, presenting: window, onApplied: onApplied)
        } catch {
            showFailure(presenting: window)
        }
    }

    // MARK: - 確認シート

    private static func confirmAndApply(_ bundle: SettingsBundle, presenting window: NSWindow?,
                                        onApplied: (() -> Void)?) {
        let alert = NSAlert()
        alert.messageText = L("share.apply.title")
        alert.informativeText = bundle.summaryLines().joined(separator: "\n")
        alert.addButton(withTitle: L("share.apply.confirm"))
        alert.addButton(withTitle: L("common.cancel"))
        let apply: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .alertFirstButtonReturn else { return }
            bundle.apply()
            onApplied?()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: apply) }
        else { apply(alert.runModal()) }
    }

    private static func showFailure(presenting window: NSWindow?) {
        alert(title: L("share.import.failed.title"), message: L("share.import.failed.message"), window: window)
    }

    private static func showEmptyClipboard(presenting window: NSWindow?) {
        alert(title: L("share.clipboard.empty.title"), message: L("share.clipboard.empty.message"), window: window)
    }

    private static func alert(title: String, message: String, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: L("common.ok"))
        if let window { a.beginSheetModal(for: window, completionHandler: nil) }
        else { a.runModal() }
    }
}
