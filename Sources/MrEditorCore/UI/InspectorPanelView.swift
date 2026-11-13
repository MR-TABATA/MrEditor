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

    enum Tab: Int {
        case bookmarks = 0
        case info = 1
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

        // ヘッダー（タブ切り替え: しおり / 情報）
        tabSegment.segmentCount = 2
        tabSegment.setLabel(L("inspector.tab.bookmarks"), forSegment: 0)
        tabSegment.setLabel(L("inspector.tab.info"), forSegment: 1)
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
