import AppKit

/// 小ファイル用の編集ペイン。ファイル全体をメモリに読み込み、`NSTextView` で
/// 編集する（アンドゥ・IME・選択・標準コピーは AppKit 標準機能に委ねる）。
///
/// 大ファイルは `LargeFileViewer`（mmap + スパース索引・読み取り専用）が担う。
/// 振り分けの閾値は `EditableViewer.sizeThreshold`。
final class EditableViewer: NSView, DocumentPane, NSTextViewDelegate {
    /// この閾値以下のファイルを編集ペインで開く（超過は読み取り専用ビューア）。
    static let sizeThreshold = 8 * 1024 * 1024

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    private(set) var fileURL: URL?
    private var encoding: DetectedEncoding = .utf8
    private var byteSize = 0

    /// 未保存の変更があるか。
    private(set) var isDirty = false
    /// 変更状態が変わったときの通知（タイトルバーの edited 表示用）。
    var onDirtyChange: ((Bool) -> Void)?

    var onStateChange: ((ViewerState) -> Void)?
    var onSearchState: ((Int, Int, Bool, Int, Bool) -> Void)?   // 編集ペインでは未使用
    var onDropFiles: (([URL]) -> Void)?

    // 編集ペインは検索バー／末尾追従を出さない。
    var supportsSearch: Bool { false }
    var supportsFollow: Bool { false }
    var canEdit: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = EditorFont.current()
        textView.textContainerInset = NSSize(width: 4, height: 6)

        // 横スクロールせず、テキストコンテナの幅をビューに追従させる（ワードラップ）。
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self

        scrollView.documentView = textView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var isFlipped: Bool { true }

    // MARK: - ファイルを開く

    @discardableResult
    func open(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            NSSound.beep()
            return false
        }
        let detected = EncodingDetector.detect(data.prefix(64 * 1024))
        // 検出エンコードでデコード。失敗時は UTF-8 置換デコードへフォールバック。
        let text: String
        if let s = String(data: data, encoding: detected.stringEncoding) {
            text = s
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        self.fileURL = url
        self.encoding = detected
        self.byteSize = data.count
        textView.string = text
        textView.undoManager?.removeAllActions()   // 読み込みはアンドゥ対象にしない
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        setDirty(false)
        emitState()
        return true
    }

    /// 空の新規ドキュメントとして初期化する（パス未確定。保存時に確定する）。
    func newDocument() {
        fileURL = nil
        encoding = .utf8
        byteSize = 0
        textView.string = ""
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        setDirty(false)
        emitState()
    }

    // MARK: - 保存

    /// 変更状態を更新し、変化があれば通知する。
    private func setDirty(_ value: Bool) {
        guard value != isDirty else { return }
        isDirty = value
        onDirtyChange?(value)
    }

    /// 既存パスへ保存（パスが無ければ saveAs）。成功で true。
    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        return write(to: url)
    }

    /// 保存先を選んで保存（NSSavePanel）。成功で true。
    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        if let url = fileURL {
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    /// 現在のテキストを検出エンコードで原子的に書き出す。
    /// 検出エンコードで表現できない文字が増えていれば UTF-8 にフォールバックする。
    private func write(to url: URL) -> Bool {
        let s = textView.string
        var enc = encoding
        var data = s.data(using: enc.stringEncoding)
        if data == nil {
            let original = enc.displayName
            enc = .utf8
            data = s.data(using: .utf8)
            let a = NSAlert()
            a.messageText = L("save.encodingFallback", original)
            a.runModal()
        }
        guard let data else { NSSound.beep(); return false }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        encoding = enc
        fileURL = url
        byteSize = data.count
        setDirty(false)
        emitState()
        return true
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        setDirty(true)
        emitState()   // 行数・状態を更新
    }

    // MARK: - DocumentPane

    func reEmitState() { emitState() }

    func focusContent() {
        window?.makeFirstResponder(textView)
    }

    func applyCurrentFontSize() {
        textView.font = EditorFont.current()
    }

    private func emitState() {
        let state = ViewerState(
            encodingName: encoding.displayName,
            lineCount: lineCount(of: textView.string),
            lineCountIsExact: true,
            fileSize: byteSize,
            indexProgress: 1.0
        )
        onStateChange?(state)
    }

    /// 行数（末尾に改行がなければその行も 1 行として数える）。空文字列は 0 行。
    private func lineCount(of s: String) -> Int {
        if s.isEmpty { return 0 }
        var count = 0
        for ch in s where ch == "\n" { count += 1 }
        return s.hasSuffix("\n") ? count : count + 1
    }
}
