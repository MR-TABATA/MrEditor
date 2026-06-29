import AppKit

/// 開いているドキュメントの縦リスト。
///
/// このウィンドウでは custom-draw のサブツリーは最前面の1つしか画面合成されない
/// macOS の不具合がある（本文の DocumentView がその1つ）。そこでサイドバーは
/// custom-draw を使わず、layer 背景＋コントロール（NSTextField の行）で構成し、
/// contentView の最前面側に置く（StatusBar / SearchBar と同じ作り）。
final class SidebarView: NSView {
    var onSelect: ((Int) -> Void)?

    private let stack = NSStackView()
    private var rows: [SidebarRow] = []

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

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
        sep.backgroundColor = NSColor.separatorColor.cgColor
        layer?.addSublayer(sep)
        separator = sep
    }

    private var separator: CALayer?
    override func layout() {
        super.layout()
        separator?.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            separator?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    func reload(names: [String], active: Int) {
        rows.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows.removeAll()
        for (i, name) in names.enumerated() {
            let row = SidebarRow()
            row.index = i
            row.label.stringValue = name
            row.onClick = { [weak self] idx in self?.onSelect?(idx) }
            row.setActive(i == active)
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right).isActive = true
            rows.append(row)
        }
    }

    func setActive(_ index: Int) {
        for (i, r) in rows.enumerated() { r.setActive(i == index) }
    }
}

/// サイドバーの 1 行（layer 背景＋ラベル）。
final class SidebarRow: NSView {
    let label = NSTextField(labelWithString: "")
    var index = 0
    var onClick: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?(index) }

    func setActive(_ active: Bool) {
        layer?.backgroundColor = (active ? NSColor.selectedContentBackgroundColor : .clear).cgColor
        label.textColor = active ? .white : .labelColor
    }
}
