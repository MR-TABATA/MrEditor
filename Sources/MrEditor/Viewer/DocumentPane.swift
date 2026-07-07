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
    /// 現在のグローバルフォントサイズを自身の表示へ反映する。
    func applyCurrentFontSize()
    /// 長い行の折り返し設定（AppSettings.lineWrap）を自身の表示へ反映する。
    func applyLineWrap()

    /// 検索・フィルタに対応するか（検索バーを出してよいか）。
    var supportsSearch: Bool { get }
    /// 末尾追従（tail -f）に対応するか。
    var supportsFollow: Bool { get }

    // MARK: - 編集・保存（編集ペインのみ。読み取り専用は既定実装で no-op）

    /// 編集・保存できるか（保存メニューの有効化・読み取り専用バナーの判定）。
    var canEdit: Bool { get }
    /// 未保存の変更があるか。
    var isDirty: Bool { get }
    /// 未保存状態が変化したときの通知（タイトルバーの編集済みドット用）。
    var onDirtyChange: ((Bool) -> Void)? { get set }
    /// 既存パスへ保存する。成功で true。
    @discardableResult func save() -> Bool
    /// 保存先を選んで保存する（Save As）。成功で true。
    @discardableResult func saveAs() -> Bool

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
}

extension DocumentPane {
    var supportsSearch: Bool { true }
    var supportsFollow: Bool { true }

    var currentEncoding: DetectedEncoding { .utf8 }
    var currentSaveEncoding: DetectedEncoding { .utf8 }
    func setSaveEncoding(_ encoding: DetectedEncoding) {}
    @discardableResult func reopen(withEncoding encoding: DetectedEncoding) -> Bool { false }

    // 読み取り専用ペインの既定（編集・保存なし）。onDirtyChange は各ペインが保持する。
    var canEdit: Bool { false }
    var isDirty: Bool { false }
    @discardableResult func save() -> Bool { false }
    @discardableResult func saveAs() -> Bool { false }

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
    func applyLineWrap() {}
}
