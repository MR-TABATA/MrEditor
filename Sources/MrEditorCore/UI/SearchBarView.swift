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
    /// 前後 N 行（`grep -C`）。**アイコンでなく文字と数字**にしてある——
    /// 絞り込んだ画面に「±2」と出ていれば何が起きているか読めるが、記号だけだと気づかれない。
    private let contextLabel = NSTextField(labelWithString: "±")
    private let contextField = NSTextField()

    private let replaceField = NSTextField()
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()
    private let preserveCaseToggle = NSButton()

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onClose: (() -> Void)?
    var onCaseToggle: ((Bool) -> Void)?
    var onRegexToggle: ((Bool) -> Void)?
    var onFilterToggle: ((Bool) -> Void)?
    /// 漏斗が**使えないペインに移ったせいで**降りたとき。本人が消したのとは別物で、
    /// 次に使えるペインへ戻ったら元に戻す（意図は消えていない）。
    var onFilterUnavailable: (() -> Void)?
    var onContextChange: ((Int) -> Void)?
    var onReplace: ((String) -> Void)?
    var onReplaceAll: ((String) -> Void)?
    var onPreserveCaseToggle: ((Bool) -> Void)?

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
        regexToggle.toolTip = "正規表現（先読み・後読み対応） / Regular expression (lookahead/lookbehind)"
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

        // 前後 N 行（grep -C）。絞り込みの隣に置く＝絞り込んだ人の目に入る位置。
        contextLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        contextLabel.setContentHuggingPriority(.required, for: .horizontal)
        contextField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        contextField.alignment = .right
        contextField.placeholderString = "0"
        contextField.target = self
        contextField.action = #selector(contextEdited)   // Enter・フォーカスを外したとき
        contextField.toolTip = "一致行の前後も出す（grep -C） / Also show N lines around each match"
        contextField.setContentHuggingPriority(.required, for: .horizontal)

        let prev = iconButton("chevron.up", #selector(prevTapped))
        let next = iconButton("chevron.down", #selector(nextTapped))
        let close = iconButton("xmark", #selector(closeTapped))

        // 件数（「18 件中 1 件目」）も縮めさせない。末尾が切れると何件目か読めない。
        keepIntrinsicWidth([caseToggle, regexToggle, filterToggle, contextLabel, countLabel,
                            preserveCaseToggle, replaceButton, replaceAllButton])

        let findRow = NSStackView(views: [field, caseToggle, regexToggle, filterToggle,
                                          contextLabel, contextField, countLabel, prev, next, close])
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

        // ケース維持トグル（Aa→aA）。大小区別なしで拾った一致の綴りを置換文字列へ引き継ぐ。
        preserveCaseToggle.title = "aA"
        preserveCaseToggle.setButtonType(.pushOnPushOff)
        preserveCaseToggle.bezelStyle = .roundRect
        preserveCaseToggle.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        preserveCaseToggle.target = self
        preserveCaseToggle.action = #selector(preserveCaseTapped)
        preserveCaseToggle.toolTip = "元の大文字小文字を維持して置換 / Preserve case when replacing"
        preserveCaseToggle.setContentHuggingPriority(.required, for: .horizontal)

        let replaceRow = NSStackView(views: [replaceField, preserveCaseToggle, replaceButton, replaceAllButton])
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
            // 詰まったときに縮むのは検索欄（打った語は自分で覚えているが、
            // 件数やトグルは読めなくなると困る）。
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            contextField.widthAnchor.constraint(equalToConstant: 30),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    /// 文字のトグル（Aa / .*）は縮めさせない。詰まると「…」に化けて何のボタンか読めなくなる
    /// （±N の欄を足したときに実際そうなった）。狭いときに縮むのは検索欄の側でよい。
    private func keepIntrinsicWidth(_ views: [NSView]) {
        for v in views {
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            v.setContentHuggingPriority(.required, for: .horizontal)
        }
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
        let theme = EditorTheme.current()
        layer?.backgroundColor = EditorTheme.withBackgroundOpacity(theme.chromeBackground).cgColor
        layer?.borderColor = theme.separator.cgColor
        countLabel.textColor = theme.chromeSecondaryText
        syncContextEnabled()   // 「±」の色は使える／使えないで変わる
    }
    /// 配色（テーマ）を検索パネルへ適用する（内部の検索フィールド・ボタンは窓アピアランスに追従）。
    func applyTheme() { applyColors() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    // MARK: - 公開API

    var query: String { field.stringValue }

    /// フィルタ（一致行だけ表示）を使えないペインでは漏斗ボタンを隠す。
    func setFilterAvailable(_ available: Bool) {
        if !available, filterToggle.state == .on {
            filterToggle.state = .off
            onFilterUnavailable?()
        }
        filterToggle.isHidden = !available
        contextLabel.isHidden = !available
        contextField.isHidden = !available
        syncContextEnabled()
    }

    /// 前後 N 行の欄は**絞り込んでいる間だけ**触れる（絞っていないときは前後も何もない）。
    private func syncContextEnabled() {
        let on = !filterToggle.isHidden && filterToggle.state == .on
        contextField.isEnabled = on
        contextLabel.textColor = on ? EditorTheme.current().chromeText
                                    : EditorTheme.current().chromeSecondaryText
    }

    /// 前後 N 行を外から立てる（メニューの増減・ペインを切り替えたとき）。
    func setContextLines(_ n: Int) {
        contextField.stringValue = n > 0 ? String(n) : ""
        syncContextEnabled()
    }

    /// 置換できないペイン（構造化表示中・一致行だけ表示中）では置換の行を触れなくする。
    /// 隠さずに落とすのは、バーの高さが固定で行を消すと隙間が空くため。
    func setReplaceAvailable(_ available: Bool) {
        replaceField.isEnabled = available
        preserveCaseToggle.isEnabled = available
        replaceButton.isEnabled = available
        replaceAllButton.isEnabled = available
    }

    /// 漏斗ボタンの状態を外から立てる（ツールバーの「フィルタ」から開いたとき用）。
    /// 押下イベントを伴わないので、本文側の反映は呼び出し元が行う。
    func setFilterOn(_ on: Bool) {
        guard !filterToggle.isHidden else { return }
        filterToggle.state = on ? .on : .off
        syncContextEnabled()
    }

    func focusField() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// 外から検索条件を丸ごと立てる（分析ペインの表から「この値で絞る」を押したとき）。
    /// **本文側の反映は呼び出し元が行う**（`setFilterOn` と同じ約束）。
    func setQuery(_ text: String, regex: Bool, caseSensitive: Bool, filter: Bool) {
        field.stringValue = text
        regexToggle.state = regex ? .on : .off
        caseToggle.state = caseSensitive ? .on : .off
        setFilterOn(filter)
    }

    /// `capped` が真なら総数は上限で打ち切った下限＝「N 件以上」と出す。
    /// 打ち切った数をそのまま「N 件」と言うと、実際より少ない数を断言してしまう。
    func setCount(current: Int, total: Int, searching: Bool, progress: Int,
                  invalid: Bool, capped: Bool = false) {
        let fmt = { (n: Int) in NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
        if query.isEmpty {
            countLabel.stringValue = ""
        } else if invalid {
            countLabel.stringValue = L("search.invalid")
        } else if total == 0 {
            countLabel.stringValue = searching ? L("search.searching", progress) : L("search.none")
        } else if current == 0 {
            // まだ移動していない: 件数のみ（検索中なら継続表示）
            countLabel.stringValue = capped ? L("search.foundCapped", fmt(total))
                                            : L("search.found", fmt(total))
        } else {
            countLabel.stringValue = capped ? L("search.countCapped", fmt(current), fmt(total))
                                            : L("search.count", fmt(current), fmt(total))
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
    @objc private func filterTapped() {
        syncContextEnabled()
        onFilterToggle?(filterToggle.state == .on)
    }
    @objc private func contextEdited() {
        let n = min(max(0, Int(contextField.stringValue) ?? 0), FilterContext.maxContext)
        contextField.stringValue = n > 0 ? String(n) : ""   // 入力を丸めた結果を見せる
        onContextChange?(n)
    }
    @objc private func preserveCaseTapped() { onPreserveCaseToggle?(preserveCaseToggle.state == .on) }
    @objc private func replaceTapped() { onReplace?(replaceField.stringValue) }
    @objc private func replaceAllTapped() { onReplaceAll?(replaceField.stringValue) }

    /// バーを閉じる時に状態をリセット。
    func clear() {
        field.stringValue = ""
        replaceField.stringValue = ""
        caseToggle.state = .off
        regexToggle.state = .off
        filterToggle.state = .off
        preserveCaseToggle.state = .off
        countLabel.stringValue = ""
        // 前後 N 行は消さない（アプリの設定として覚えている値なので、閉じるたびに 0 へ戻さない）。
        syncContextEnabled()
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
