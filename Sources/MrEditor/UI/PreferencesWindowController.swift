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

// MARK: - 表示ペイン（フォント・本文体裁・長い行）

private final class DisplayPaneViewController: NSViewController {
    private var fontPopup: NSPopUpButton!
    private var sizePopup: NSPopUpButton!
    private var sample: NSTextField!
    private var tabWidthPopup: NSPopUpButton!
    private var lineSpacingPopup: NSPopUpButton!
    private var highlightCheck: NSButton!
    private var cursorPopup: NSPopUpButton!
    private var noWrapRadio: NSButton!
    private var wrapRadio: NSButton!

    /// nil（システム既定）を表す先頭項目の tag。
    private static let systemDefaultTag = -1

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 460))

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
        let ptLabel = NSTextField(labelWithString: L("prefs.font.pt"))
        ptLabel.textColor = .secondaryLabelColor

        let fontRow = NSStackView(views: [fontPopup, label("prefs.font.size"), sizePopup, ptLabel])
        fontRow.orientation = .horizontal
        fontRow.spacing = 8
        fontRow.alignment = .firstBaseline

        // --- ライブサンプル ---
        sample = NSTextField(labelWithString: "AaBbYy 0123 ()=>{} 日本語ログ")
        sample.textColor = .secondaryLabelColor
        sample.lineBreakMode = .byTruncatingTail

        // --- タブ幅・行間 ---
        tabWidthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for w in [2, 4, 8] { tabWidthPopup.addItem(withTitle: "\(w)"); tabWidthPopup.lastItem?.tag = w }
        tabWidthPopup.target = self
        tabWidthPopup.action = #selector(tabWidthPicked(_:))

        lineSpacingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, s) in LineSpacing.allCases.enumerated() {
            lineSpacingPopup.addItem(withTitle: L("prefs.lineSpacing.\(s.rawValue)"))
            lineSpacingPopup.lastItem?.tag = i
        }
        lineSpacingPopup.target = self
        lineSpacingPopup.action = #selector(lineSpacingPicked(_:))

        let metricsRow = NSStackView(views: [label("prefs.tabWidth"), tabWidthPopup,
                                             label("prefs.lineSpacing"), lineSpacingPopup])
        metricsRow.orientation = .horizontal
        metricsRow.spacing = 8
        metricsRow.alignment = .firstBaseline

        // --- 現在行ハイライト ---
        highlightCheck = NSButton(checkboxWithTitle: L("prefs.highlightCurrentLine"),
                                  target: self, action: #selector(highlightChanged(_:)))

        // --- カーソル形状 ---
        cursorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, c) in CursorShape.allCases.enumerated() {
            cursorPopup.addItem(withTitle: L("prefs.cursorShape.\(c.rawValue)"))
            cursorPopup.lastItem?.tag = i
        }
        cursorPopup.target = self
        cursorPopup.action = #selector(cursorPicked(_:))
        let cursorRow = NSStackView(views: [label("prefs.cursorShape"), cursorPopup])
        cursorRow.orientation = .horizontal
        cursorRow.spacing = 8
        cursorRow.alignment = .firstBaseline

        // --- 長い行 ---
        noWrapRadio = NSButton(radioButtonWithTitle: L("prefs.lineWrap.off"),
                               target: self, action: #selector(wrapChanged(_:)))
        wrapRadio = NSButton(radioButtonWithTitle: L("prefs.lineWrap.on"),
                             target: self, action: #selector(wrapChanged(_:)))

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        let stack = makeStack([heading("prefs.font"), fontRow, sample,
                               sep1,
                               heading("prefs.text"), metricsRow, highlightCheck, cursorRow,
                               sep2,
                               heading("prefs.lineWrap"), noWrapRadio, wrapRadio])
        sep1.widthAnchor.constraint(equalToConstant: 400).isActive = true
        sep2.widthAnchor.constraint(equalToConstant: 400).isActive = true
        pin(stack, in: root)
        self.view = root
        sync()
    }

    private func label(_ key: String) -> NSTextField { NSTextField(labelWithString: L(key)) }

    private func sync() {
        // フォント種別
        if let name = EditorFont.currentName, fontPopup.itemTitles.contains(name) {
            fontPopup.selectItem(withTitle: name)
        } else {
            fontPopup.selectItem(withTag: Self.systemDefaultTag)
        }
        sizePopup.selectItem(withTag: Int(EditorFont.currentSize))
        tabWidthPopup.selectItem(withTag: AppSettings.tabWidth)
        lineSpacingPopup.selectItem(withTag: LineSpacing.allCases.firstIndex(of: AppSettings.lineSpacing) ?? 0)
        highlightCheck.state = AppSettings.highlightCurrentLine ? .on : .off
        cursorPopup.selectItem(withTag: CursorShape.allCases.firstIndex(of: AppSettings.cursorShape) ?? 0)
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

    @objc private func tabWidthPicked(_ sender: NSPopUpButton) {
        AppSettings.tabWidth = sender.selectedTag()
    }

    @objc private func lineSpacingPicked(_ sender: NSPopUpButton) {
        AppSettings.lineSpacing = LineSpacing.allCases[sender.selectedTag()]
        sync()   // サンプルの行高が変わるわけではないが選択整合のため
    }

    @objc private func highlightChanged(_ sender: NSButton) {
        AppSettings.highlightCurrentLine = (sender.state == .on)
    }

    @objc private func cursorPicked(_ sender: NSPopUpButton) {
        AppSettings.cursorShape = CursorShape.allCases[sender.selectedTag()]
    }

    @objc private func wrapChanged(_ sender: NSButton) {
        AppSettings.lineWrap = (sender === wrapRadio)
        sync()
    }
}
