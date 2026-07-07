import AppKit

/// 検索バー（ビューア右上に浮かぶ）。
///
/// custom draw() は持たない。背景・枠はレイヤで描く。
/// （custom draw を持つビューに子コントロールを同居させると、同一ウィンドウ内の
/// 別のカスタム描画ビューの合成が壊れる macOS の不具合を避けるため。[StatusBarView] 同様。）
final class SearchBarView: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 72   // 2 段（検索 / 置換）

    private let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")

    private let caseToggle = NSButton()
    private let regexToggle = NSButton()
    private let filterToggle = NSButton()

    private let replaceField = NSTextField()
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onClose: (() -> Void)?
    var onCaseToggle: ((Bool) -> Void)?
    var onRegexToggle: ((Bool) -> Void)?
    var onFilterToggle: ((Bool) -> Void)?
    var onReplace: ((String) -> Void)?
    var onReplaceAll: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        applyColors()

        field.placeholderString = L("search.placeholder")
        field.delegate = self
        field.target = self
        field.action = #selector(enterPressed)
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = false
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.isTransparent = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        // 大小区別トグル（Aa）
        caseToggle.title = "Aa"
        caseToggle.setButtonType(.pushOnPushOff)
        caseToggle.bezelStyle = .roundRect
        caseToggle.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        caseToggle.target = self
        caseToggle.action = #selector(caseTapped)
        caseToggle.toolTip = "大文字小文字を区別 / Case sensitive"
        caseToggle.setContentHuggingPriority(.required, for: .horizontal)

        // 正規表現トグル（.*）
        regexToggle.title = ".*"
        regexToggle.setButtonType(.pushOnPushOff)
        regexToggle.bezelStyle = .roundRect
        regexToggle.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        regexToggle.target = self
        regexToggle.action = #selector(regexTapped)
        regexToggle.toolTip = "正規表現 / Regular expression"
        regexToggle.setContentHuggingPriority(.required, for: .horizontal)

        // フィルタ表示トグル（漏斗）
        filterToggle.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
        filterToggle.setButtonType(.pushOnPushOff)
        filterToggle.bezelStyle = .roundRect
        filterToggle.imageScaling = .scaleProportionallyDown
        filterToggle.target = self
        filterToggle.action = #selector(filterTapped)
        filterToggle.toolTip = "一致行だけ表示 / Show matching lines only"
        filterToggle.setContentHuggingPriority(.required, for: .horizontal)

        let prev = iconButton("chevron.up", #selector(prevTapped))
        let next = iconButton("chevron.down", #selector(nextTapped))
        let close = iconButton("xmark", #selector(closeTapped))

        let findRow = NSStackView(views: [field, caseToggle, regexToggle, filterToggle, countLabel, prev, next, close])
        findRow.orientation = .horizontal
        findRow.spacing = 6

        // 置換の行。
        replaceField.placeholderString = L("search.replacePlaceholder")
        replaceField.font = field.font
        replaceField.target = self
        replaceField.action = #selector(replaceTapped)   // Enter で「置換」
        replaceButton.title = L("search.replace")
        replaceButton.bezelStyle = .rounded
        replaceButton.target = self
        replaceButton.action = #selector(replaceTapped)
        replaceButton.setContentHuggingPriority(.required, for: .horizontal)
        replaceAllButton.title = L("search.replaceAll")
        replaceAllButton.bezelStyle = .rounded
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllTapped)
        replaceAllButton.setContentHuggingPriority(.required, for: .horizontal)
        let replaceRow = NSStackView(views: [replaceField, replaceButton, replaceAllButton])
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 6

        let stack = NSStackView(views: [findRow, replaceRow])
        stack.orientation = .vertical
        stack.spacing = 7
        stack.alignment = .leading
        stack.distribution = .fillEqually
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            findRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -18),
            replaceRow.widthAnchor.constraint(equalTo: findRow.widthAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    private func iconButton(_ symbol: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let b = NSButton(image: img ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .smallSquare
        b.imageScaling = .scaleProportionallyDown
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func applyColors() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    // MARK: - 公開API

    var query: String { field.stringValue }

    func focusField() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func setCount(current: Int, total: Int, searching: Bool, progress: Int, invalid: Bool) {
        let fmt = { (n: Int) in NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
        if query.isEmpty {
            countLabel.stringValue = ""
        } else if invalid {
            countLabel.stringValue = L("search.invalid")
        } else if total == 0 {
            countLabel.stringValue = searching ? L("search.searching", progress) : L("search.none")
        } else if current == 0 {
            // まだ移動していない: 件数のみ（検索中なら継続表示）
            countLabel.stringValue = L("search.found", fmt(total))
        } else {
            countLabel.stringValue = L("search.count", fmt(current), fmt(total))
        }
    }

    // MARK: - イベント

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(field.stringValue)
    }

    @objc private func enterPressed() {
        // Shift+Enter で前へ。
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrev?() } else { onNext?() }
    }
    @objc private func nextTapped() { onNext?() }
    @objc private func prevTapped() { onPrev?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func caseTapped() { onCaseToggle?(caseToggle.state == .on) }
    @objc private func regexTapped() { onRegexToggle?(regexToggle.state == .on) }
    @objc private func filterTapped() { onFilterToggle?(filterToggle.state == .on) }
    @objc private func replaceTapped() { onReplace?(replaceField.stringValue) }
    @objc private func replaceAllTapped() { onReplaceAll?(replaceField.stringValue) }

    /// バーを閉じる時に状態をリセット。
    func clear() {
        field.stringValue = ""
        replaceField.stringValue = ""
        caseToggle.state = .off
        regexToggle.state = .off
        filterToggle.state = .off
        countLabel.stringValue = ""
    }

    /// Esc でバーを閉じる。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}
