import AppKit

/// 構造化表示（CSV/TSV/NDJSON の桁揃え）が有効な間だけ本文左上に浮かべる帯。
///
/// 「これは表示だけの整形・読み取り専用・いつでも元に戻せる」ことを明示し、
/// 「縦棒付きで保存されてしまうのでは」という誤解を防ぐための安心材料。
final class StructuredBanner: NSView {
    /// 「元に戻す」を押したとき。
    var onRevert: (() -> Void)?
    /// 「ビュープリセット…」を押したとき（B19/C9）。無料ビルドでも押せる（説明シートで止まる）。
    var onPresetTapped: (() -> Void)?

    static let height: CGFloat = 26

    private let label = NSTextField(labelWithString: "")
    private let presetButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        applyBackground()
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

        presetButton.title = L("structured.presetsButton")
        presetButton.bezelStyle = .rounded
        presetButton.controlSize = .small
        presetButton.font = .systemFont(ofSize: 11)
        presetButton.translatesAutoresizingMaskIntoConstraints = false
        presetButton.setContentHuggingPriority(.required, for: .horizontal)
        presetButton.target = self
        presetButton.action = #selector(presetTapped)

        addSubview(icon); addSubview(label); addSubview(presetButton); addSubview(revert)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            presetButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            presetButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            revert.leadingAnchor.constraint(equalTo: presetButton.trailingAnchor, constant: 8),
            revert.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            revert.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// モード名（CSV/TSV/NDJSON）を反映する。**プリセットボタンは fixedWidth では隠す**
    /// （並べ替え・B19が対象外のモードなので、保存して使い回す先も無い）。
    func configure(mode: StructuredMode) {
        label.stringValue = L("structured.banner") + " · " + mode.displayName
        presetButton.isHidden = (mode == .fixedWidth)
        applyBackground()   // テーマが変わっていることがある
    }

    /// 本文の上に浮かぶ帯なので、背景は**不透明**でなければならない。
    /// 半透明（alpha 0.16）にすると下の行が透けて帯の文字と重なり、両方読めなくなる。
    /// 見た目の淡さは保ちたいので、テーマの背景色にアクセント色を 16% 混ぜた不透明色を使う。
    private func applyBackground() {
        let base = EditorTheme.current().background
        let tinted = base.blended(withFraction: 0.16, of: .systemTeal) ?? base
        layer?.backgroundColor = tinted.withAlphaComponent(1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBackground() }
    }

    @objc private func revertTapped() { onRevert?() }
    @objc private func presetTapped() { onPresetTapped?() }
}
