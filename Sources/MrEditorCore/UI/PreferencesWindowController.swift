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

        let ai = AIPaneViewController()
        ai.title = L("prefs.ai.tab")
        let aiItem = NSTabViewItem(viewController: ai)
        aiItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        tabs.addTabViewItem(aiItem)

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
    private var autoReloadCheck: NSButton!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 340))

        statusBarRadio = NSButton(radioButtonWithTitle: L("menu.saveProgress.statusBar"),
                                  target: self, action: #selector(radioChanged(_:)))
        sheetRadio = NSButton(radioButtonWithTitle: L("menu.saveProgress.sheet"),
                              target: self, action: #selector(radioChanged(_:)))

        let hint = NSTextField(wrappingLabelWithString: L("prefs.saveProgress.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        autoUpdateCheck = NSButton(checkboxWithTitle: L("prefs.autoUpdateCheck"),
                                   target: self, action: #selector(autoUpdateChanged(_:)))

        autoReloadCheck = NSButton(checkboxWithTitle: L("prefs.autoReload"),
                                   target: self, action: #selector(autoReloadChanged(_:)))
        let reloadHint = NSTextField(wrappingLabelWithString: L("prefs.autoReload.hint"))
        reloadHint.font = .systemFont(ofSize: 11)
        reloadHint.textColor = .secondaryLabelColor

        let sep = NSBox(); sep.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        let stack = makeStack([heading("prefs.saveProgress"), statusBarRadio, sheetRadio, hint,
                               sep,
                               heading("prefs.externalChanges"), autoReloadCheck, reloadHint,
                               sep2,
                               heading("prefs.updates"), autoUpdateCheck])
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        reloadHint.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        sep.widthAnchor.constraint(equalToConstant: 400).isActive = true
        sep2.widthAnchor.constraint(equalToConstant: 400).isActive = true
        pin(stack, in: root)
        self.view = root
        syncRadios()
        autoUpdateCheck.state = AppSettings.automaticUpdateChecks ? .on : .off
        autoReloadCheck.state = AppSettings.autoReloadExternalChanges ? .on : .off
    }

    @objc private func autoUpdateChanged(_ sender: NSButton) {
        AppSettings.automaticUpdateChecks = (sender.state == .on)
    }

    @objc private func autoReloadChanged(_ sender: NSButton) {
        AppSettings.autoReloadExternalChanges = (sender.state == .on)
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
    private var lineNumbersCheck: NSButton!
    private var invisiblesCheck: NSButton!
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

        // --- 現在行ハイライト・行番号・不可視文字 ---
        highlightCheck = NSButton(checkboxWithTitle: L("prefs.highlightCurrentLine"),
                                  target: self, action: #selector(highlightChanged(_:)))
        lineNumbersCheck = NSButton(checkboxWithTitle: L("prefs.showLineNumbers"),
                                    target: self, action: #selector(lineNumbersChanged(_:)))
        invisiblesCheck = NSButton(checkboxWithTitle: L("prefs.showInvisibles"),
                                   target: self, action: #selector(invisiblesChanged(_:)))

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
                               heading("prefs.text"), metricsRow, highlightCheck,
                               lineNumbersCheck, invisiblesCheck, cursorRow,
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
        lineNumbersCheck.state = AppSettings.showLineNumbers ? .on : .off
        invisiblesCheck.state = AppSettings.showInvisibles ? .on : .off
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

    @objc private func lineNumbersChanged(_ sender: NSButton) {
        AppSettings.showLineNumbers = (sender.state == .on)
    }

    @objc private func invisiblesChanged(_ sender: NSButton) {
        AppSettings.showInvisibles = (sender.state == .on)
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
    private var opacitySlider: NSSlider!
    private var opacityValue: NSTextField!
    private var ansiCheck: NSButton!
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

        // --- 背景の不透明度（ウィンドウ全体・iTerm 風） ---
        opacitySlider = NSSlider(value: Double(EditorTheme.backgroundOpacity * 100),
                                 minValue: 30, maxValue: 100,
                                 target: self, action: #selector(opacityChanged(_:)))
        opacitySlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        opacityValue = NSTextField(labelWithString: "")
        opacityValue.font = .systemFont(ofSize: 11)
        opacityValue.textColor = .secondaryLabelColor
        let opacityRow = NSStackView(views: [label("prefs.opacity"), opacitySlider, opacityValue])
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 8
        opacityRow.alignment = .centerY

        // --- ANSI カラー表示（閲覧時） ---
        ansiCheck = NSButton(checkboxWithTitle: L("prefs.ansi"), target: self, action: #selector(ansiToggled(_:)))

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

        let stack = makeStack([heading("prefs.theme"), themeRow, sample, opacityRow, ansiCheck, sep, customStack,
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
        let pct = Int((EditorTheme.backgroundOpacity * 100).rounded())
        opacitySlider.doubleValue = Double(pct)
        opacityValue.stringValue = "\(pct)%"
        ansiCheck.state = EditorTheme.ansiColorsEnabled ? .on : .off
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        EditorTheme.backgroundOpacity = CGFloat(sender.doubleValue) / 100
        opacityValue.stringValue = "\(Int(sender.doubleValue.rounded()))%"
    }

    @objc private func ansiToggled(_ sender: NSButton) {
        EditorTheme.ansiColorsEnabled = (sender.state == .on)
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

// MARK: - AI ペイン（BYOK：プロバイダ・モデル・キー・ベース URL）

private final class AIPaneViewController: NSViewController, NSTextFieldDelegate, NSComboBoxDelegate {
    private var providerPopup: NSPopUpButton!
    private var modelBox: NSComboBox!
    private var keyField: NSSecureTextField!
    private var baseURLField: NSTextField!
    private var testButton: NSButton!
    private var testResultLabel: NSTextField!
    /// 実行中の接続テスト（タブを離れる・やり直しで捨てる）。
    private var testStream: AIStreamHandle?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))

        providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, p) in AIProvider.allCases.enumerated() {
            providerPopup.addItem(withTitle: p.displayName)
            providerPopup.lastItem?.tag = i
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerPicked(_:))

        // モデルは**候補から選べて、打ち込みもできる**（一覧に無い ID・OpenAI 互換サーバの
        // 独自モデルも通す）。モデルは改名・引退するので、一覧で縛らない。
        modelBox = NSComboBox()
        modelBox.isEditable = true
        modelBox.completes = true
        modelBox.numberOfVisibleItems = 6
        modelBox.delegate = self

        keyField = NSSecureTextField(string: "")
        keyField.delegate = self
        baseURLField = NSTextField(string: "")
        baseURLField.placeholderString = L("prefs.ai.baseURLPlaceholder")
        baseURLField.delegate = self

        // 接続テスト：キー・モデル ID・ベース URL・受信までを本番と同じ経路で一往復。
        testButton = NSButton(title: L("prefs.ai.test"), target: self, action: #selector(testTapped))
        testButton.bezelStyle = .rounded
        testResultLabel = NSTextField(wrappingLabelWithString: "")
        testResultLabel.font = .systemFont(ofSize: 11)
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        let testRow = NSStackView(views: [testButton, testResultLabel])
        testRow.orientation = .horizontal
        testRow.spacing = 10
        testRow.alignment = .centerY

        let note = NSTextField(wrappingLabelWithString: L("prefs.ai.note"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        for f in [keyField, baseURLField] as [NSTextField] {
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        modelBox.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let stack = makeStack([heading("prefs.ai.tab"),
                               row("prefs.ai.provider", providerPopup),
                               row("prefs.ai.model", modelBox),
                               row("prefs.ai.apiKey", keyField),
                               row("prefs.ai.baseURL", baseURLField),
                               row("", testRow),
                               note])
        pin(stack, in: root)
        self.view = root
        sync()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        testStream?.cancel()          // タブ／ウィンドウを離れたら通信を残さない
        testStream = nil
    }

    private func row(_ key: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: L(key))
        label.setContentHuggingPriority(.required, for: .horizontal)
        // 110pt：「ベース URL（任意）」が切れない幅（90 だと日本語で切れていた）。
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        label.alignment = .right
        let r = NSStackView(views: [label, control])
        r.orientation = .horizontal
        r.spacing = 10
        r.alignment = .firstBaseline
        return r
    }

    private func sync() {
        let config = AppSettings.aiConfig
        providerPopup.selectItem(withTag: AIProvider.allCases.firstIndex(of: config.provider) ?? 0)
        reloadModelChoices(provider: config.provider)
        modelBox.stringValue = config.model
        baseURLField.stringValue = config.baseURLOverride
        keyField.stringValue = Keychain.get(account: config.provider.keychainAccount) ?? ""
        testResultLabel.stringValue = ""
    }

    private var currentProvider: AIProvider {
        AIProvider.allCases[providerPopup.selectedTag()]
    }

    /// 一覧の中身を作り直す（自分で確かめたモデルを先頭に、既定の候補を後ろに）。
    private func reloadModelChoices(provider: AIProvider) {
        modelBox.removeAllItems()
        modelBox.addItems(withObjectValues:
            provider.modelChoices(remembered: AppSettings.aiRememberedModels(for: provider)))
    }

    @objc private func providerPicked(_ sender: NSPopUpButton) {
        // プロバイダを切り替え、モデルは既定へ・候補一覧とキー欄もそのプロバイダのものへ。
        var config = AppSettings.aiConfig
        config.provider = currentProvider
        config.model = currentProvider.defaultModel
        AppSettings.aiConfig = config
        sync()
    }

    /// モデル・ベース URL は**入力のたびに**その場保存する。
    /// （編集確定＝フォーカスが外れる、を待つと「入力して即メニュー実行」で保存を取りこぼす。）
    func controlTextDidChange(_ obj: Notification) {
        persistTextFields()
    }

    /// 編集確定時は本文欄に加えてキーも Keychain へ（キーは毎打鍵で書かず確定時にまとめる）。
    func controlTextDidEndEditing(_ obj: Notification) {
        persistTextFields()
        Keychain.set(keyField.stringValue, account: currentProvider.keychainAccount)
    }

    /// 一覧からモデルを選んだとき（打鍵ではないので controlTextDidChange が来ない）。
    func comboBoxSelectionDidChange(_ notification: Notification) {
        // 選択が stringValue に反映されるのを待ってから拾う。
        DispatchQueue.main.async { [weak self] in self?.persistTextFields() }
    }

    private func persistTextFields() {
        var config = AppSettings.aiConfig
        config.provider = currentProvider
        let model = modelBox.stringValue.trimmingCharacters(in: .whitespaces)
        config.model = model.isEmpty ? currentProvider.defaultModel : model
        config.baseURLOverride = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)
        AppSettings.aiConfig = config
    }

    // MARK: - 接続テスト

    /// いまの設定で本番と同じ経路（ストリーミング）を一往復し、届くか・弾かれるかを見せる。
    /// 中身は見ない＝届いたこと自体が答え。失敗はプロバイダの文言をそのまま出す。
    @objc private func testTapped() {
        // 打ちかけの入力（キーは確定時にしか書かない）を先に確定させてから試す。
        persistTextFields()
        Keychain.set(keyField.stringValue, account: currentProvider.keychainAccount)

        testStream?.cancel()
        testButton.isEnabled = false
        testResultLabel.font = .systemFont(ofSize: 11)
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.stringValue = L("prefs.ai.testing")

        let model = AppSettings.aiConfig.model
        let provider = currentProvider
        testStream = AIClient.stream(AIPrompts.connectionTest(), onDelta: { _ in }) { [weak self] result in
            guard let self else { return }
            self.testStream = nil
            self.testButton.isEnabled = true
            switch result {
            case .success:
                // 通ったモデルは覚える＝一覧に無い ID も、次からは選ぶだけで済む。
                AppSettings.rememberAIModel(model, for: provider)
                self.reloadModelChoices(provider: provider)
                self.modelBox.stringValue = model
                self.testResultLabel.font = .systemFont(ofSize: 11, weight: .medium)
                self.testResultLabel.textColor = .systemGreen
                self.testResultLabel.stringValue = L("prefs.ai.testOK", model)
            case .failure(let err):
                self.showTestFailure(err.errorDescription ?? "\(err)")
            }
        }
    }

    /// 失敗の見せ方：**1 行目＝システムの言語**（何が起きたか）を赤で目立たせ、
    /// プロバイダの原文（英語）は手がかりとして下に小さく添える。
    /// 原文を消すと調べようがなくなり、同じ大きさで並べると日本語が埋もれる。
    private func showTestFailure(_ text: String) {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let out = NSMutableAttributedString(string: L("prefs.ai.testNG", parts[0]), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.systemRed,
        ])
        if parts.count > 1, !parts[1].isEmpty {
            out.append(NSAttributedString(string: "\n" + parts[1], attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        testResultLabel.attributedStringValue = out
    }
}
