import AppKit

/// 下部ステータスバー。文字コード・行数・ファイルサイズ・索引進捗を表示する。
final class StatusBarView: NSView {
    static let height: CGFloat = 24

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// 上端の区切り線（draw() を使わずサブレイヤで描く）。
    private let separator = CALayer()

    private func setup() {
        // 背景・区切り線は custom draw() を使わずレイヤで描く。
        // custom draw() を持つビューが子コントロールを抱えると、
        // 同一ウィンドウ内の別のカスタム描画ビュー(LargeFileViewer/DocumentView)の
        // 画面合成が壊れる macOS の不具合を避けるため。
        wantsLayer = true
        layer?.addSublayer(separator)

        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        applyTheme()
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setPlaceholder()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // 上端 1px の区切り線。
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // cgColor はアピアランス変化に追従しないため明示的に再設定する。
        effectiveAppearance.performAsCurrentDrawingAppearance { applyTheme() }
    }

    /// 配色（テーマ）を背景・区切り線・ラベルへ適用する。
    func applyTheme() {
        let theme = EditorTheme.current()
        layer?.backgroundColor = theme.chromeBackground.cgColor
        separator.backgroundColor = theme.separator.cgColor
        label.textColor = theme.chromeSecondaryText
    }

    func setPlaceholder() {
        guard !isShowingMessage else { return }
        label.stringValue = L("status.placeholder")
    }

    /// 一時メッセージ（保存中 N% など）を表示する。解除まで `update`/`setPlaceholder` を無視する。
    private var isShowingMessage = false
    private var onCancel: (() -> Void)?
    private lazy var cancelButton: NSButton = {
        let b = NSButton(title: L("common.cancel"), target: self, action: #selector(cancelTapped))
        b.bezelStyle = .inline
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.isHidden = true
        b.translatesAutoresizingMaskIntoConstraints = false
        addSubview(b)
        NSLayoutConstraint.activate([
            b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            b.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return b
    }()

    func showMessage(_ text: String) {
        isShowingMessage = true
        label.stringValue = text
    }

    /// 保存中メッセージをキャンセルボタン付きで表示する（進捗モード A）。
    func showSaving(_ text: String, onCancel: @escaping () -> Void) {
        isShowingMessage = true
        label.stringValue = text
        self.onCancel = onCancel
        cancelButton.isHidden = false
    }
    /// 保存中メッセージのテキストだけ更新する。
    func updateSaving(_ text: String) {
        guard isShowingMessage else { return }
        label.stringValue = text
    }
    @objc private func cancelTapped() { onCancel?() }

    /// 一時メッセージを解除する（次の `update` で通常表示に戻る）。
    func clearMessage() {
        isShowingMessage = false
        onCancel = nil
        cancelButton.isHidden = true
    }

    func update(_ state: ViewerState) {
        guard !isShowingMessage else { return }
        let size = Self.formatBytes(state.fileSize)
        let lines = Self.formatNumber(state.lineCount)
        let lineLabel = state.lineCountIsExact ? L("status.lines", lines) : L("status.linesApprox", lines)
        var text = "\(state.encodingName)    \(lineLabel)    \(size)"
        if !state.lineCountIsExact {
            let pct = Int(state.indexProgress * 100)
            text += "    " + L("status.indexing", pct)
        }
        label.stringValue = text
    }

    private static func formatNumber(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var i = 0
        while value >= 1024 && i < units.count - 1 {
            value /= 1024
            i += 1
        }
        if i == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[i])
    }
}
