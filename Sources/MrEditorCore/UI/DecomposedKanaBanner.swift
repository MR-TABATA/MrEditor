import AppKit

/// 「貼り付けた文字列に、分離した濁点・半濁点があります」を知らせる小さな帯。**知らせるだけで、本文は書き換えない。**
///
/// PDF のテキストや Mac のファイル名（NFD）を貼ると、「が」が「か」＋濁点の 2 文字で入る。Mac 上では
/// 見た目も検索結果も同じで気づけないので、貼った直後に知らせる。直すのは、書式メニューの変換（本人の操作）。
///
/// 本文領域の**下端の右側**に浮かべる（左側は外部変更バナーが使う）。× で閉じる。本文の分離した濁点が
/// 0 件になったとき（直したとき）は、`MainWindowController` が自動で消す。
final class DecomposedKanaBanner: NSView {
    /// × を押したとき。
    var onClose: (() -> Void)?

    static let height: CGFloat = 26

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// 件数を入れて表示する。
    func show(count: Int) {
        label.stringValue = L("dakuten.banner", String(count))
        isHidden = false
    }

    private func setup() {
        wantsLayer = true
        applyBackground()
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.30).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "textformat.abc", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        // 窓が狭いときは、文面を切って収める（帯が本文領域からはみ出さない）。
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let close = NSButton()
        close.translatesAutoresizingMaskIntoConstraints = false
        close.isBordered = false
        close.bezelStyle = .inline
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("common.cancel"))
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)

        addSubview(icon)
        addSubview(label)
        addSubview(close)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 14),
            close.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    /// 本文の上に浮かぶ帯なので背景は**不透明**にする（半透明だと下の行が透けて読めない）。
    private func applyBackground() {
        let base = EditorTheme.current().background
        let tinted = base.blended(withFraction: 0.16, of: .systemBlue) ?? base
        layer?.backgroundColor = tinted.withAlphaComponent(1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBackground() }
    }

    @objc private func closeTapped() { onClose?() }
}
