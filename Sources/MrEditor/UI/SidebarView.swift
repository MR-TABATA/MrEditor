import AppKit

/// 開いているドキュメントの縦リスト。
///
/// このウィンドウでは custom-draw のサブツリーは最前面の1つしか画面合成されない
/// macOS の不具合がある（本文の DocumentView がその1つ）。そこでサイドバーは
/// custom-draw を使わず、layer 背景＋コントロール（NSTextField の行）で構成し、
/// contentView の最前面側に置く（StatusBar / SearchBar と同じ作り）。
final class SidebarView: NSView {
    var onSelect: ((Int) -> Void)?
    /// 行の × でそのドキュメントを閉じる要求。
    var onClose: ((Int) -> Void)?

    private let stack = NSStackView()
    private var rows: [SidebarRow] = []

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // 右端の区切り線（サブレイヤ）
        let sep = CALayer()
        layer?.addSublayer(sep)
        separator = sep
        applyTheme()
    }

    private var separator: CALayer?
    override func layout() {
        super.layout()
        separator?.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyTheme() }
    }

    /// 配色（テーマ）を背景・区切り線・各行へ適用する。
    func applyTheme() {
        let theme = EditorTheme.current()
        layer?.backgroundColor = theme.chromeBackground.cgColor
        separator?.backgroundColor = theme.separator.cgColor
        rows.forEach { $0.applyTheme(theme) }
    }

    func reload(names: [String], dirty: [Bool], active: Int) {
        rows.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows.removeAll()
        for (i, name) in names.enumerated() {
            let row = SidebarRow()
            row.index = i
            row.label.stringValue = name
            row.onClick = { [weak self] idx in self?.onSelect?(idx) }
            row.onClose = { [weak self] idx in self?.onClose?(idx) }
            row.setActive(i == active)
            row.setDirty(i < dirty.count ? dirty[i] : false)
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right).isActive = true
            rows.append(row)
        }
    }

    func setActive(_ index: Int) {
        for (i, r) in rows.enumerated() { r.setActive(i == index) }
    }

    /// 指定行の未保存表示を更新する（編集/保存のたびに呼ぶ。行を作り直さない）。
    func setDirty(_ index: Int, _ dirty: Bool) {
        guard index >= 0, index < rows.count else { return }
        rows[index].setDirty(dirty)
    }
}

/// サイドバーの 1 行（layer 背景＋未保存ドット＋ラベル＋閉じるボタン）。
final class SidebarRow: NSView {
    let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    /// 未保存インジケータ（左端の小さな●。保存済みでは非表示）。
    private let dirtyDot = NSView()
    var index = 0
    var onClick: ((Int) -> Void)?
    /// × ボタンでこの行を閉じる要求。
    var onClose: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 3
        dirtyDot.isHidden = true
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dirtyDot)

        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.setButtonType(.momentaryChange)
        closeButton.toolTip = L("sidebar.close")
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            // 左端に未保存ドット用の固定コラム（保存済み/未で名前の左位置がズレないよう常に確保）。
            dirtyDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dirtyDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dirtyDot.widthAnchor.constraint(equalToConstant: 6),
            dirtyDot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dirtyDot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?(index) }
    @objc private func closeTapped() { onClose?(index) }

    private var isActive = false
    private var isDirty = false
    private var theme = EditorTheme.current()

    func setActive(_ active: Bool) {
        isActive = active
        restyle()
    }

    /// 未保存状態を反映する（●表示＋×アイコンの塗り分け）。
    func setDirty(_ dirty: Bool) {
        isDirty = dirty
        restyle()
    }

    /// テーマ変更時に色を差し替える（選択・未保存状態は保持）。
    func applyTheme(_ theme: EditorColorTheme) {
        self.theme = theme
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = (isActive ? theme.chromeActiveBackground : .clear).cgColor
        // 名前は可読性優先で通常色のまま。未保存は●と×をアクセント色にして色分けする。
        label.textColor = isActive ? theme.chromeActiveText : theme.chromeText
        dirtyDot.isHidden = !isDirty
        dirtyDot.layer?.backgroundColor = theme.dirtyIndicator.cgColor
        closeButton.image = NSImage(
            systemSymbolName: isDirty ? "xmark.circle.fill" : "xmark.circle",
            accessibilityDescription: L("sidebar.close"))
        closeButton.contentTintColor = isDirty ? theme.dirtyIndicator
                                               : (isActive ? theme.chromeActiveText : theme.chromeSecondaryText)
    }
}
