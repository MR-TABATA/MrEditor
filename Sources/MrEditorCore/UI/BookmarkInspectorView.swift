import AppKit

/// インスペクタの「しおり」タブビュー。
///
/// custom-draw を使わず、wantsLayer + AppKit 標準コントロールで構成する
/// （macOS の画面合成不具合を回避するため）。
final class BookmarkInspectorView: NSView {
    var onSelectLine: ((Int) -> Void)?
    var onRemoveLine: ((Int) -> Void)?

    private let scrollView = NSScrollView()
    private let listStack = NSStackView()
    private let emptyStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: L("inspector.bookmarks.empty"))
    private let emptyHint = NSTextField(labelWithString: L("inspector.bookmarks.emptyHint"))

    private var rows: [BookmarkRowView] = []

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

        // 空案内
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 8
        emptyStack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        emptyHint.font = NSFont.systemFont(ofSize: 11)
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.alignment = .center
        emptyHint.maximumNumberOfLines = 3
        emptyHint.cell?.wraps = true

        emptyStack.addArrangedSubview(emptyLabel)
        emptyStack.addArrangedSubview(emptyHint)
        addSubview(emptyStack)

        // スクロール可能な一覧
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let docView = FlippedView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(listStack)

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            listStack.topAnchor.constraint(equalTo: docView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor)
        ])

        updateEmptyState(isEmpty: true)
    }

    /// しおり一覧を更新する。
    /// - Parameter items: (0-based行番号, 行のプレビュー文字列) の配列
    func updateBookmarks(_ items: [(line: Int, text: String)]) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()

        updateEmptyState(isEmpty: items.isEmpty)
        guard !items.isEmpty else { return }

        for item in items {
            let row = BookmarkRowView(line: item.line, previewText: item.text)
            row.onSelect = { [weak self] line in self?.onSelectLine?(line) }
            row.onRemove = { [weak self] line in self?.onRemoveLine?(line) }
            rows.append(row)
            listStack.addArrangedSubview(row)
        }
        applyTheme()
    }

    private func updateEmptyState(isEmpty: Bool) {
        emptyStack.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }

    func applyTheme() {
        let theme = EditorTheme.current()
        emptyLabel.textColor = theme.chromeSecondaryText
        emptyHint.textColor = theme.chromeSecondaryText.withAlphaComponent(0.6)
        rows.forEach { $0.applyTheme(theme) }
    }
}

/// 上を原点とする NSView（NSScrollView の documentView 用）。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// しおりの 1 行。
private final class BookmarkRowView: NSView {
    let line: Int
    var onSelect: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?

    private let badge = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")
    private let removeBtn = NSButton()
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var currentTheme: EditorColorTheme?

    init(line: Int, previewText: String) {
        self.line = line
        super.init(frame: .zero)
        setup(previewText: previewText)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(previewText: String) {
        wantsLayer = true
        layer?.cornerRadius = 4

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

        // オレンジ色の行番号バッジ
        badge.stringValue = "L\(line + 1)"
        badge.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemOrange.cgColor
        badge.layer?.cornerRadius = 3
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)

        // プレビュー文字列（等幅フォント）
        let cleaned = previewText
            .replacingOccurrences(of: "\t", with: "    ")
            .trimmingCharacters(in: .newlines)
        preview.stringValue = cleaned.isEmpty ? "(空行)" : cleaned
        preview.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.lineBreakMode = .byTruncatingTail
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 解除ボタン（×）
        removeBtn.bezelStyle = .inline
        removeBtn.isBordered = false
        removeBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("inspector.bookmarks.remove"))
        removeBtn.imageScaling = .scaleProportionallyDown
        removeBtn.contentTintColor = .secondaryLabelColor
        removeBtn.target = self
        removeBtn.action = #selector(removeTapped)
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        removeBtn.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [badge, preview, removeBtn])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            badge.heightAnchor.constraint(equalToConstant: 18),
            removeBtn.widthAnchor.constraint(equalToConstant: 16),
            removeBtn.heightAnchor.constraint(equalToConstant: 16),

            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyTheme()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyTheme()
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) && !removeBtn.frame.contains(loc) {
            onSelect?(line)
        }
    }

    @objc private func removeTapped() {
        onRemove?(line)
    }

    func applyTheme(_ theme: EditorColorTheme? = nil) {
        let activeTheme = theme ?? currentTheme ?? EditorTheme.current()
        currentTheme = activeTheme
        layer?.backgroundColor = (isHovered ? activeTheme.chromeActiveBackground : .clear).cgColor
        preview.textColor = isHovered ? activeTheme.chromeActiveText : activeTheme.chromeText
        removeBtn.contentTintColor = isHovered ? activeTheme.chromeActiveText : activeTheme.chromeSecondaryText
    }
}
