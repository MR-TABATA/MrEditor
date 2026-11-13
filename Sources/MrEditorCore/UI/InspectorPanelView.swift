import AppKit

/// MrEditor の右サイドパネル（インスペクタ）。
///
/// custom-draw を使わず、wantsLayer + AppKit 標準コントロールで構成する
/// （macOS の画面合成不具合を回避するため）。
final class InspectorPanelView: NSView {
    /// 左端ドラッグによる幅変更要求（ドラッグ中）。
    var onResize: ((CGFloat) -> Void)?
    /// 幅変更の確定（ドラッグ終了時・永続化用）。
    var onResizeEnd: ((CGFloat) -> Void)?
    /// 左端ダブルクリックによる幅のリセット要求。
    var onResetWidth: (() -> Void)?

    let bookmarkView = BookmarkInspectorView()
    let infoView = DocumentInfoInspectorView()

    private let resizeHandleWidth: CGFloat = 6
    private var isResizing = false
    private var dragOffsetFromLeadingEdge: CGFloat = 0

    private var separator: CALayer?
    private let tabSegment = NSSegmentedControl()
    private let contentContainer = NSView()
    private let summaryPlaceholder = NSView()

    enum Tab: Int {
        case bookmarks = 0
        case info = 1
        case summary = 2
    }

    private(set) var currentTab: Tab = .bookmarks

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

        // 左端の区切り線（サブレイヤ）
        let sep = CALayer()
        layer?.addSublayer(sep)
        separator = sep

        // ヘッダー（タブ切り替え）
        tabSegment.segmentCount = 3
        tabSegment.setLabel(L("inspector.tab.bookmarks"), forSegment: 0)
        tabSegment.setLabel(L("inspector.tab.info"), forSegment: 1)
        tabSegment.setLabel(L("inspector.tab.summary"), forSegment: 2)
        tabSegment.selectedSegment = 0
        tabSegment.target = self
        tabSegment.action = #selector(tabChanged)
        tabSegment.translatesAutoresizingMaskIntoConstraints = false
        tabSegment.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(tabSegment)

        // コンテンツ領域
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        // 各子ビューの初期設定
        bookmarkView.translatesAutoresizingMaskIntoConstraints = false
        infoView.translatesAutoresizingMaskIntoConstraints = false
        setupSummaryPlaceholder()

        NSLayoutConstraint.activate([
            tabSegment.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            tabSegment.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabSegment.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tabSegment.heightAnchor.constraint(equalToConstant: 24),

            contentContainer.topAnchor.constraint(equalTo: tabSegment.bottomAnchor, constant: 8),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        showTab(.bookmarks)
        applyTheme()
    }

    private func setupSummaryPlaceholder() {
        summaryPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        refreshSummaryState()
    }

    private var hasAPIKeyConfigured: Bool {
        let config = AppSettings.aiConfig
        if !config.provider.requiresAPIKey { return true }
        if let key = Keychain.get(account: config.provider.keychainAccount),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    /// 要約タブの内容を API キー設定状態に合わせて更新する。
    func refreshSummaryState() {
        summaryPlaceholder.subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        if hasAPIKeyConfigured {
            let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .systemPurple
            icon.translatesAutoresizingMaskIntoConstraints = false

            let hint = NSTextField(labelWithString: L("inspector.summary.placeholder"))
            hint.font = NSFont.systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.alignment = .center
            hint.maximumNumberOfLines = 3
            hint.cell?.wraps = true

            let btn = NSButton(title: L("inspector.summary.button"), target: nil, action: nil)
            btn.bezelStyle = .rounded
            btn.isEnabled = false // Phase 2 で有効化

            stack.addArrangedSubview(icon)
            stack.addArrangedSubview(hint)
            stack.addArrangedSubview(btn)

            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 28),
                icon.heightAnchor.constraint(equalToConstant: 28),
            ])
        } else {
            let icon = NSImageView(image: NSImage(systemSymbolName: "key.slash", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .systemOrange
            icon.translatesAutoresizingMaskIntoConstraints = false

            let title = NSTextField(labelWithString: L("inspector.summary.noKeyTitle"))
            title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            title.textColor = .labelColor
            title.alignment = .center

            let msg = NSTextField(labelWithString: L("inspector.summary.noKeyMessage"))
            msg.font = NSFont.systemFont(ofSize: 11)
            msg.textColor = .secondaryLabelColor
            msg.alignment = .center
            msg.maximumNumberOfLines = 4
            msg.cell?.wraps = true

            let btn = NSButton(title: L("inspector.summary.openSettings"), target: self, action: #selector(openPreferencesTapped))
            btn.bezelStyle = .rounded

            stack.addArrangedSubview(icon)
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(msg)
            stack.addArrangedSubview(btn)

            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 28),
                icon.heightAnchor.constraint(equalToConstant: 28),
            ])
        }

        summaryPlaceholder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: summaryPlaceholder.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: summaryPlaceholder.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: summaryPlaceholder.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: summaryPlaceholder.trailingAnchor, constant: -16),
        ])
    }

    @objc private func openPreferencesTapped() {
        NSApp.sendAction(Selector(("openPreferences:")), to: nil, from: nil)
    }

    @objc private func tabChanged() {
        guard let tab = Tab(rawValue: tabSegment.selectedSegment) else { return }
        showTab(tab)
    }

    func showTab(_ tab: Tab) {
        currentTab = tab
        tabSegment.selectedSegment = tab.rawValue
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        let targetView: NSView
        switch tab {
        case .bookmarks:
            targetView = bookmarkView
        case .info:
            targetView = infoView
        case .summary:
            refreshSummaryState()
            targetView = summaryPlaceholder
        }

        contentContainer.addSubview(targetView)
        NSLayoutConstraint.activate([
            targetView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            targetView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            targetView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            targetView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    // MARK: - リサイズハンドル（左端）

    func isNearLeftEdge(_ point: NSPoint) -> Bool {
        point.x >= 0 && point.x <= resizeHandleWidth
    }

    override func layout() {
        super.layout()
        separator?.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = NSRect(x: 0, y: 0, width: resizeHandleWidth, height: bounds.height)
        addCursorRect(rect, cursor: .resizeLeftRight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isNearLeftEdge(point) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if isNearLeftEdge(loc) {
            if event.clickCount == 2 {
                onResetWidth?()
                return
            }
            isResizing = true
            dragOffsetFromLeadingEdge = loc.x
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isResizing {
            let parentView = superview ?? self
            let locInParent = parentView.convert(event.locationInWindow, from: nil)
            let newWidth = (frame.maxX - locInParent.x) + dragOffsetFromLeadingEdge
            onResize?(newWidth)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            isResizing = false
            onResizeEnd?(bounds.width)
            return
        }
        super.mouseUp(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyTheme() }
    }

    func applyTheme() {
        let theme = EditorTheme.current()
        layer?.backgroundColor = EditorTheme.withBackgroundOpacity(theme.chromeBackground).cgColor
        separator?.backgroundColor = theme.separator.cgColor
        bookmarkView.applyTheme()
        infoView.applyTheme()
    }
}
