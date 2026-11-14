import AppKit

/// 分析ペインの枠。**4 機能（集計・列の統計・時間分布・横断検索）が共有する 1 枚。**
///
/// 本文の下に差す（`MainWindowController.setAnalysisAccessory`）。行が見えたまま数を見られる
/// ことと、表から本文へ絞り込みで戻れることが、この位置にしている理由。
///
/// **custom draw() は持たない。** 同一ウィンドウ内に custom draw のビューが複数あると
/// macOS の合成が壊れる（1.11 で踏んだ）ので、背景と枠はレイヤだけで作る。
final class AnalysisPane: NSView {

    static let defaultHeight: CGFloat = 220

    /// 上端をつかんで高さを変えるときに呼ぶ（引数は新しい高さ）。
    var onResize: ((CGFloat) -> Void)?
    var onSelect: ((AnalysisFeature) -> Void)?
    var onRerun: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onExport: (() -> Void)?

    private let tabs = NSSegmentedControl()
    private let targetLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cancelButton = NSButton()
    private let rerunButton = NSButton()
    private let closeButton = NSButton()
    private let copyButton = NSButton()
    private let exportButton = NSButton()
    private let contentBox = NSView()
    private let resizeHandle = ResizeHandle()

    private var contentView: NSView?
    private let features = AnalysisFeature.menuOrder

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    // MARK: - 組み立て

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        tabs.segmentCount = features.count
        tabs.segmentStyle = .automatic
        tabs.trackingMode = .selectOne
        for (i, f) in features.enumerated() {
            tabs.setLabel(S.featureTab(f), forSegment: i)
            tabs.setWidth(0, forSegment: i)          // 0 ＝ 内容に合わせる
        }
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)

        targetLabel.font = .systemFont(ofSize: 11)
        targetLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail

        spinner.style = .bar
        spinner.isIndeterminate = false
        spinner.minValue = 0
        spinner.maxValue = 1
        spinner.isHidden = true
        spinner.controlSize = .small

        configure(cancelButton, symbol: "stop.fill", tip: S.cancel, action: #selector(cancelTapped))
        configure(rerunButton, symbol: "arrow.clockwise", tip: S.rerun, action: #selector(rerunTapped))
        configure(closeButton, symbol: "xmark", tip: S.close, action: #selector(closeTapped))
        configure(copyButton, symbol: "doc.on.doc", tip: S.copyTSV, action: #selector(copyTapped))
        configure(exportButton, symbol: "square.and.arrow.down", tip: S.exportCSV, action: #selector(exportTapped))
        cancelButton.isHidden = true

        let header = NSStackView(views: [tabs, targetLabel, NSView(), summaryLabel,
                                         spinner, cancelButton, copyButton, exportButton,
                                         rerunButton, closeButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        spinner.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        // 本文との境目。これが無いと本文の続きに見える。
        let topEdge = NSBox()
        topEdge.boxType = .separator

        for v in [topEdge, resizeHandle, header, divider, contentBox] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        resizeHandle.onDrag = { [weak self] dy in
            guard let self else { return }
            self.onResize?(self.frame.height + dy)
        }

        NSLayoutConstraint.activate([
            topEdge.topAnchor.constraint(equalTo: topAnchor),
            topEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
            topEdge.trailingAnchor.constraint(equalTo: trailingAnchor),

            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeHandle.heightAnchor.constraint(equalToConstant: 5),

            header.topAnchor.constraint(equalTo: resizeHandle.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),

            contentBox.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentBox.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.isBordered = false
        button.bezelStyle = .smallSquare
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = tip
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - 外から

    /// 上端の枠線（本文との境目）。区切りが無いと本文の続きに見える。
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    var selectedFeature: AnalysisFeature { features[max(0, tabs.selectedSegment)] }

    func select(_ feature: AnalysisFeature) {
        guard let i = features.firstIndex(of: feature) else { return }
        tabs.selectedSegment = i
    }

    /// 「対象: 全体 / フィルタ中の 12,345 行」。**何を数えたのかを常に見せる。**
    func setTarget(_ text: String) { targetLabel.stringValue = text }

    /// 完了後の 1 行（「8,642 万行 / 3.32 秒 / 3 種類」）。**丸めない。**
    func setSummary(_ text: String) { summaryLabel.stringValue = text }

    func setContent(_ view: NSView?) {
        contentView?.removeFromSuperview()
        contentView = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentBox.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
        ])
    }

    /// 走査中の見た目（進捗とキャンセルだけを出す）。
    func setRunning(_ running: Bool, progress: Double = 0) {
        spinner.isHidden = !running
        cancelButton.isHidden = !running
        rerunButton.isHidden = running
        spinner.doubleValue = progress
    }

    // MARK: - 操作

    @objc private func tabChanged() { onSelect?(selectedFeature) }
    @objc private func rerunTapped() { onRerun?() }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func exportTapped() { onExport?() }
}

/// 上端の掴みしろ。ドラッグでペインの高さを変える。
private final class ResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastY: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func mouseDown(with event: NSEvent) {
        lastY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        let y = event.locationInWindow.y
        // 上へ引くほど（y が増えるほど）ペインは高くなる。
        onDrag?(y - lastY)
        lastY = y
    }
}