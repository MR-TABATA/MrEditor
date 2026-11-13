import AppKit

/// ドキュメントのメタデータを表す値型。
struct DocumentInfo {
    var fileName: String
    var path: String?
    var fileSize: Int64?
    var lineCount: Int
    var encodingName: String
    var lineEndingName: String
    var fontName: String
    var creationDate: Date?
    var modificationDate: Date?
    var generatorApp: String?
    var formatName: String
    var isReadOnly: Bool
    var isDirty: Bool

    /// 人間に読みやすいファイルサイズ表記（例: "1.2 MB (1,234,567 バイト)"）。
    var formattedSize: String {
        guard let size = fileSize else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        let readable = formatter.string(fromByteCount: size)

        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        let bytesStr = numberFormatter.string(from: NSNumber(value: size)) ?? "\(size)"
        return "\(readable) (\(bytesStr) B)"
    }

    /// 人間に読みやすい総行数表記（例: "12,345 行"）。
    var formattedLineCount: String {
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        let linesStr = numberFormatter.string(from: NSNumber(value: lineCount)) ?? "\(lineCount)"
        return "\(linesStr) 行"
    }

    /// 作成日時の表記（例: "2026/10/07 14:34"）。
    var formattedCreationDate: String {
        guard let date = creationDate else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    /// 更新日時の表記（例: "2026/10/07 14:34"）。
    var formattedModificationDate: String {
        guard let date = modificationDate else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    /// 状態の表記（例: "編集可能" / "読み取り専用（未保存の変更あり）"）。
    var formattedStatus: String {
        let base = isReadOnly ? L("inspector.info.status.readOnly") : L("inspector.info.status.writable")
        return isDirty ? "\(base) \(L("inspector.info.status.dirty"))" : base
    }
}

/// インスペクタの「情報」タブビュー。
///
/// custom-draw を使わず、wantsLayer + AppKit 標準コントロールで構成する。
final class DocumentInfoInspectorView: NSView {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()

    private var currentPath: String?
    private let copyToast = NSTextField(labelWithString: "")
    private var toastTimer: Timer?

    private var propertyViews: [InfoPropertyRowView] = []

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

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let docView = FlippedView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(stack)

        addSubview(scrollView)

        // コピー完了トースト表示
        copyToast.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        copyToast.textColor = .white
        copyToast.alignment = .center
        copyToast.wantsLayer = true
        copyToast.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        copyToast.layer?.cornerRadius = 10
        copyToast.alphaValue = 0
        copyToast.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyToast)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            stack.topAnchor.constraint(equalTo: docView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),

            copyToast.centerXAnchor.constraint(equalTo: centerXAnchor),
            copyToast.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            copyToast.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            copyToast.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    func updateInfo(_ info: DocumentInfo?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        propertyViews.removeAll()
        currentPath = info?.path

        guard let info else { return }

        // 各項目の行を作成
        addRow(label: L("inspector.info.fileName"), value: info.fileName)

        if let path = info.path {
            let row = InfoPropertyRowView(label: L("inspector.info.path"), value: path, canCopy: true) { [weak self] in
                self?.copyPathToClipboard(path)
            }
            propertyViews.append(row)
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12).isActive = true
        } else {
            addRow(label: L("inspector.info.path"), value: "—")
        }

        addRow(label: L("inspector.info.size"), value: info.formattedSize)
        addRow(label: L("inspector.info.lines"), value: info.formattedLineCount)
        addRow(label: L("inspector.info.encoding"), value: info.encodingName)
        addRow(label: L("inspector.info.lineEnding"), value: info.lineEndingName)
        addRow(label: L("inspector.info.font"), value: info.fontName)
        addRow(label: L("inspector.info.created"), value: info.formattedCreationDate)
        addRow(label: L("inspector.info.modified"), value: info.formattedModificationDate)
        addRow(label: L("inspector.info.generator"), value: info.generatorApp ?? "—")
        addRow(label: L("inspector.info.format"), value: info.formatName)
        addRow(label: L("inspector.info.status"), value: info.formattedStatus)

        applyTheme()
    }

    private func addRow(label: String, value: String) {
        let row = InfoPropertyRowView(label: label, value: value)
        propertyViews.append(row)
        stack.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12).isActive = true
        row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12).isActive = true
    }

    private func copyPathToClipboard(_ path: String) {
        NSPasteboard.general.clearContents()
        let success = NSPasteboard.general.setString(path, forType: .string)
        if success {
            showToast(L("inspector.info.pathCopied"))
        }
    }

    private func showToast(_ text: String) {
        toastTimer?.invalidate()
        copyToast.stringValue = "  \(text)  "
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            copyToast.animator().alphaValue = 1
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.copyToast.animator().alphaValue = 0
            }
        }
    }

    func applyTheme() {
        propertyViews.forEach { $0.applyTheme() }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// プロパティの 1 行（ラベルと値）。
private final class InfoPropertyRowView: NSView {
    private let labelField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private var copyBtn: NSButton?
    private var onCopy: (() -> Void)?

    init(label: String, value: String, canCopy: Bool = false, onCopy: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.onCopy = onCopy
        setup(label: label, value: value, canCopy: canCopy)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(label: String, value: String, canCopy: Bool) {
        translatesAutoresizingMaskIntoConstraints = false

        labelField.stringValue = label
        labelField.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        labelField.textColor = .secondaryLabelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false

        valueField.stringValue = value
        valueField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        valueField.textColor = .labelColor
        valueField.lineBreakMode = .byTruncatingMiddle
        valueField.cell?.wraps = false
        valueField.toolTip = value
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topStack = NSStackView(views: [labelField])
        topStack.orientation = .horizontal
        topStack.alignment = .centerY
        topStack.translatesAutoresizingMaskIntoConstraints = false

        if canCopy {
            let btn = NSButton()
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            btn.imageScaling = .scaleProportionallyDown
            btn.contentTintColor = .secondaryLabelColor
            btn.target = self
            btn.action = #selector(copyTapped)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.setContentHuggingPriority(.required, for: .horizontal)
            topStack.addArrangedSubview(btn)
            self.copyBtn = btn
        }

        let mainStack = NSStackView(views: [topStack, valueField])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 2
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor),
            valueField.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor),
            valueField.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor),

            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func copyTapped() {
        onCopy?()
    }

    func applyTheme() {
        let theme = EditorTheme.current()
        let isSystemAppearance = theme.appearanceName != nil
        let secColor = isSystemAppearance ? .secondaryLabelColor : theme.foreground.withAlphaComponent(0.6)
        labelField.textColor = secColor
        valueField.textColor = isSystemAppearance ? .labelColor : theme.foreground
        copyBtn?.contentTintColor = secColor
    }
}
