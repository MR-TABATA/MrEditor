import AppKit

/// ビュープリセットの入口。構造化ヘッダのボタンから呼ばれる。
///
/// 分析(C1〜C5・C4)と違って「本文の下にペインを差す」機能ではなく、押した位置に
/// 一覧を出すだけの軽い操作なので、`AnalysisController` のような常設ペインは持たず
/// **NSMenu**（+保存/リネームのNSAlert）で組む。core が教えてくれるのは `window` だけ
/// なので、メニューはマウス位置(押した場所)にポップアップする。
@MainActor
final class ViewPresetController {
    private let store: ViewPresetStore
    /// メニュー項目のターゲット(closure を保持するためだけの存在)。メニューを出すたびに作り直す。
    private var actions: [MenuAction] = []

    init(store: ViewPresetStore = ViewPresetStore()) {
        self.store = store
    }

    /// `ProProvider.perform` から呼ばれる。表示できなければ false(core がビープを鳴らす)。
    @discardableResult
    func show(in window: NSWindow?) -> Bool {
        guard let window,
              let wc = window.windowController as? MainWindowController,
              let doc = wc.activeDocument,
              let mode = doc.structuredMode, mode == .csv || mode == .tsv || mode == .ndjson
        else {
            if let window { presentNoDocumentAlert(in: window) }
            return false
        }

        actions.removeAll()
        let menu = NSMenu()
        let matching = store.matching(mode: mode, columns: doc.columnNames)

        for preset in matching {
            let item = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
            item.submenu = presetSubmenu(for: preset, windowController: wc, in: window)
            menu.addItem(item)
        }
        if !matching.isEmpty { menu.addItem(.separator()) }

        menu.addItem(actionItem(S.viewPresetSaveCurrent) { [weak self] in
            self?.promptSaveCurrent(mode: mode, columns: doc.columnNames, widths: doc.columnWidths, in: window)
        })

        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        menu.popUp(positioning: nil, at: point, in: window.contentView)
        return true
    }

    private func presetSubmenu(for preset: ViewPreset, windowController wc: MainWindowController,
                               in window: NSWindow) -> NSMenu {
        let submenu = NSMenu()
        submenu.addItem(actionItem(S.viewPresetApply) { [weak wc] in
            wc?.applyViewPreset(order: preset.columnOrder, widths: preset.columnWidths)
        })
        submenu.addItem(actionItem(S.viewPresetRename) { [weak self] in
            self?.promptRename(preset, in: window)
        })
        submenu.addItem(actionItem(S.viewPresetDelete) { [weak self] in
            self?.store.delete(id: preset.id)
        })
        return submenu
    }

    // MARK: - ダイアログ

    private func promptSaveCurrent(mode: StructuredMode, columns: [String], widths: [String: Int],
                                   in window: NSWindow) {
        promptForName(title: S.viewPresetSaveTitle, message: S.viewPresetSaveMessage,
                     confirmTitle: S.viewPresetSave, initial: "", in: window) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            self.store.add(name: name, mode: mode, order: columns, widths: widths)
        }
    }

    private func promptRename(_ preset: ViewPreset, in window: NSWindow) {
        promptForName(title: S.viewPresetRenameTitle, message: "",
                     confirmTitle: S.viewPresetSave, initial: preset.name, in: window) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            self.store.rename(id: preset.id, to: name)
        }
    }

    private func presentNoDocumentAlert(in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = S.viewPresetNoDocument
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window)
    }

    /// 名前を1つ訊く小さいシート。**確定した文字列だけ** `completion` へ渡す(トリム済み)。
    private func promptForName(title: String, message: String, confirmTitle: String, initial: String,
                               in window: NSWindow, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        if !message.isEmpty { alert.informativeText = message }
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: S.viewPresetCancel)

        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.placeholderString = S.viewPresetNamePlaceholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(name)
        }
    }

    private func actionItem(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler: handler)
        actions.append(action)   // メニューが閉じるまで保持する(target は weak 参照)。
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        item.target = action
        return item
    }
}

/// NSMenuItem の target/action は selector しか取れないので、closure をここへ包む。
private final class MenuAction: NSObject {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
