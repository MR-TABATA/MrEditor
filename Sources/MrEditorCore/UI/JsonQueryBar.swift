import AppKit

/// JSON その場クエリのバー（ビューア上部に出す 1 段）。式を入力すると結果で表示を置き換える。
///
/// `SearchBarView` と同じく **custom draw() は持たない**（背景・枠はレイヤ）。同一ウィンドウ内の
/// 別のカスタム描画ビューの合成が壊れる macOS の不具合を避けるため。
final class JsonQueryBar: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 40

    private let field = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    /// 式が変わるたび（live）。
    var onQueryChange: ((String) -> Void)?
    /// バーを閉じる（✕ / Esc）。
    var onClose: (() -> Void)?

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

        let prompt = NSTextField(labelWithString: "query:")
        prompt.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        prompt.setContentHuggingPriority(.required, for: .horizontal)

        field.placeholderString = L("jsonquery.placeholder")
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.delegate = self
        field.target = self
        field.action = #selector(enterPressed)
        field.bezelStyle = .roundedBezel

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.bezelStyle = .smallSquare
        close.imageScaling = .scaleProportionallyDown
        close.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [prompt, field, statusLabel, close])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
    }

    private func applyColors() {
        let theme = EditorTheme.current()
        layer?.backgroundColor = theme.chromeBackground.cgColor
        layer?.borderColor = theme.separator.cgColor
        statusLabel.textColor = theme.chromeSecondaryText
    }
    func applyTheme() { applyColors() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    // MARK: - 公開 API

    var query: String { field.stringValue }

    func focusField() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// エラー表示（赤）／通常表示（クリア）を切り替える。
    func setStatus(error: String?) {
        if let error {
            statusLabel.stringValue = error
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue = ""
            statusLabel.textColor = EditorTheme.current().chromeSecondaryText
        }
    }

    func clear() {
        field.stringValue = ""
        setStatus(error: nil)
    }

    // MARK: - イベント

    func controlTextDidChange(_ obj: Notification) { onQueryChange?(field.stringValue) }
    @objc private func enterPressed() { onQueryChange?(field.stringValue) }
    @objc private func closeTapped() { onClose?() }

    /// Esc でバーを閉じる。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        return false
    }
}
