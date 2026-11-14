import AppKit

/// 構造化表示（CSV/TSV/NDJSON の桁揃え）が有効な間だけ本文左上に浮かべる帯。
///
/// 「これは表示だけの整形・読み取り専用・いつでも元に戻せる」ことを明示し、
/// 「縦棒付きで保存されてしまうのでは」という誤解を防ぐための安心材料。
final class StructuredBanner: NSView {
    /// 「元に戻す」を押したとき。
    var onRevert: (() -> Void)?
    /// 列数が合わない行へ「次へ / 前へ」（ラベルを押しても「次へ」）。
    var onMismatchNext: (() -> Void)?
    var onMismatchPrev: (() -> Void)?

    static let height: CGFloat = 26

    private let label = NSTextField(labelWithString: "")
    private let mismatchButton = NSButton(title: "", target: nil, action: nil)
    private let mismatchPrevButton = NSButton(title: "◀︎", target: nil, action: nil)
    private let mismatchNextButton = NSButton(title: "▶︎", target: nil, action: nil)
    private let revertButton = NSButton(title: "", target: nil, action: nil)

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

        revertButton.title = L("structured.revert")
        revertButton.bezelStyle = .rounded
        revertButton.controlSize = .small
        revertButton.font = .systemFont(ofSize: 11)
        revertButton.translatesAutoresizingMaskIntoConstraints = false
        revertButton.setContentHuggingPriority(.required, for: .horizontal)
        revertButton.target = self
        revertButton.action = #selector(revertTapped)

        setupMismatchControls()

        // 並びは 1 本の stack。隠した部品（不一致なし）の分は、自動で詰まる。
        let stack = NSStackView(views: [icon, label, mismatchButton, mismatchPrevButton, mismatchNextButton,
                                        revertButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.setCustomSpacing(6, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// 列数が合わない行の警告と ◀ ▶（初めは隠す）。
    private func setupMismatchControls() {
        // 列数が合わない行の警告。**本文を見ている目線のすぐ上**に出す（ステータスバーは気づきにくい）。
        mismatchButton.isBordered = false
        mismatchButton.font = .systemFont(ofSize: 11, weight: .semibold)
        mismatchButton.contentTintColor = .systemOrange
        mismatchButton.toolTip = L("structured.mismatchTip")
        mismatchButton.target = self
        mismatchButton.action = #selector(mismatchNextTapped)
        mismatchButton.setContentHuggingPriority(.required, for: .horizontal)
        for (button, tip, sel) in [(mismatchPrevButton, "structured.mismatchPrevTip", #selector(mismatchPrevTapped)),
                              (mismatchNextButton, "structured.mismatchNextTip", #selector(mismatchNextTapped))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10)
            button.toolTip = L(tip)
            button.target = self
            button.action = sel
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        mismatchButton.isHidden = true
        mismatchPrevButton.isHidden = true
        mismatchNextButton.isHidden = true
    }

    /// 列数が合わない行の件数。0 なら警告を出さない。
    func setMismatchCount(_ count: Int) {
        let show = count > 0
        mismatchButton.title = show ? L("structured.mismatch", count) : ""
        mismatchButton.isHidden = !show
        mismatchPrevButton.isHidden = !show
        mismatchNextButton.isHidden = !show
    }

    // 試験用の読み口。
    var mismatchVisibleForTesting: Bool { !mismatchButton.isHidden }
    var mismatchTextForTesting: String { mismatchButton.title }
    func tapNextForTesting() { mismatchNextTapped() }
    func tapPrevForTesting() { mismatchPrevTapped() }

    /// モード名（CSV/TSV/NDJSON）を反映する。
    func configure(mode: StructuredMode) {
        label.stringValue = L("structured.banner") + " · " + mode.displayName
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
    @objc private func mismatchNextTapped() { onMismatchNext?() }
    @objc private func mismatchPrevTapped() { onMismatchPrev?() }
}
