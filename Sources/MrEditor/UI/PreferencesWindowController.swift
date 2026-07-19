import AppKit

/// 環境設定ウィンドウ（⌘,）。macOS 標準のツールバータブ構成。
/// 「一般」＝保存中の表示、「表示」＝フォント＋本文体裁＋長い行、「配色」＝本文エリアのテーマ。
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

        let colors = ColorsPaneViewController()
        colors.title = L("prefs.colors")
        let colorsItem = NSTabViewItem(viewController: colors)
        colorsItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        tabs.addTabViewItem(colorsItem)

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
    private var autoUpdateCheck: NSButton!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))

        statusBarRadio = NSButton(radioButtonWithTitle: L("menu.saveProgress.statusBar"),
                                  target: self, action: #selector(radioChanged(_:)))
        sheetRadio = NSButton(radioButtonWithTitle: L("menu.saveProgress.sheet"),
                              target: self, action: #selector(radioChanged(_:)))

        let hint = NSTextField(wrappingLabelWithString: L("prefs.saveProgress.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        autoUpdateCheck = NSButton(checkboxWithTitle: L("prefs.autoUpdateCheck"),
                                   target: self, action: #selector(autoUpdateChanged(_:)))

        let sep = NSBox(); sep.boxType = .separator

        let stack = makeStack([heading("prefs.saveProgress"), statusBarRadio, sheetRadio, hint,
                               sep,
                               heading("prefs.updates"), autoUpdateCheck])
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        sep.widthAnchor.constraint(equalToConstant: 400).isActive = true
        pin(stack, in: root)
        self.view = root
        syncRadios()
        autoUpdateCheck.state = AppSettings.automaticUpdateChecks ? .on : .off
    }

    @objc private func autoUpdateChanged(_ sender: NSButton) {
        AppSettings.automaticUpdateChecks = (sender.state == .on)
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

// MARK: - 配色ペイン（本文エリアのテーマ）

private final class ColorsPaneViewController: NSViewController {
    private var themePopup: NSPopUpButton!
    private var sample: NSTextField!
    /// custom 時のみ表示する 5 色の個別ピッカー行をまとめた領域。
    private var customStack: NSStackView!
    private var wells: [EditorTheme.ColorKey: NSColorWell] = [:]
    /// 共有操作の結果を一言だけ添える（コピー完了・適用完了）。
    private var shareStatus: NSTextField!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 380))

        // --- テーマ選択 ---
        themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, p) in ThemePreset.allCases.enumerated() {
            themePopup.addItem(withTitle: L("prefs.theme.\(p.rawValue)"))
            themePopup.lastItem?.tag = i
        }
        themePopup.target = self
        themePopup.action = #selector(themePicked(_:))
        let themeRow = NSStackView(views: [label("prefs.theme"), themePopup])
        themeRow.orientation = .horizontal
        themeRow.spacing = 8
        themeRow.alignment = .firstBaseline

        // --- ライブサンプル（前景/背景色を反映して見せる） ---
        sample = NSTextField(labelWithString: "AaBbYy 0123 ()=>{} 日本語ログ")
        sample.drawsBackground = true
        sample.isBezeled = true
        sample.lineBreakMode = .byTruncatingTail
        sample.font = EditorFont.current()

        // --- custom 用の 5 色ピッカー ---
        var rows: [NSView] = []
        for key in EditorTheme.ColorKey.allCases {
            let well = NSColorWell()
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
            well.target = self
            well.action = #selector(colorPicked(_:))
            well.tag = EditorTheme.ColorKey.allCases.firstIndex(of: key)!
            wells[key] = well
            let row = NSStackView(views: [well, label("prefs.color.\(key.rawValue)")])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            rows.append(row)
        }
        customStack = NSStackView(views: rows)
        customStack.orientation = .vertical
        customStack.alignment = .leading
        customStack.spacing = 8

        let sep = NSBox(); sep.boxType = .separator
        sep.widthAnchor.constraint(equalToConstant: 400).isActive = true

        // --- 共有（書き出し／読み込み／リンク） ---
        let sep2 = NSBox(); sep2.boxType = .separator
        sep2.widthAnchor.constraint(equalToConstant: 400).isActive = true

        let shareHint = NSTextField(wrappingLabelWithString: L("prefs.share.hint"))
        shareHint.font = .systemFont(ofSize: 11)
        shareHint.textColor = .secondaryLabelColor
        shareHint.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true

        let exportBtn = NSButton(title: L("prefs.share.export"), target: self, action: #selector(exportSettings(_:)))
        let importBtn = NSButton(title: L("prefs.share.import"), target: self, action: #selector(importSettings(_:)))
        let copyBtn = NSButton(title: L("prefs.share.copyLink"), target: self, action: #selector(copyLink(_:)))
        let fromClipBtn = NSButton(title: L("prefs.share.importClipboard"), target: self, action: #selector(importFromClipboard(_:)))
        let shareRow = NSStackView(views: [exportBtn, importBtn, copyBtn, fromClipBtn])
        shareRow.orientation = .horizontal
        shareRow.spacing = 8

        shareStatus = NSTextField(labelWithString: "")
        shareStatus.font = .systemFont(ofSize: 11)
        shareStatus.textColor = .secondaryLabelColor

        let stack = makeStack([heading("prefs.theme"), themeRow, sample, sep, customStack,
                               sep2, heading("prefs.share"), shareHint, shareRow, shareStatus])
        sample.widthAnchor.constraint(equalToConstant: 400).isActive = true
        pin(stack, in: root)
        self.view = root
        sync()
    }

    private func label(_ key: String) -> NSTextField { NSTextField(labelWithString: L(key)) }

    private func sync() {
        let idx = ThemePreset.allCases.firstIndex(of: EditorTheme.preset) ?? 0
        themePopup.selectItem(withTag: idx)
        let theme = EditorTheme.current()
        // サンプルへ配色を反映。
        sample.textColor = theme.foreground
        sample.backgroundColor = theme.background
        // ピッカーは custom 時のみ表示。各 well へ現在色を反映。
        customStack.isHidden = (EditorTheme.preset != .custom)
        for key in EditorTheme.ColorKey.allCases {
            wells[key]?.color = EditorTheme.customColor(key)
        }
    }

    @objc private func themePicked(_ sender: NSPopUpButton) {
        EditorTheme.preset = ThemePreset.allCases[sender.selectedTag()]
        sync()
    }

    @objc private func colorPicked(_ sender: NSColorWell) {
        let key = EditorTheme.ColorKey.allCases[sender.tag]
        EditorTheme.setCustomColor(key, sender.color)   // preset を .custom に切替＆通知
        shareStatus.stringValue = ""
        sync()
    }

    // MARK: - 共有

    @objc private func exportSettings(_ sender: Any?) {
        shareStatus.stringValue = ""
        SettingsShare.export(presenting: view.window)
    }

    @objc private func importSettings(_ sender: Any?) {
        shareStatus.stringValue = ""
        SettingsShare.importFromFile(presenting: view.window) { [weak self] in self?.applied() }
    }

    @objc private func copyLink(_ sender: Any?) {
        SettingsShare.copyShareLink()
        shareStatus.stringValue = L("prefs.share.copied")
    }

    @objc private func importFromClipboard(_ sender: Any?) {
        shareStatus.stringValue = ""
        SettingsShare.importFromClipboard(presenting: view.window) { [weak self] in self?.applied() }
    }

    /// 適用後：ポップアップ／ピッカーを新しい値へ同期し、一言添える。
    private func applied() {
        sync()
        shareStatus.stringValue = L("prefs.share.imported")
    }
}
