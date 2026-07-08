import AppKit

/// 構造化表示（CSV/TSV/NDJSON の桁揃え）が有効な間だけ本文左上に浮かべる帯。
///
/// 「これは表示だけの整形・読み取り専用・いつでも元に戻せる」ことを明示し、
/// 「縦棒付きで保存されてしまうのでは」という誤解を防ぐための安心材料。
final class StructuredBanner: NSView {
    /// 「元に戻す」を押したとき。
    var onRevert: (() -> Void)?

    static let height: CGFloat = 26

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.16).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.32).cgColor
        toolTip = L("structured.hint")

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let revert = NSButton(title: L("structured.revert"), target: self, action: #selector(revertTapped))
        revert.bezelStyle = .rounded
        revert.controlSize = .small
        revert.font = .systemFont(ofSize: 11)
        revert.translatesAutoresizingMaskIntoConstraints = false
        revert.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(icon); addSubview(label); addSubview(revert)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            revert.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            revert.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            revert.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// モード名（CSV/TSV/NDJSON）を反映する。
    func configure(mode: StructuredMode) {
        label.stringValue = L("structured.banner") + " · " + mode.rawValue.uppercased()
    }

    @objc private func revertTapped() { onRevert?() }
}
