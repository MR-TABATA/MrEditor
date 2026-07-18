import AppKit

/// 表示状態をステータスバーへ伝えるための情報。
struct ViewerState {
    var encodingName: String
    var lineCount: Int
    var lineCountIsExact: Bool
    var fileSize: Int
    var indexProgress: Double // 0...1
}

/// 1 ドキュメント＝1 ペインの共通インターフェース。
///
/// 大ファイルは読み取り専用の `LargeFileViewer`（mmap + スパース索引）、
/// 小ファイルは全読み込み編集の `EditableViewer`（NSTextView）が担う。
/// `MainWindowController` は具体型を意識せず、このプロトコル越しに扱う。
///
/// 検索・追従・行ジャンプは `LargeFileViewer` 固有の機能。編集ペインでは
/// 既定実装（no-op）に委ね、`supportsSearch` / `supportsFollow` で能力を申告する。
protocol DocumentPane: NSView {
    /// 開いているファイル（サイドバー／タイトル表示用）。
    var fileURL: URL? { get }

    /// ステータスバー更新の通知。
    var onStateChange: ((ViewerState) -> Void)? { get set }
    /// 検索状態の通知（検索バーの件数表示用）。編集ペインでは未使用。
    var onSearchState: ((Int, Int, Bool, Int, Bool) -> Void)? { get set }
    /// ファイルがドロップされたとき（新規ドキュメントとして開くのはコントローラ側）。
    var onDropFiles: (([URL]) -> Void)? { get set }

    /// ファイルを開く。失敗時は false。
    @discardableResult func open(url: URL) -> Bool

    /// バッファ（表示）の文字コード（「開き直す」メニューのチェック表示用）。
    var currentEncoding: DetectedEncoding { get }
    /// 保存時に書き出す文字コード（「テキストエンコーディング」メニューのチェック表示・ステータス用）。
    var currentSaveEncoding: DetectedEncoding { get }
    /// 保存時のエンコードを設定する（まだ書き出さない。dirty にして次の保存で反映）。
    func setSaveEncoding(_ encoding: DetectedEncoding)
    /// 現在のファイルを指定エンコードで開き直す（自動判定ミスの文字化けを直す）。成功で true。
    @discardableResult func reopen(withEncoding encoding: DetectedEncoding) -> Bool
    /// 現在の状態を `onStateChange` に再送信する（ドキュメント切替時のステータスバー更新用）。
    func reEmitState()
    /// 本文へフォーカスを戻す。
    func focusContent()
    /// アクティブ表示になった直後に確実に本文を描画させる（初回レイアウトの取りこぼし対策）。
    func ensureVisibleLayout()
    /// 現在のグローバルフォントサイズを自身の表示へ反映する。
    func applyCurrentFontSize()
    /// 長い行の折り返し設定（AppSettings.lineWrap）を自身の表示へ反映する。
    func applyLineWrap()
    /// 表示設定（タブ幅・行間・現在行ハイライト・カーソル形状）を自身の表示へ反映する。
    func applyDisplaySettings()

    /// 検索・フィルタに対応するか（検索バーを出してよいか）。
    var supportsSearch: Bool { get }
    /// 末尾追従（tail -f）に対応するか。
    var supportsFollow: Bool { get }

    // MARK: - 構造化表示（CSV/TSV/NDJSON の読み取り専用整形。両ビューアが対応）

    /// 構造化表示に対応するか（View メニューの有効化）。
    var supportsStructured: Bool { get }
    /// JSON 整形（単一ドキュメント全体の字下げ）に対応するか。全文をメモリに載せる操作なので
    /// 小ファイルの編集ペインのみ。大ファイル経路は行指向の NDJSON が担当する。
    var supportsJsonReformat: Bool { get }
    /// 現在の構造化表示モード（nil＝オフ）。
    var structuredMode: StructuredMode? { get }
    /// 構造化表示モードを設定する（nil でオフ＝通常表示へ復帰）。
    func setStructuredMode(_ mode: StructuredMode?)

    /// JSON その場クエリ（jmespath 相当・結果は揮発）に対応するか。小ファイルペインのみ。
    var supportsJsonQuery: Bool { get }
    /// クエリバーが現在開いているか（メニューのチェック表示）。
    var jsonQueryIsActive: Bool { get }
    /// クエリバーを開閉する。
    func toggleJsonQuery()

    // MARK: - 編集・保存（編集ペインのみ。読み取り専用は既定実装で no-op）

    /// 編集・保存できるか（保存メニューの有効化・読み取り専用バナーの判定）。
    var canEdit: Bool { get }
    /// 未保存の変更があるか。
    var isDirty: Bool { get }
    /// セッション復元用の本文（未保存の新規ドキュメントを保存/再現するため）。
    /// 大ファイル等・復元非対応のペインは nil（既定）。
    var restorableText: String? { get }

    // MARK: - 未保存の本文の保護（DraftStore）

    /// 未保存の新規ドキュメントの本文を持つ draft の id（保存済み・復元非対応のペインは nil）。
    var draftID: String? { get }
    /// 溜めている本文を今すぐ draft へ書き出す（終了直前・非アクティブ化時に呼ぶ）。
    func flushDraft()
    /// draft を捨てる。**ユーザーがそのドキュメントを閉じた（破棄した）ときだけ呼ぶ。**
    func discardDraft()
    /// 未保存状態が変化したときの通知（タイトルバーの編集済みドット用）。
    var onDirtyChange: ((Bool) -> Void)? { get set }
    /// 既存パスへ保存する。成功で true。
    @discardableResult func save() -> Bool
    /// 保存先を選んで保存する（Save As）。成功で true。
    @discardableResult func saveAs() -> Bool

    /// 印刷できるか（プリントダイアログから PDF 保存もできる）。
    /// 巨大ファイルは数百万ページになり意味を成さないため既定で false。
    var canPrint: Bool { get }
    /// プリントダイアログを出す。
    func printDocument()

    // 検索／追従／行ジャンプ（編集ペインでは既定で no-op）。
    func setSearchQuery(_ q: String)
    func setCaseSensitive(_ on: Bool)
    func setRegexMode(_ on: Bool)
    func setFilterMode(_ on: Bool)
    func findNext()
    func findPrev()
    func setFollowMode(_ on: Bool)
    var isFollowing: Bool { get }
    func goToLine(_ line1Based: Int)
    /// 現在の一致を置換して次へ（反復置換）。
    func replaceCurrent(with replacement: String)
    /// 一致をすべて置換（1 アンドゥ）。
    func replaceAll(with replacement: String)

    /// 現在の選択テキスト（編集可能ペインで選択があるときのみ）。編集ツールボックスの入力。
    var selectedText: String? { get }
    /// 現在の選択を `text` で置換する（1 アンドゥ／置換後のテキストを選択したまま残す）。
    func replaceSelection(with text: String)
}

extension DocumentPane {
    var supportsSearch: Bool { true }
    var supportsFollow: Bool { true }

    var supportsStructured: Bool { false }
    var supportsJsonReformat: Bool { false }
    var structuredMode: StructuredMode? { nil }
    func setStructuredMode(_ mode: StructuredMode?) {}

    var supportsJsonQuery: Bool { false }
    var jsonQueryIsActive: Bool { false }
    func toggleJsonQuery() {}

    var currentEncoding: DetectedEncoding { .utf8 }
    var currentSaveEncoding: DetectedEncoding { .utf8 }
    func setSaveEncoding(_ encoding: DetectedEncoding) {}
    @discardableResult func reopen(withEncoding encoding: DetectedEncoding) -> Bool { false }

    // 読み取り専用ペインの既定（編集・保存なし）。onDirtyChange は各ペインが保持する。
    var canEdit: Bool { false }
    var isDirty: Bool { false }
    var restorableText: String? { nil }

    // 未保存の本文を持たないペイン（読み取り専用・巨大ファイル）は draft と無縁。
    var draftID: String? { nil }
    func flushDraft() {}
    func discardDraft() {}
    @discardableResult func save() -> Bool { false }
    @discardableResult func saveAs() -> Bool { false }

    // 読み取り専用の巨大ファイルは印刷しない（8,600 万行＝数百万ページになる）。
    var canPrint: Bool { false }
    func printDocument() {}

    func setSearchQuery(_ q: String) {}
    func setCaseSensitive(_ on: Bool) {}
    func setRegexMode(_ on: Bool) {}
    func setFilterMode(_ on: Bool) {}
    func findNext() {}
    func findPrev() {}
    func setFollowMode(_ on: Bool) {}
    var isFollowing: Bool { false }
    func goToLine(_ line1Based: Int) {}
    func replaceCurrent(with replacement: String) {}
    func replaceAll(with replacement: String) {}

    // 編集ツールボックスの既定。読み取り専用ペインは選択なし＝何もしない。
    var selectedText: String? { nil }
    func replaceSelection(with text: String) { NSSound.beep() }

    /// 選択テキストに純粋変換を適用する。selectedText/replaceSelection の上に載るだけ。
    func applyTextTransform(_ transform: TextTransform) {
        guard let source = selectedText, !source.isEmpty else { NSSound.beep(); return }
        guard let result = transform.apply(source) else { NSSound.beep(); return }   // 変換不能（不正入力）
        guard result != source else { return }   // 変化なしはアンドゥを積まない
        replaceSelection(with: result)
    }
    func applyLineWrap() {}
    func ensureVisibleLayout() {}
}
