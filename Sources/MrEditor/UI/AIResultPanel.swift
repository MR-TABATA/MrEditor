import AppKit

/// Escape でキャンセル（＝パネルを閉じる）を拾うための読み取り専用テキストビュー。
private final class AIResultTextView: NSTextView {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// ヘッダをつかんでパネル（ウィンドウ）を動かすためのドラッグ領域。`performDrag` に委ねるので、
/// 画面のどこへでも・アプリのウィンドウ外へも動かせる。ボタン上はボタンが先にイベントを取るので、
/// ここが反応するのはヘッダの余白部分だけ＝本文の選択やボタン操作を邪魔しない。
private final class DragHeaderView: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// 枠なしでもキーウィンドウになれるフローティングパネル（Escape をテキストビューに届けるため）。
final class AIPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// AI の単発解析（エラー原因推測）を出す、ビューア上に浮かぶ**常駐・移動可能**なツールパネル。
///
/// 出したら出しっぱなし（✕ / Esc で閉じる）。ヘッダをドラッグで移動。ヘッダの「解析」ボタンで、
/// そのとき選択している本文を都度解析する。本文（テーマ配色）から分離するため背景はすりガラス。
/// custom draw() は持たない（合成不具合回避）。
final class AIResultPanel: NSView {
    static let width: CGFloat = 480
    static let height: CGFloat = 300

    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let analyzeButton = NSButton()
    private let copyButton = NSButton()
    private let closeButton = NSButton()
    private let divider = NSBox()
    private let scroll = NSScrollView()
    private let textView = AIResultTextView()

    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onAnalyze: (() -> Void)?

    /// ストリーム表示中か（差分の追記を受け付ける状態）。
    private var isStreaming = false
    /// ストリームで本文がまだ 1 文字も来ていない（＝「問い合わせ中…」を出したまま）。
    private var streamIsEmpty = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // 影はウィンドウ（NSPanel.hasShadow）が落とすので、ここでは持たない。
        // すりガラス背景（角丸クリップ）。
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        // ヘッダ：✦ AI（アクセント）＋ 解析 ／ コピー ／ 閉じる。
        let spark = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
        spark.contentTintColor = .controlAccentColor
        spark.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.stringValue = L("ai.menu.title")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        analyzeButton.title = L("ai.panel.analyze")
        analyzeButton.bezelStyle = .rounded
        analyzeButton.controlSize = .small
        analyzeButton.font = .systemFont(ofSize: 11, weight: .medium)
        analyzeButton.keyEquivalent = "\r"   // パネルにフォーカスがあれば Return で解析
        analyzeButton.target = self
        analyzeButton.action = #selector(analyzeTapped)
        analyzeButton.setContentHuggingPriority(.required, for: .horizontal)

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("ai.panel.copy"))
        copyButton.toolTip = L("ai.panel.copy")
        styleIconButton(copyButton, action: #selector(copyTapped))
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("ai.panel.close"))
        closeButton.toolTip = L("ai.panel.close")
        styleIconButton(closeButton, action: #selector(closeTapped))

        let headerRow = NSStackView(views: [spark, titleLabel, spinner, analyzeButton, copyButton, closeButton])
        headerRow.orientation = .horizontal
        headerRow.spacing = 7
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let header = DragHeaderView()
        header.addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerRow.topAnchor.constraint(equalTo: header.topAnchor),
            headerRow.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        divider.boxType = .separator

        // 本文。
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.onCancel = { [weak self] in self?.onClose?() }
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true      // 必要なときだけ出す
        scroll.scrollerStyle = .overlay       // かぶせ式（幅を食わない・常時表示しない）
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let stack = NSStackView(views: [header, divider, scroll])
        stack.orientation = .vertical
        stack.spacing = 9
        stack.distribution = .fill
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 15, bottom: 13, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -27),
            divider.widthAnchor.constraint(equalTo: header.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: header.widthAnchor),
        ])
    }

    private func styleIconButton(_ b: NSButton, action: Selector) {
        b.isBordered = false
        b.bezelStyle = .smallSquare
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = .secondaryLabelColor
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
    }

    func applyTheme() {
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyTheme() }
    }

    // MARK: - 状態

    /// 問い合わせ中（スピナー＋「問い合わせ中…」）。コピーは伏せる。Escape 用にフォーカスを取る。
    func showThinking() {
        isStreaming = false
        spinner.startAnimation(nil)
        copyButton.isHidden = true
        setBody(L("ai.panel.thinking"), color: .secondaryLabelColor)
        window?.makeFirstResponder(textView)
    }

    /// ストリーム開始。最初の差分が来るまでは「問い合わせ中…」のまま待つ。
    func beginStreaming() {
        showThinking()
        isStreaming = true
        streamIsEmpty = true
    }

    /// 届いた差分を末尾へ足す。読むために上へスクロールしていたら、そこを動かさない。
    func appendStreamDelta(_ chunk: String) {
        guard isStreaming, !chunk.isEmpty else { return }
        if streamIsEmpty {                       // 「問い合わせ中…」を本文に置き換える
            setBody("", color: .labelColor)
            streamIsEmpty = false
        }
        let follow = isScrolledToBottom
        textView.textStorage?.append(NSAttributedString(string: chunk,
                                                        attributes: Self.bodyAttributes(color: .labelColor)))
        if follow { textView.scrollToEndOfDocument(nil) }
    }

    /// ストリーム正常終了。スピナーを止め、コピーを出す（本文はそのまま）。
    func finishStreaming() {
        isStreaming = false
        spinner.stopAnimation(nil)
        copyButton.isHidden = false
    }

    func showResult(_ text: String) {
        isStreaming = false
        spinner.stopAnimation(nil)
        copyButton.isHidden = false
        setBody(text, color: .labelColor)
        window?.makeFirstResponder(textView)
    }

    /// 失敗。ストリームの途中で落ちたときは、そこまでの本文を残して赤字を継ぎ足す
    /// （読めていた分を消さない）。
    func showError(_ message: String) {
        let hadPartialText = isStreaming && !streamIsEmpty
        isStreaming = false
        spinner.stopAnimation(nil)
        copyButton.isHidden = !hadPartialText
        if hadPartialText {
            textView.textStorage?.append(NSAttributedString(string: "\n\n" + message,
                                                            attributes: Self.bodyAttributes(color: .systemRed)))
            textView.scrollToEndOfDocument(nil)
        } else {
            setBody(message, color: .systemRed)
        }
        window?.makeFirstResponder(textView)
    }

    /// 選択が無いとき等の淡いヒント（赤ではない）。
    func showHint(_ text: String) {
        isStreaming = false
        spinner.stopAnimation(nil)
        copyButton.isHidden = true
        setBody(text, color: .secondaryLabelColor)
        window?.makeFirstResponder(textView)
    }

    /// 本文の見た目（読みやすい行間・段落間）。差分追記でも同じものを使う。
    private static func bodyAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8
        return [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    /// 本文を差し替える。
    private func setBody(_ text: String, color: NSColor) {
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: Self.bodyAttributes(color: color)))
        textView.scrollToBeginningOfDocument(nil)
    }

    /// いま末尾まで見えているか（＝差分に追随してよいか）。
    private var isScrolledToBottom: Bool {
        guard let document = scroll.documentView else { return true }
        let visible = scroll.contentView.documentVisibleRect
        return visible.maxY >= document.bounds.maxY - 4
    }

    var bodyText: String { textView.string }

    @objc private func analyzeTapped() { onAnalyze?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func closeTapped() { onClose?() }
}
