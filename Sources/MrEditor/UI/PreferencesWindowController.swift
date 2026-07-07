import AppKit

/// 環境設定ウィンドウ（⌘,）。macOS 標準のツールバータブ構成。
/// 「一般」＝保存中の表示、「表示」＝フォント＋長い行。
/// 設定項目が増えても各ペイン VC を足すだけで済むよう、`NSTabViewController`
/// の `.toolbar` スタイルに委ねている。
final class PreferencesWindowController: NSWindowController {

    convenience init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        let general = GeneralPaneViewController()
        general.title = L("prefs.general")
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        tabs.addTabViewItem(generalItem)

        let display = DisplayPaneViewController()
        display.title = L("prefs.display")
        let displayItem = NSTabViewItem(viewController: display)
        displayItem.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
        tabs.addTabViewItem(displayItem)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = L("prefs.title")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.center()
    }

    /// ウィンドウを最前面に出す（無ければ生成済みのものを再利用）。
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 共通ヘルパ

private func heading(_ key: String) -> NSTextField {
    let f = NSTextField(labelWithString: L(key))
    f.font = .boldSystemFont(ofSize: 13)
    return f
}

private func makeStack(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
    return stack
}

private func pin(_ stack: NSStackView, in root: NSView) {
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        stack.topAnchor.constraint(equalTo: root.topAnchor),
        stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
}

// MARK: - 一般ペイン（保存中の表示）

private final class GeneralPaneViewController: NSViewController {
    private var statusBarRadio: NSButton!
    private var sheetRadio: NSButton!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))

        statusBarRadio = NSButton(radioButtonWithTitle: L("menu.saveProgress.statusBar"),
                                  target: self, action: #selector(radioChanged(_:)))
        sheetRadio = NSButton(radioButtonWithTitle: L("menu.saveProgress.sheet"),
                              target: self, action: #selector(radioChanged(_:)))

        let hint = NSTextField(wrappingLabelWithString: L("prefs.saveProgress.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = makeStack([heading("prefs.saveProgress"), statusBarRadio, sheetRadio, hint])
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        pin(stack, in: root)
        self.view = root
        syncRadios()
    }

    private func syncRadios() {
        let s = AppSettings.saveProgressStyle
        statusBarRadio.state = (s == .statusBar) ? .on : .off
        sheetRadio.state = (s == .sheet) ? .on : .off
    }

    @objc private func radioChanged(_ sender: NSButton) {
        AppSettings.saveProgressStyle = (sender === sheetRadio) ? .sheet : .statusBar
        syncRadios()
    }
}

// MARK: - 表示ペイン（フォント＋長い行）

private final class DisplayPaneViewController: NSViewController {
    private var fontPopup: NSPopUpButton!
    private var sizePopup: NSPopUpButton!
    private var sample: NSTextField!
    private var noWrapRadio: NSButton!
    private var wrapRadio: NSButton!

    /// nil（システム既定）を表す先頭項目の tag。
    private static let systemDefaultTag = -1

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))

        // --- フォント種別 ---
        fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let systemItem = NSMenuItem(title: L("prefs.font.system"), action: nil, keyEquivalent: "")
        systemItem.tag = Self.systemDefaultTag
        fontPopup.menu?.addItem(systemItem)
        fontPopup.menu?.addItem(.separator())
        for name in EditorFont.availableMonospaceFamilies() {
            fontPopup.addItem(withTitle: name)
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontPicked(_:))

        // --- サイズ ---
        sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for s in Int(EditorFont.minSize)...Int(EditorFont.maxSize) {
            sizePopup.addItem(withTitle: "\(s)")
            sizePopup.lastItem?.tag = s
        }
        sizePopup.target = self
        sizePopup.action = #selector(sizePicked(_:))
        let sizeLabel = NSTextField(labelWithString: L("prefs.font.size"))
        let ptLabel = NSTextField(labelWithString: L("prefs.font.pt"))
        ptLabel.textColor = .secondaryLabelColor

        let fontRow = NSStackView(views: [fontPopup, sizeLabel, sizePopup, ptLabel])
        fontRow.orientation = .horizontal
        fontRow.spacing = 8
        fontRow.alignment = .firstBaseline

        // --- ライブサンプル ---
        sample = NSTextField(labelWithString: "AaBbYy 0123 ()=>{} 日本語ログ")
        sample.textColor = .secondaryLabelColor
        sample.lineBreakMode = .byTruncatingTail

        // --- 長い行 ---
        noWrapRadio = NSButton(radioButtonWithTitle: L("prefs.lineWrap.off"),
                               target: self, action: #selector(wrapChanged(_:)))
        wrapRadio = NSButton(radioButtonWithTitle: L("prefs.lineWrap.on"),
                             target: self, action: #selector(wrapChanged(_:)))

        let sep = NSBox(); sep.boxType = .separator

        let stack = makeStack([heading("prefs.font"), fontRow, sample,
                               sep, heading("prefs.lineWrap"), noWrapRadio, wrapRadio])
        sep.widthAnchor.constraint(equalToConstant: 400).isActive = true
        pin(stack, in: root)
        self.view = root
        sync()
    }

    private func sync() {
        // フォント種別
        if let name = EditorFont.currentName, fontPopup.itemTitles.contains(name) {
            fontPopup.selectItem(withTitle: name)
        } else {
            fontPopup.selectItem(withTag: Self.systemDefaultTag)
        }
        // サイズ
        sizePopup.selectItem(withTag: Int(EditorFont.currentSize))
        // 長い行
        noWrapRadio.state = AppSettings.lineWrap ? .off : .on
        wrapRadio.state = AppSettings.lineWrap ? .on : .off
        // サンプルを現在のフォントで描く
        sample.font = EditorFont.current()
    }

    @objc private func fontPicked(_ sender: NSPopUpButton) {
        if sender.selectedItem?.tag == Self.systemDefaultTag {
            EditorFont.setName(nil)
        } else {
            EditorFont.setName(sender.titleOfSelectedItem)
        }
        sync()
    }

    @objc private func sizePicked(_ sender: NSPopUpButton) {
        EditorFont.setSize(CGFloat(sender.selectedTag()))
        sync()
    }

    @objc private func wrapChanged(_ sender: NSButton) {
        AppSettings.lineWrap = (sender === wrapRadio)
        sync()
    }
}
