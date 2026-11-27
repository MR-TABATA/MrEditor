import AppKit

/// 「呼び出し元（git など）が、このタブを閉じるのを待っています」を知らせる小さな帯。
///
/// `mreditor --wait` で開いたタブにだけ出す。**⌘S では呼び出し元に戻らない**（何度も保存しながら
/// 編集するため）ので、これが無いと、保存したのに端末が戻らず、固まったと思われる。
/// 知らせるだけで、ボタンは持たない。
final class WaitingBanner: NSView {

    static let height: CGFloat = 26

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
        applyBackground()
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.30).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: L("wait.banner"))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
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
}
