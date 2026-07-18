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
    private let textView = EditorTextView()
    private let jsonQueryBar = JsonQueryBar()
    /// クエリバー表示/非表示で本文の上端を切り替える（片方だけ有効化）。
    private var scrollTopToContainer: NSLayoutConstraint!
    private var scrollTopToBar: NSLayoutConstraint!

    private(set) var fileURL: URL?
    private var encoding: DetectedEncoding = .utf8
    /// ファイルの改行コード。保存時に全文をこれへ揃える（NSTextView は改行を LF で挿入するため）。
    private var lineEnding: LineEnding = .lf
    private var byteSize = 0

    /// 未保存の変更があるか。
    private(set) var isDirty = false
    /// 変更状態が変わったときの通知（タイトルバーの edited 表示用）。
    var onDirtyChange: ((Bool) -> Void)?

    // MARK: - 未保存の本文の保護（DraftStore）
    //
    // 未保存の新規ドキュメントの本文は、ユーザーがまだどこにも保存していない唯一の写し。
    // 終了時にまとめて書くのでは、クラッシュ・強制終了・電源断で消える。打鍵のたびに
    // （デバウンスして）draft ファイルへ書き、落ちても直前まで残るようにする。

    /// この draft を保存するストア（テストでは一時ディレクトリのものを差し込む）。
    var draftStore: DraftStore = .shared
    /// 未保存の新規ドキュメントの本文が入る draft の id。保存済みファイルでは nil。
    private(set) var draftID: String?
    /// 打鍵のたびに書かず、この間隔だけ落ち着いてから書く。
    private var draftSaveTimer: Timer?
    private static let draftDebounce: TimeInterval = 1.0

    var onStateChange: ((ViewerState) -> Void)?
    var onSearchState: ((Int, Int, Bool, Int, Bool) -> Void)?   // 編集ペインでは未使用
    var onDropFiles: (([URL]) -> Void)?

    // 編集ペインは検索バー／末尾追従を出さない。
    var supportsSearch: Bool { false }
    var supportsFollow: Bool { false }
    var canEdit: Bool { structuredFormatter == nil && !jsonPrettyActive && !jsonQueryActive }   // 整形/クエリ中は読み取り専用

    // MARK: - 構造化表示（読み取り専用の整形ビュー）
    private var structuredFormatter: TabularFormatter?
    /// JSON 整形（単一ドキュメントの字下げ）が有効か。CSV/TSV/NDJSON と違い列指向でないため別フラグ。
    private var jsonPrettyActive = false
    /// JSON クエリ窓が有効か（結果を読み取り専用で表示中）。
    private var jsonQueryActive = false
    /// 構造化 ON 前の本文（OFF で復元）。
    private var preStructuredText: String?
    var supportsStructured: Bool { true }
    var supportsJsonReformat: Bool { true }   // 全文を保持する小ファイルペインなので単一 JSON 整形が可能
    var structuredMode: StructuredMode? { jsonPrettyActive ? .json : structuredFormatter?.mode }

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
        applyParagraphStyle()

        // 横スクロールせず、テキストコンテナの幅をビューに追従させる（ワードラップ）。
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        applyColors()

        scrollView.documentView = textView
        addSubview(scrollView)

        jsonQueryBar.translatesAutoresizingMaskIntoConstraints = false
        jsonQueryBar.isHidden = true
        jsonQueryBar.onQueryChange = { [weak self] q in self?.runJsonQuery(q) }
        jsonQueryBar.onClose = { [weak self] in self?.closeJsonQuery() }
        addSubview(jsonQueryBar)

        // クエリバー非表示時は本文が上端まで、表示時はバーの下から。
        scrollTopToContainer = scrollView.topAnchor.constraint(equalTo: topAnchor)
        scrollTopToBar = scrollView.topAnchor.constraint(equalTo: jsonQueryBar.bottomAnchor)
        NSLayoutConstraint.activate([
            jsonQueryBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            jsonQueryBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            jsonQueryBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            jsonQueryBar.heightAnchor.constraint(equalToConstant: JsonQueryBar.height),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollTopToContainer,
        ])
    }

    override var isFlipped: Bool { true }

    // MARK: - ファイルを開く

    @discardableResult
    func open(url: URL) -> Bool { open(url: url, forcedEncoding: nil) }

    var currentEncoding: DetectedEncoding { encoding }
    var currentSaveEncoding: DetectedEncoding { encoding }

    /// 現在のファイルを指定エンコードで開き直す（自動判定ミスの文字化けを直す）。編集は破棄される。
    @discardableResult
    func reopen(withEncoding enc: DetectedEncoding) -> Bool {
        guard let url = fileURL else { return false }
        return open(url: url, forcedEncoding: enc)
    }

    /// `forcedEncoding` を渡すと自動判定を上書きしてそのエンコードでデコードする。
    @discardableResult
    func open(url: URL, forcedEncoding: DetectedEncoding?) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            NSSound.beep()
            return false
        }
        let prefix = data.prefix(64 * 1024)
        let detected = forcedEncoding ?? EncodingDetector.detect(prefix)
        // 検出エンコードでデコード。失敗時は UTF-8 置換デコードへフォールバック。
        let text: String
        if let s = String(data: data, encoding: detected.stringEncoding) {
            text = s
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        self.fileURL = url
        self.draftID = nil          // 実ファイルを開いたペインは draft を持たない
        self.encoding = detected
        self.lineEnding = LineEnding.detect(Data(prefix), encoding: detected)
        self.byteSize = data.count
        resetStructuredPresentation()
        textView.string = text
        applyParagraphStyle()                       // タブ幅・行間を本文全体へ
        textView.undoManager?.removeAllActions()   // 読み込みはアンドゥ対象にしない
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        setDirty(false)
        emitState()
        return true
    }

    /// セッション復元用の本文（構造化中は元の論理本文）。保存済み・未保存を問わず現在の中身。
    var restorableText: String? { logicalText }

    // MARK: - 印刷（プリントダイアログの「PDF ▸ PDF として保存」で PDF 出力も兼ねる）

    var canPrint: Bool { true }

    /// 表示中の本文を印刷する。改ページ・行の分割は NSTextView に委ねる。
    /// 構造化表示中は整形後の見た目をそのまま刷る（画面と一致させる）。
    func printDocument() {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        // ヘッダ/フッタの余白ぶんを確保しつつ、行が切れないよう幅は用紙に合わせる。
        info.topMargin = 36; info.bottomMargin = 36
        info.leftMargin = 36; info.rightMargin = 36

        let op = NSPrintOperation(view: textView, printInfo: info)
        op.jobTitle = fileURL?.lastPathComponent ?? L("doc.untitled")
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        if let win = window {
            op.runModal(for: win, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }

    // MARK: - draft（未保存の本文）の読み書き

    /// 打鍵から少し待って draft を書く（連続入力のたびにディスクを叩かない）。
    private func scheduleDraftSave() {
        guard fileURL == nil, draftID != nil else { return }   // 保存済みファイルは draft を持たない
        draftSaveTimer?.invalidate()
        draftSaveTimer = Timer.scheduledTimer(withTimeInterval: Self.draftDebounce, repeats: false) { [weak self] _ in
            self?.flushDraft()
        }
    }

    /// 溜めている本文を今すぐ draft へ書き出す（終了直前・非アクティブ化時にも呼ばれる）。
    func flushDraft() {
        draftSaveTimer?.invalidate()
        draftSaveTimer = nil
        guard fileURL == nil, let id = draftID else { return }
        draftStore.write(id: id, text: logicalText)
    }

    /// draft を捨てる。**ユーザーがドキュメントを閉じた（破棄した）ときだけ呼ぶ。**
    /// 保存済みファイルのペインでは何も起きない（draftID が無い）。
    func discardDraft() {
        draftSaveTimer?.invalidate()
        draftSaveTimer = nil
        guard let id = draftID else { return }
        draftStore.discard(id)
        draftID = nil
    }

    /// draft から未保存の新規ドキュメントを復元する（本文はディスクの draft ファイルが持つ）。
    func restoreDraft(id: String, text: String, dirty: Bool) {
        draftID = id
        restoreUntitled(text: text, dirty: dirty)
    }

    /// 前回終了時の未保存の新規ドキュメントを本文つきで復元する（パスは未確定のまま）。
    func restoreUntitled(text: String, dirty: Bool) {
        fileURL = nil
        encoding = .utf8
        lineEnding = .lf
        byteSize = text.utf8.count
        resetStructuredPresentation()
        textView.string = text
        applyParagraphStyle()
        textView.undoManager?.removeAllActions()   // 復元はアンドゥ対象にしない
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        setDirty(dirty)
        emitState()
    }

    /// 空の新規ドキュメントとして初期化する（パス未確定。保存時に確定する）。
    /// この時点で draft の id を振る（本文が空のうちはファイルを作らない）。
    func newDocument() {
        draftID = DraftStore.newID()
        fileURL = nil
        encoding = .utf8
        lineEnding = .lf
        byteSize = 0
        resetStructuredPresentation()
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

    /// 保存時のエンコードを設定する（まだ書き出さない。dirty にして次の保存で反映）。
    /// 小ファイルは文字列を保持しているため、保存エンコード＝バッファのエンコードで区別は不要。
    func setSaveEncoding(_ enc: DetectedEncoding) {
        guard enc != encoding else { return }
        encoding = enc          // ⌘S で write() がこのエンコードへ再符号化して書き出す
        setDirty(true)
        emitState()
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

    /// 保存・行数計算に使う論理テキスト。構造化表示中は整形後の見た目ではなく元の本文を返す
    /// （整形は表示だけの変換であり、CSV/JSON の中身を壊さないため）。
    private var logicalText: String { preStructuredText ?? textView.string }

    /// 現在のテキストを検出エンコードで原子的に書き出す。
    /// 検出エンコードで表現できない文字が増えていれば UTF-8 にフォールバックする。
    private func write(to url: URL) -> Bool {
        // NSTextView は改行を LF で挿入するため、保存時に全文をファイルの EOL へ揃える。
        let s = lineEnding.normalize(logicalText)
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
        // 本文が実ファイルになった。draft はもう要らない（消してよい 2 経路のうちの 1 つ）。
        discardDraft()
        emitState()
        return true
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        setDirty(true)
        scheduleDraftSave()   // 落ちても直前まで残るよう、未保存の本文をディスクへ
        emitState()           // 行数・状態を更新
    }

    // MARK: - 編集ツールボックス（選択の取得・置換。変換/パイプはこの2つに載る）

    var selectedText: String? {
        guard canEdit else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    /// 選択を置換し、NSTextView のアンドゥ機構に載せる（置換後を選択したまま残す）。
    func replaceSelection(with text: String) {
        guard canEdit else { NSSound.beep(); return }
        let range = textView.selectedRange()
        guard range.length > 0 else { NSSound.beep(); return }
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.replaceCharacters(in: range, with: text)
        textView.didChangeText()   // textDidChange 経由で dirty/draft/状態が更新される
        textView.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
    }

    // MARK: - DocumentPane

    func reEmitState() { emitState() }

    func focusContent() {
        window?.makeFirstResponder(textView)
    }

    /// 非表示中に本文を差し込んだペインをアクティブ表示にした直後、確実に描画させる。
    /// 隠れたまま `string` を設定するとグリフのレイアウトが遅延し、操作するまで空に
    /// 見えることがある。フレーム確定→グリフレイアウト→再描画を明示的に走らせる。
    func ensureVisibleLayout() {
        layoutSubtreeIfNeeded()
        if let container = textView.textContainer, let lm = textView.layoutManager {
            lm.ensureLayout(for: container)
        }
        textView.needsDisplay = true
    }

    func applyCurrentFontSize() {
        textView.font = EditorFont.current()
        applyParagraphStyle()   // 行高はフォント依存なので再計算する
    }

    func applyDisplaySettings() {
        textView.cursorShape = AppSettings.cursorShape
        textView.highlightCurrentLine = AppSettings.highlightCurrentLine
        applyParagraphStyle()   // タブ幅・行間
        applyColors()           // 配色（テーマ）
        textView.needsDisplay = true
    }

    // MARK: - 構造化表示

    func setStructuredMode(_ mode: StructuredMode?) {
        if jsonQueryActive { closeJsonQuery() }   // クエリ中に構造化へ切替えるならまず畳む
        guard let mode else {
            // OFF: 本文復元・編集可・折り返し復帰。
            guard let original = preStructuredText else { structuredFormatter = nil; jsonPrettyActive = false; return }
            structuredFormatter = nil
            jsonPrettyActive = false
            preStructuredText = nil
            textView.isEditable = true
            setWrapMode(wrapped: true)
            textView.delegate = nil
            textView.string = original
            textView.delegate = self
            applyParagraphStyle(); applyColors()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            emitState()
            return
        }
        // ON: 現在の本文から整形（読み取り専用）。
        let source = preStructuredText ?? textView.string
        // JSON 整形は単一ドキュメントの字下げ（列指向でない）。不正 JSON なら切り替えず beep。
        if mode == .json {
            guard let pretty = JsonFormatter.pretty(source) else { NSSound.beep(); return }
            preStructuredText = source
            structuredFormatter = nil
            jsonPrettyActive = true
            textView.isEditable = false
            setWrapMode(wrapped: false)
            textView.delegate = nil
            textView.textStorage?.setAttributedString(readonlyAttributed(pretty))
            textView.delegate = self
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            return
        }
        preStructuredText = source
        jsonPrettyActive = false
        var lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // 末尾改行の余り
        let fmt = TabularFormatter.build(mode: mode, sampleLines: Array(lines.prefix(1000)))
        structuredFormatter = fmt
        textView.isEditable = false
        setWrapMode(wrapped: false)
        let formatted = formattedText(lines: lines, formatter: fmt)
        textView.delegate = nil
        textView.textStorage?.setAttributedString(formatted)
        textView.delegate = self
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// 整形済みの読み取り専用テキスト（等幅・CSV/TSV は先頭行を太字）。
    private func formattedText(lines: [String], formatter: TabularFormatter) -> NSAttributedString {
        let font = EditorFont.current()
        let theme = EditorTheme.current()
        let style = EditorStyle.paragraphStyle(for: font)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.foreground, .paragraphStyle: style]
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            var attrs = base
            if formatter.mode != .ndjson, i == 0 { attrs[.font] = bold }
            out.append(NSAttributedString(string: formatter.format(line), attributes: attrs))
            out.append(NSAttributedString(string: "\n", attributes: base))
        }
        return out
    }

    /// 読み取り専用の整形テキスト（等幅・テーマ配色）。JSON 整形の描画に使う。
    private func readonlyAttributed(_ s: String) -> NSAttributedString {
        let font = EditorFont.current()
        let theme = EditorTheme.current()
        let style = EditorStyle.paragraphStyle(for: font)
        return NSAttributedString(string: s,
                                  attributes: [.font: font, .foregroundColor: theme.foreground, .paragraphStyle: style])
    }

    // MARK: - JSON その場クエリ（結果は揮発＝保存しない読み取り専用）

    var supportsJsonQuery: Bool { true }
    var jsonQueryIsActive: Bool { jsonQueryActive }

    /// クエリバーを開閉する。開くには本文が妥当な JSON であること（不正なら beep）。
    func toggleJsonQuery() {
        if jsonQueryActive { closeJsonQuery(); return }
        let source = preStructuredText ?? textView.string
        guard JsonFormatter.pretty(source) != nil else { NSSound.beep(); return }   // 妥当な JSON のみ
        // 構造化/整形が出ていたら畳んでソースを確定。
        preStructuredText = source
        structuredFormatter = nil
        jsonPrettyActive = false
        jsonQueryActive = true
        textView.isEditable = false
        setWrapMode(wrapped: false)
        showQueryBar(true)
        jsonQueryBar.clear()
        runJsonQuery("")                 // 空＝全体を整形表示
        jsonQueryBar.focusField()
    }

    /// 式を評価して結果で本文を置き換える。空式は全体整形。エラーはバーに赤字表示。
    private func runJsonQuery(_ expr: String) {
        guard jsonQueryActive, let source = preStructuredText else { return }
        do {
            let text = try JsonQuery.run(expr, onJSONText: source)
            textView.delegate = nil
            textView.textStorage?.setAttributedString(readonlyAttributed(text))
            textView.delegate = self
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            jsonQueryBar.setStatus(error: nil)
        } catch {
            jsonQueryBar.setStatus(error: L("jsonquery.error"))
        }
    }

    /// クエリを終了して元の本文・編集可へ戻す（結果は保存しない）。
    private func closeJsonQuery() {
        guard jsonQueryActive else { return }
        jsonQueryActive = false
        showQueryBar(false)
        jsonQueryBar.clear()
        guard let original = preStructuredText else { textView.isEditable = true; return }
        preStructuredText = nil
        textView.isEditable = true
        setWrapMode(wrapped: true)
        textView.delegate = nil
        textView.string = original
        textView.delegate = self
        applyParagraphStyle(); applyColors()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        emitState()
    }

    private func showQueryBar(_ show: Bool) {
        jsonQueryBar.isHidden = !show
        scrollTopToContainer.isActive = !show
        scrollTopToBar.isActive = show
    }

    /// 折り返し（true）／横スクロール（false・列を折り返さない）を切り替える。
    private func setWrapMode(wrapped: Bool) {
        guard let container = textView.textContainer else { return }
        if wrapped {
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            let big = CGFloat.greatestFiniteMagnitude
            container.size = NSSize(width: big, height: big)
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: big, height: big)
            scrollView.hasHorizontalScroller = true
        }
    }

    /// 別ファイル読込・新規時に構造化表示を解除して素の編集状態へ戻す。
    private func resetStructuredPresentation() {
        if jsonQueryActive {
            jsonQueryActive = false
            showQueryBar(false)
            jsonQueryBar.clear()
        }
        guard structuredFormatter != nil || jsonPrettyActive || preStructuredText != nil else { return }
        structuredFormatter = nil
        jsonPrettyActive = false
        preStructuredText = nil
        textView.isEditable = true
        setWrapMode(wrapped: true)
    }

    /// 本文エリアの配色（前景・背景・選択）をテーマから適用する。現在行ハイライトは
    /// `EditorTextView` が描画時に `EditorTheme` を直接読む。
    private func applyColors() {
        let theme = EditorTheme.current()
        textView.textColor = theme.foreground
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.foreground
        scrollView.backgroundColor = theme.background
        textView.selectedTextAttributes[.backgroundColor] = theme.selection
    }

    /// 段落スタイル（タブ幅・行間）を typingAttributes と本文全体へ適用する。
    private func applyParagraphStyle() {
        let style = EditorStyle.paragraphStyle(for: textView.font ?? EditorFont.current())
        textView.defaultParagraphStyle = style
        textView.typingAttributes[.paragraphStyle] = style
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: style,
                                 range: NSRange(location: 0, length: storage.length))
        }
    }

    private func emitState() {
        let state = ViewerState(
            encodingName: encoding.displayName,
            lineCount: lineCount(of: logicalText),
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

#if DEBUG
extension EditableViewer {
    var _testText: String { textView.string }
    var _testEncoding: DetectedEncoding { encoding }
    var _testLineEnding: LineEnding { lineEnding }
    func _testSetText(_ s: String) { textView.string = s; setDirty(true) }
    func _testSelect(_ range: NSRange) { textView.setSelectedRange(range) }
    @discardableResult func _testWrite(to url: URL) -> Bool { write(to: url) }
    var _testJsonQueryActive: Bool { jsonQueryActive }
    /// クエリバーに式を入力したときと同じ経路（バーの UI に依存せず評価だけ走らせる）。
    func _testRunJsonQuery(_ expr: String) { runJsonQuery(expr) }
}
#endif
