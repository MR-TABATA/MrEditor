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
    /// このペインの編集履歴（窓ではなくペインごとに持つ。undoManager(for:) 参照）。
    private let paneUndoManager = UndoManager()
    private let jsonQueryBar = JsonQueryBar()
    /// 行番号ガター（config 連動で出し入れする）。
    private var lineNumberRuler: LineNumberRulerView!
    /// 行頭索引のキャッシュ（行番号ガターとステータスバーの「行:桁」が共有する）。
    /// 本文が変わったら捨てて、次に必要になったときに数え直す。
    private var lineIndexCache: LineStartIndex?
    /// クエリバー表示/非表示で本文の上端を切り替える（片方だけ有効化）。
    private var scrollTopToContainer: NSLayoutConstraint!
    private var scrollTopToBar: NSLayoutConstraint!

    // MARK: - 桁ルーラー（A）と桁ガイド（B）
    private let columnRuler = ColumnRulerView()
    private var columnRulerOn = false
    /// ルーラーを出す前の折り返し設定。**折り返したままでは桁が定まらない**ので出すときに
    /// 横スクロールへ切り替え、しまうときにここへ戻す。
    private var wrapBeforeColumnRuler: Bool?
    private var rulerTopToContainer: NSLayoutConstraint!
    private var rulerTopToBar: NSLayoutConstraint!
    private var scrollTopToRuler: NSLayoutConstraint!

    private(set) var fileURL: URL?
    private var encoding: DetectedEncoding = .utf8
    /// ユーザーが「開き直す」で明示したエンコード（自動判定に戻さないため、読み込み直しで引き継ぐ）。
    private var userChosenEncoding: DetectedEncoding?
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
    var onSearchState: ((Int, Int, Bool, Int, Bool, Bool) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    // 検索は素の編集状態でのみ（構造化／整形／クエリ中は読み取り専用の見た目で、
    // 置換の行き先が本文でなくなるため）。末尾追従は巨大ファイル閲覧の機能なので出さない。
    var supportsSearch: Bool { structuredFormatter == nil && !jsonPrettyActive && !jsonQueryActive }
    var supportsFollow: Bool { false }
    /// 「一致行だけ表示」は本文を一致行だけに差し替える読み取り専用の見せ方。
    /// 素の編集状態でだけ受ける（構造化／整形／クエリ中は既に本文が差し替わっている）。
    var supportsSearchFilter: Bool { structuredFormatter == nil && !jsonPrettyActive && !jsonQueryActive }
    /// 一致行だけ表示の最中は読み取り専用＝置換の行き先が本文でなくなるので受けない。
    var supportsReplace: Bool { canEdit }
    /// 整形/クエリ中と、一致行だけ表示の間は読み取り専用。
    var canEdit: Bool { structuredFormatter == nil && !jsonPrettyActive && !jsonQueryActive && preFilterText == nil }

    // MARK: - 構造化表示（読み取り専用の整形ビュー）
    private var structuredFormatter: TabularFormatter?
    /// JSON 整形（単一ドキュメントの字下げ）が有効か。CSV/TSV/NDJSON と違い列指向でないため別フラグ。
    private var jsonPrettyActive = false
    /// JSON クエリ窓が有効か（結果を読み取り専用で表示中）。
    private var jsonQueryActive = false
    /// 構造化 ON 前の本文（OFF で復元）。
    private var preStructuredText: String?

    // MARK: - 一致行だけ表示（フィルタ／live grep）
    //
    // 巨大ファイル側は可視行を自前で描くので「一致行だけ描く」で済むが、
    // こちらは `NSTextView` に本文を載せているので、**一致行だけの本文に差し替える**。
    // 構造化表示と同じやり方（元本文を退避して読み取り専用にする）に揃えてある。
    // 保存・行数・draft は必ず `logicalText`＝元の本文を見る。ここを間違えると
    // 「フィルタしたまま保存したら他の行が消えた」という最悪の壊し方になる。

    /// フィルタ ON 前の本文（OFF で復元）。nil ならフィルタしていない。
    private var preFilterText: String?
    /// 表示している各行が、元の本文の何行目だったか（0 始まり）。ガターに元の番号を出すため。
    private var filterLineNumbers: [Int] = []
    var supportsStructured: Bool { true }
    var supportsJsonReformat: Bool { true }   // 全文を保持する小ファイルペインなので単一 JSON 整形が可能
    var structuredMode: StructuredMode? { jsonPrettyActive ? .json : structuredFormatter?.mode }
    var structuredColumnNames: [String] { structuredFormatter?.columns.map(\.key) ?? [] }
    /// フィルタ中の一致行（0 始まり）。`filterLineNumbers` がそのまま元の行番号。
    var filterMatchLines: [Int]? { preFilterText != nil ? filterLineNumbers : nil }

    // MARK: - 検索・置換の状態
    //
    // 全文がメモリにあるので、巨大ファイル側（SearchEngine の非同期走査）と違い
    // その場で全一致を数え切れる。一致は UTF-16 レンジの配列として持ち、
    // ハイライトは可視範囲だけ temporary attribute で塗る（本文の属性は汚さない）。

    private var searchQuery = ""
    private var searchTerms: [String] = []
    private var searchRegex: NSRegularExpression?
    private var searchCaseSensitive = false
    private var searchRegexMode = false
    private var searchPreserveCase = false
    /// 正規表現が壊れている（検索バーに「不正」と出す）。
    private var searchInvalid = false
    /// 一致レンジ（本文順）。
    private var matches: [NSRange] = []
    /// 現在の一致（1 始まり。0＝まだ移動していない）。
    private var currentMatch = 0
    /// 数え切る上限。1 文字クエリで数百万一致になっても打鍵が止まらないように。
    /// 打ち鍵ごとに同期で数えるので、ここを外すと 8MB×1 文字で目に見えて詰まる。
    private static let matchCap = 200_000
    /// 上限で打ち切ったか（＝`matches.count` は総数でなく下限）。件数表示を「N 件以上」にする。
    private var matchesCapped = false

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

        // 行番号ガター。スクロール・本文変更・設定変更で描き直す。
        let ruler = LineNumberRulerView(textView: textView)
        ruler.lineIndexProvider = { [weak self] in self?.currentLineIndex() ?? LineStartIndex("") }
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = AppSettings.showLineNumbers
        lineNumberRuler = ruler
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        jsonQueryBar.translatesAutoresizingMaskIntoConstraints = false
        jsonQueryBar.isHidden = true
        jsonQueryBar.onQueryChange = { [weak self] q in self?.runJsonQuery(q) }
        jsonQueryBar.onClose = { [weak self] in self?.closeJsonQuery() }
        addSubview(jsonQueryBar)

        columnRuler.translatesAutoresizingMaskIntoConstraints = false
        columnRuler.isHidden = true
        columnRuler.onToggleGuide = { [weak self] col in self?.toggleColumnGuide(col) }
        addSubview(columnRuler)

        // 上から [クエリバー][桁ルーラー][本文]。出ているものだけが場所を取る。
        scrollTopToContainer = scrollView.topAnchor.constraint(equalTo: topAnchor)
        scrollTopToBar = scrollView.topAnchor.constraint(equalTo: jsonQueryBar.bottomAnchor)
        scrollTopToRuler = scrollView.topAnchor.constraint(equalTo: columnRuler.bottomAnchor)
        rulerTopToContainer = columnRuler.topAnchor.constraint(equalTo: topAnchor)
        rulerTopToBar = columnRuler.topAnchor.constraint(equalTo: jsonQueryBar.bottomAnchor)
        NSLayoutConstraint.activate([
            jsonQueryBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            jsonQueryBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            jsonQueryBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            jsonQueryBar.heightAnchor.constraint(equalToConstant: JsonQueryBar.height),
            columnRuler.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnRuler.trailingAnchor.constraint(equalTo: trailingAnchor),
            columnRuler.heightAnchor.constraint(equalToConstant: ColumnRulerView.height),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollTopToContainer,
        ])
    }

    // MARK: - 桁ルーラー（A）と桁ガイド（B）

    var supportsColumnRuler: Bool { true }
    var columnRulerVisible: Bool { columnRulerOn }
    var hasColumnGuides: Bool { !textView.columnGuides.isEmpty }

    func setColumnRulerVisible(_ on: Bool) {
        guard on != columnRulerOn else { return }
        columnRulerOn = on
        if on {
            // 折り返していると 1 行が複数行に割れて桁が定まらない。数えるために横スクロールへ。
            // 構造化表示中などで既に横スクロールなら触らない（戻すときに壊さないよう記録もしない）。
            if textView.textContainer?.widthTracksTextView == true {
                wrapBeforeColumnRuler = true
                setWrapMode(wrapped: false)
            }
        } else if wrapBeforeColumnRuler == true {
            wrapBeforeColumnRuler = nil
            // ルーラーを出している間に構造化表示などへ移っていたら、そちらの都合を壊さない。
            if canEdit { setWrapMode(wrapped: true) }
        }
        updateTopLayout()
        syncColumnRuler()
        textView.needsDisplay = true
    }

    func clearColumnGuides() {
        guard !textView.columnGuides.isEmpty else { return }
        textView.columnGuides.removeAll()
        columnRuler.guides = textView.columnGuides
    }

    private func toggleColumnGuide(_ column: Int) {
        textView.columnGuides.toggle(column)
        columnRuler.guides = textView.columnGuides
    }

    /// クエリバー／桁ルーラーの有無に応じて本文の上端を張り替える。
    private func updateTopLayout() {
        let bar = !jsonQueryBar.isHidden
        columnRuler.isHidden = !columnRulerOn
        for c in [scrollTopToContainer, scrollTopToBar, scrollTopToRuler,
                  rulerTopToContainer, rulerTopToBar] {
            c?.isActive = false
        }
        if columnRulerOn {
            (bar ? rulerTopToBar : rulerTopToContainer)?.isActive = true
            scrollTopToRuler.isActive = true
        } else {
            (bar ? scrollTopToBar : scrollTopToContainer)?.isActive = true
        }
    }

    /// ルーラーへ現在の桁幅・原点・スクロール量・キャレット桁を送る。
    private func syncColumnRuler() {
        guard columnRulerOn else { return }
        let font = textView.font ?? EditorFont.current()
        columnRuler.columnWidth = EditorStyle.columnWidth(for: font)
        // 1 桁目の x は**推測しない**。ガター幅・コンテナ余白・スクロール位置を足し合わせる
        // 式を自分で書くと必ずどれかを二重に数える（実際に行番号ガターぶん右へずれた）。
        // 本文の 1 文字目がどこに描かれているかを AppKit に変換させ、それをそのまま原点にする。
        let offset = scrollView.contentView.bounds.origin.x
        columnRuler.horizontalOffset = offset
        let textOriginInTextView = textView.textContainerOrigin.x
            + (textView.textContainer?.lineFragmentPadding ?? 0)
        let inPane = textView.convert(NSPoint(x: textOriginInTextView, y: 0), to: columnRuler)
        // 変換にはスクロールで流れたぶんが入っている。ルーラー側で改めて引くので足し戻す。
        columnRuler.contentInset = inPane.x + offset
        columnRuler.guides = textView.columnGuides
        columnRuler.currentColumn = caretPosition.column
        columnRuler.selectedColumns = selectedColumnRange()
    }

    /// 選択の桁範囲（1 行に収まっているときだけ）。複数行にまたがる選択は桁の帯にならない。
    private func selectedColumnRange() -> ClosedRange<Int>? {
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        let text = textView.string as NSString
        let index = currentLineIndex()
        let start = index.position(at: range.location, in: text)
        let end = index.position(at: NSMaxRange(range), in: text)
        guard start.line == end.line, end.column > start.column else { return nil }
        return start.column...(end.column - 1)
    }

    override var isFlipped: Bool { true }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - 行頭索引（行番号ガター・キャレット位置の共有キャッシュ）

    /// 表示中の本文の行頭索引。無ければ数え直してキャッシュする。
    private func currentLineIndex() -> LineStartIndex {
        if let cached = lineIndexCache { return cached }
        let index = LineStartIndex(textView.string as NSString)
        lineIndexCache = index
        return index
    }

    /// 本文を差し替えた／編集したときに呼ぶ（次に必要になったとき数え直す）。
    /// 本文が変われば検索の一致位置も無効になるので、ここで数え直す（本文の代入は
    /// delegate を通らないため、textDidChange だけでは取りこぼす）。
    private func invalidateLineIndex() {
        lineIndexCache = nil
        lineNumberRuler?.updateThickness()
        lineNumberRuler?.needsDisplay = true
        if !searchQuery.isEmpty { recomputeMatches() }
    }

    @objc private func scrolled() {
        lineNumberRuler?.needsDisplay = true
        syncColumnRuler()                               // 横スクロールに目盛りを追従させる
        if !matches.isEmpty { applySearchHighlight() }   // 可視範囲だけ塗るので送り直す
    }

    /// キャレット位置（1 始まりの行・桁）。選択中は選択の先頭を指す。
    private var caretPosition: (line: Int, column: Int) {
        let text = textView.string as NSString
        return currentLineIndex().position(at: textView.selectedRange().location, in: text)
    }

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
        self.userChosenEncoding = forcedEncoding
        self.encoding = detected
        self.lineEnding = LineEnding.detect(Data(prefix), encoding: detected)
        self.byteSize = data.count
        resetStructuredPresentation()
        textView.string = text
        invalidateLineIndex()
        applyParagraphStyle()                       // タブ幅・行間を本文全体へ
        textView.undoManager?.removeAllActions()   // 読み込みはアンドゥ対象にしない
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        setDirty(false)
        emitState()
        return true
    }

    /// 他のアプリで書き換えられたファイルを取り込み直す。
    /// キャレットとスクロール位置は保つ（自動で走るので、毎回先頭へ飛ばされると使い物にならない）。
    /// エンコードは、ユーザーが「開き直す」で指定していればそれを引き継ぐ（自動判定に戻さない）。
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let url = fileURL else { return false }
        let selection = textView.selectedRange()
        let scrollOrigin = scrollView.contentView.bounds.origin
        guard open(url: url, forcedEncoding: userChosenEncoding) else { return false }

        // 短くなっていることがあるので、選択は新しい本文の長さへ丸める。
        let length = (textView.string as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location,
                                          length: min(selection.length, length - location)))
        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
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
        invalidateLineIndex()
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
        invalidateLineIndex()
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
    private var logicalText: String { preFilterText ?? preStructuredText ?? textView.string }

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

    /// このペイン専用のアンドゥ。既定では窓のアンドゥを共有するが、1 窓に複数ドキュメントが
    /// 並ぶ作りなので、それでは ⌘Z が別ドキュメントの編集まで巻き戻してしまう。
    func undoManager(for view: NSTextView) -> UndoManager? { paneUndoManager }

    func textDidChange(_ notification: Notification) {
        setDirty(true)
        scheduleDraftSave()   // 落ちても直前まで残るよう、未保存の本文をディスクへ
        invalidateLineIndex() // 行がずれた＝行番号ガターとキャレット位置を数え直す
        emitState()           // 行数・状態を更新
    }

    /// キャレット移動でステータスバーの「行:桁」を更新する。
    func textViewDidChangeSelection(_ notification: Notification) {
        emitState()
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

    // MARK: - マルチカーソル（NSTextView の不連続選択に載る＝このペインだけ）

    var supportsMultiCursor: Bool { canEdit }
    func addCaret(above: Bool) {
        guard canEdit else { NSSound.beep(); return }
        textView.addCaret(above: above)
    }
    func selectNextOccurrence() {
        guard canEdit else { NSSound.beep(); return }
        textView.selectNextOccurrence()
    }

    // MARK: - 検索・置換

    func setSearchQuery(_ q: String) {
        guard q != searchQuery else { return }
        searchQuery = q
        rebuildSearch()
    }
    func setCaseSensitive(_ on: Bool) {
        guard on != searchCaseSensitive else { return }
        searchCaseSensitive = on
        rebuildSearch()
    }
    func setRegexMode(_ on: Bool) {
        guard on != searchRegexMode else { return }
        searchRegexMode = on
        rebuildSearch()
    }
    func setPreserveCase(_ on: Bool) { searchPreserveCase = on }
    /// 一致行だけを表示する（live grep）。ON の間は読み取り専用で、本文は一致行だけに差し替わる。
    /// 元の本文は `preFilterText` に退避してあり、保存・行数・draft は常にそちらを見る。
    func setFilterMode(_ on: Bool) {
        guard on != (preFilterText != nil) else { return }
        if on {
            guard supportsSearchFilter else { NSSound.beep(); return }
            preFilterText = textView.string
            textView.isEditable = false
            applyFilteredText()
        } else {
            guard let original = preFilterText else { return }
            preFilterText = nil
            filterLineNumbers = []
            lineNumberRuler?.displayLineNumber = nil
            lineNumberRuler?.maxLineNumberOverride = nil
            textView.isEditable = true
            textView.delegate = nil
            textView.string = original
            textView.delegate = self
            applyParagraphStyle(); applyColors()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            invalidateLineIndex()
            recomputeMatches()
            emitState()
        }
    }

    /// 指定した行だけを表示する（時間分布のドラッグ選択から）。空配列なら解除。
    func showOnlyLines(_ lines: [Int]) {
        guard !lines.isEmpty else {
            if preFilterText != nil { setFilterMode(false) }
            return
        }
        guard supportsSearchFilter else { NSSound.beep(); return }
        if preFilterText == nil {
            preFilterText = textView.string
            textView.isEditable = false
        }
        applyFilteredText(only: Set(lines))
    }

    /// 元の本文から一致行だけを抜き出して表示に載せ直す。クエリを変えるたびに呼ぶ。
    /// クエリが空なら一致は 0 件＝何も出ない（巨大ファイル側のフィルタと同じ振る舞い）。
    private func applyFilteredText(only explicit: Set<Int>? = nil) {
        guard let source = preFilterText else { return }
        var lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // 末尾改行の余り（幻の空行を作らない）
        var kept: [String] = []
        var numbers: [Int] = []
        for (i, line) in lines.enumerated() {
            // 行を指定されていればそれに従う（時間分布からの絞り込み）。無ければ検索の一致行。
            let keep = explicit.map { $0.contains(i) } ?? !matchRanges(in: line).isEmpty
            guard keep else { continue }
            kept.append(line)
            numbers.append(i)
        }
        filterLineNumbers = numbers
        // ガターは表示順ではなく**元の行番号**を出す（飛び飛びであることが分かるように）。
        lineNumberRuler?.displayLineNumber = { [weak self] row in
            guard let self, row >= 0, row < self.filterLineNumbers.count else { return row + 1 }
            return self.filterLineNumbers[row] + 1
        }
        lineNumberRuler?.maxLineNumberOverride = max(lines.count, 1)

        textView.delegate = nil
        textView.string = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        textView.delegate = self
        applyParagraphStyle(); applyColors()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        lineIndexCache = nil
        lineNumberRuler?.updateThickness()
        lineNumberRuler?.needsDisplay = true
        recomputeMatches()
        emitState()
    }

    /// クエリ・モードからパターンを組み直し、一致を数え直す。
    private func rebuildSearch() {
        searchTerms = []
        searchRegex = nil
        searchInvalid = false
        if !searchQuery.isEmpty {
            if searchRegexMode {
                // ^ / $ は行頭・行末に当てる（巨大ファイル側が行ごとに照合するのと同じ手触り）。
                var opts: NSRegularExpression.Options = [.anchorsMatchLines]
                if !searchCaseSensitive { opts.insert(.caseInsensitive) }
                do { searchRegex = try NSRegularExpression(pattern: searchQuery, options: opts) }
                catch { searchInvalid = true }
            } else {
                searchTerms = searchQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            }
        }
        // 一致行だけ表示の最中は、載せている本文そのものを作り直す（中で数え直しまでやる）。
        if preFilterText != nil { applyFilteredText() } else { recomputeMatches() }
    }

    /// 本文全体の一致を数え直し、ハイライトと件数表示を更新する。
    private func recomputeMatches() {
        matches = matchRanges(in: textView.string)
        matchesCapped = matches.count >= Self.matchCap
        currentMatch = 0
        applySearchHighlight()
        emitSearchState()
    }

    /// 文字列中の一致（UTF-16 レンジ・本文順）。リテラルは語ごとの出現をすべて拾う。
    private func matchRanges(in text: String) -> [NSRange] {
        guard !searchInvalid else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        if let rx = searchRegex {
            rx.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
                if let r = m?.range, r.length > 0 {
                    out.append(r)
                    if out.count >= Self.matchCap { stop.pointee = true }
                }
            }
            return out
        }
        let opts: NSString.CompareOptions = searchCaseSensitive ? [] : .caseInsensitive
        for term in searchTerms where !term.isEmpty {
            var from = 0
            while from <= ns.length, out.count < Self.matchCap {
                let r = ns.range(of: term, options: opts, range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                out.append(r)
                from = r.location + max(1, r.length)
            }
        }
        if searchTerms.count > 1 { out.sort { $0.location < $1.location } }
        return out
    }

    private func emitSearchState() {
        onSearchState?(currentMatch, matches.count, false, 0, searchInvalid, matchesCapped)
    }

    /// 一致を塗る。可視範囲だけ塗るのでヒットが数万でもスクロールが重くならない
    /// （本文の属性ではなく temporary attribute＝アンドゥにも保存にも乗らない）。
    private func applySearchHighlight() {
        guard let lm = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        guard !matches.isEmpty else { return }
        // 「現在の一致」は選択（NSTextView が上から描く）で示す。ここは全一致を同じ色で塗る。
        let color = EditorTheme.current().searchMatch
        let visible = visibleCharacterRange()
        for r in matches where NSIntersectionRange(r, visible).length > 0 {
            lm.addTemporaryAttributes([.backgroundColor: color], forCharacterRange: r)
        }
    }

    /// いま画面に出ている文字範囲（前後に少し余裕を持たせる）。
    private func visibleCharacterRange() -> NSRange {
        guard let lm = textView.layoutManager, let container = textView.textContainer else {
            return NSRange(location: 0, length: 0)
        }
        let glyphs = lm.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = (textView.string as NSString).length
        let start = max(0, chars.location - 1000)
        let end = min(length, chars.location + chars.length + 1000)
        return NSRange(location: start, length: max(0, end - start))
    }

    func findNext() {
        guard !matches.isEmpty else { NSSound.beep(); return }
        let sel = textView.selectedRange()
        let from = sel.location + sel.length
        // 選択の後ろにある最初の一致。無ければ先頭へ回り込む。
        let idx = matches.firstIndex { $0.location >= from } ?? 0
        select(match: idx)
    }

    func findPrev() {
        guard !matches.isEmpty else { NSSound.beep(); return }
        let sel = textView.selectedRange()
        let idx = matches.lastIndex { $0.location < sel.location } ?? (matches.count - 1)
        select(match: idx)
    }

    /// `index` 番目の一致を選択して画面に入れる。
    private func select(match index: Int) {
        guard index >= 0, index < matches.count else { return }
        currentMatch = index + 1
        let r = matches[index]
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
        applySearchHighlight()
        emitSearchState()
    }

    /// 現在の一致を置換して次へ。選択が一致でなければ次を探すだけ（＝押し続けで送れる）。
    func replaceCurrent(with replacement: String) {
        guard canEdit else { NSSound.beep(); return }
        guard !matches.isEmpty else { NSSound.beep(); return }
        let sel = textView.selectedRange()
        guard sel.length > 0, matches.contains(where: { NSEqualRanges($0, sel) }),
              let text = replacementText(for: sel, with: replacement) else {
            findNext()
            return
        }
        guard textView.shouldChangeText(in: sel, replacementString: text) else { return }
        textView.replaceCharacters(in: sel, with: text)
        textView.didChangeText()   // textDidChange 経由で dirty/draft/一致の数え直しが走る
        let after = NSRange(location: sel.location + (text as NSString).length, length: 0)
        textView.setSelectedRange(after)
        findNext()
    }

    /// 一致をすべて置換（1 アンドゥ）。
    func replaceAll(with replacement: String) {
        guard canEdit, !matches.isEmpty, let storage = textView.textStorage else { NSSound.beep(); return }
        var ranges: [NSRange] = []
        var strings: [String] = []
        var last = -1
        for r in matches {
            guard r.location >= last else { continue }   // 語が重なった一致は先に採った方を優先
            guard let s = replacementText(for: r, with: replacement) else { continue }
            ranges.append(r)
            strings.append(s)
            last = r.location + r.length
        }
        guard !ranges.isEmpty else { NSSound.beep(); return }
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
                                        replacementStrings: strings) else { return }
        // 後ろから当てる（前を先に置換すると後ろのレンジがずれる）。
        storage.beginEditing()
        for (r, s) in zip(ranges, strings).reversed() { storage.replaceCharacters(in: r, with: s) }
        storage.endEditing()
        textView.didChangeText()
        applyParagraphStyle()   // 挿入分にもタブ幅・行間を効かせる
        textView.setSelectedRange(NSRange(location: min(ranges[0].location, storage.length), length: 0))
    }

    /// 一致レンジ `range` に当てる置換後文字列（正規表現は $1 展開・ケース維持を反映）。
    /// パターンに一致しなくなっていれば nil。
    private func replacementText(for range: NSRange, with replacement: String) -> String? {
        let ns = textView.string as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
        let matched = ns.substring(with: range)
        func shaped(_ s: String) -> String {
            searchPreserveCase ? CasePreserving.apply(s, matching: matched) : s
        }
        if let rx = searchRegex {
            let text = textView.string
            guard let m = rx.firstMatch(in: text, range: range), NSEqualRanges(m.range, range) else { return nil }
            return shaped(rx.replacementString(for: m, in: text, offset: 0, template: replacement))
        }
        return shaped(replacement)
    }

    /// 行ジャンプ（1 始まり）。その行の先頭へキャレットを置いて画面に入れる。
    func goToLine(_ line1Based: Int) {
        let ns = textView.string as NSString
        guard ns.length >= 0 else { return }
        let index = currentLineIndex()
        let line0 = min(max(0, line1Based - 1), max(0, index.lineCount - 1))
        let location = min(index.start(ofLine: line0), ns.length)
        let range = NSRange(location: location, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        focusContent()
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
        lineNumberRuler?.updateThickness()   // 行番号も同じフォントで描くので幅が変わる
        lineNumberRuler?.needsDisplay = true
    }

    func applyDisplaySettings() {
        textView.cursorShape = AppSettings.cursorShape
        textView.highlightCurrentLine = AppSettings.highlightCurrentLine
        textView.showInvisibles = AppSettings.showInvisibles
        applyParagraphStyle()   // タブ幅・行間
        applyColors()           // 配色（テーマ）
        scrollView.rulersVisible = AppSettings.showLineNumbers
        lineNumberRuler?.updateThickness()
        lineNumberRuler?.needsDisplay = true
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
            invalidateLineIndex()
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
            invalidateLineIndex()
            return
        }
        preStructuredText = source
        jsonPrettyActive = false
        var lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // 末尾改行の余り
        // 先頭だけでは後半で桁が伸びる列を取りこぼすため、両端をサンプルする
        // （大ファイル側の `structuredSampleLines` と同じ方針）。
        let sample = lines.count > 2000
            ? Array(lines.prefix(1000)) + Array(lines.suffix(1000))
            : lines
        let fmt = TabularFormatter.build(mode: mode, sampleLines: sample)
        structuredFormatter = fmt
        textView.isEditable = false
        setWrapMode(wrapped: false)
        let formatted = formattedText(lines: lines, formatter: fmt)
        textView.delegate = nil
        textView.textStorage?.setAttributedString(formatted)
        textView.delegate = self
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        invalidateLineIndex()
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
            invalidateLineIndex()
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
        invalidateLineIndex()
        emitState()
    }

    private func showQueryBar(_ show: Bool) {
        jsonQueryBar.isHidden = !show
        updateTopLayout()
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
        let translucent = !EditorTheme.isOpaqueBackground
        textView.textColor = theme.foreground
        textView.backgroundColor = EditorTheme.withBackgroundOpacity(theme.background)
        textView.insertionPointColor = theme.foreground
        // 透明時は背後（窓＝デスクトップ）を透かすため、周りのスクロールビューは背景を描かない。
        textView.drawsBackground = true
        scrollView.drawsBackground = !translucent
        scrollView.backgroundColor = EditorTheme.withBackgroundOpacity(theme.background)
        textView.enclosingScrollView?.contentView.drawsBackground = !translucent
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
            // クリーン時は読み込み時の実ディスクサイズ（正確・安価）。編集中は保存されるバイト数をライブ計算。
            fileSize: isDirty ? liveByteSize : byteSize,
            indexProgress: 1.0,
            caret: caretPosition
        )
        onStateChange?(state)
        syncColumnRuler()   // キャレット桁・選択の帯はここで追従する
    }

    /// 現在のバッファを保存したときのバイト数（EOL 正規化＋保存エンコード込み）。
    /// 表現不能なエンコードのときは UTF-8 での概算に落とす。
    private var liveByteSize: Int {
        let normalized = lineEnding.normalize(logicalText)
        let n = normalized.lengthOfBytes(using: encoding.stringEncoding)
        return (n > 0 || normalized.isEmpty) ? n : normalized.utf8.count
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
    func _testSetText(_ s: String) { textView.string = s; invalidateLineIndex(); setDirty(true) }
    func _testSelect(_ range: NSRange) { textView.setSelectedRange(range) }
    var _testSelection: NSRange { textView.selectedRange() }
    /// 折り返しているか（桁ルーラーは折り返しを切るので、その確認に使う）。
    var _testWrapsText: Bool { textView.textContainer?.widthTracksTextView ?? false }
    var _testColumnGuides: [Int] { textView.columnGuides.columns }
    /// ルーラーが「1 桁目はここ」と思っている x（ペイン座標・スクロール量を戻したもの）。
    var _testRulerColumnOneX: CGFloat { syncColumnRuler(); return columnRuler.contentInset }
    /// 本文の 1 文字目が実際に描かれている x（同じくペイン座標）。この 2 つは一致しなければならない。
    var _testFirstGlyphX: CGFloat? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              (textView.string as NSString).length > 0 else { return nil }
        lm.ensureLayout(for: tc)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: tc)
        let x = rect.minX + textView.textContainerOrigin.x
        return textView.convert(NSPoint(x: x, y: 0), to: columnRuler).x
            + scrollView.contentView.bounds.origin.x
    }
    /// ルーラーをクリックしたのと同じこと（当たり判定は `ColumnGuides.nearest` 側でテスト済み）。
    func _testToggleColumnGuide(_ column: Int) { toggleColumnGuide(column) }
    var _testMatchCount: Int { matches.count }
    var _testMatchesCapped: Bool { matchesCapped }
    static var _testMatchCap: Int { matchCap }
    var _testCurrentMatch: Int { currentMatch }
    var _testSearchInvalid: Bool { searchInvalid }
    /// アンドゥ 1 回。自動グループ（groupsByEvent）はイベントループの一巡で閉じるので、
    /// テストでは先にループを回してから戻す。
    func _testUndo() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        textView.undoManager?.undo()
    }
    @discardableResult func _testWrite(to url: URL) -> Bool { write(to: url) }
    var _testJsonQueryActive: Bool { jsonQueryActive }
    /// クエリバーに式を入力したときと同じ経路（バーの UI に依存せず評価だけ走らせる）。
    func _testRunJsonQuery(_ expr: String) { runJsonQuery(expr) }
}
#endif
