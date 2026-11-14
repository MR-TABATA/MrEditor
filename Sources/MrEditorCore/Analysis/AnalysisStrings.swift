import Foundation

/// 分析・ビュープリセットの文言。`.lproj` を持たず、日本語か否かだけで切り替える。
enum S {
    static var isJapanese: Bool {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ja")
    }

    static func t(_ ja: String, _ en: String) -> String { isJapanese ? ja : en }

    // MARK: - 分析ペイン

    static let close = t("閉じる", "Close")
    static let cancel      = t("中止", "Stop")
    static let rerun       = t("もう一度実行", "Run again")
    static let copyTSV     = t("選択行をコピー（TSV）", "Copy selected rows (TSV)")
    static let exportCSV   = t("CSV で書き出し…", "Export as CSV…")
    static let targetWhole = t("対象: 全体", "Target: whole file")
    static let notReady    = t("この機能はまだ空です（土台だけが入っています）",
                               "This tab is still empty — only the foundation is in place.")
    static let noDocument  = t("開いているドキュメントがありません",
                               "No document is open.")

    static func featureTab(_ feature: AnalysisFeature) -> String {
        switch feature {
        case .aggregate:       return t("集計", "Count")
        case .columnStats:     return t("列の統計", "Columns")
        case .timeHistogram:   return t("時間分布", "Time")
        case .crossFileSearch: return t("横断検索", "Search")
        }
    }

    static func targetFiltered(_ lines: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: lines), number: .decimal)
        return t("対象: フィルタ中の \(n) 行", "Target: \(n) filtered lines")
    }

    // MARK: - 集計（C1）

    static let modeColumn     = t("列", "Column")
    static let modeKeyValue   = t("key=value", "key=value")
    static let modeRegex      = t("正規表現", "Regex")
    static let modeWholeLine  = t("行全体", "Whole line")
    static let count          = t("数える", "Count")
    static let caseSensitive  = t("大小を区別", "Match case")
    static let columnValue    = t("値", "Value")
    static let columnCount    = t("件数", "Count")
    static let columnShare    = t("割合", "Share")
    static let keyPlaceholderAggregate = t("キー名（例: status）", "key name (e.g. status)")
    static let regexNeedsGroup = t("正規表現には括弧（キャプチャ）が 1 つ要ります。例: status=(\\d+)",
                                   "The pattern needs one capture group, e.g. status=(\\d+)")

    static func columnNumber(_ n: Int) -> String { t("列 \(n)", "Column \(n)") }

    /// 「8,642万行 / 3.32 秒 / 3 種類」。**丸めない。**
    static func aggregateSummary(lines: Int, seconds: TimeInterval, distinct: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: lines), number: .decimal)
        let d = NumberFormatter.localizedString(from: NSNumber(value: distinct), number: .decimal)
        let sec = String(format: "%.2f", seconds)
        return t("\(n) 行 / \(sec) 秒 / \(d) 種類", "\(n) lines / \(sec) s / \(d) distinct")
    }

    /// 打ち切ったときの注意書き。**「上位を推定しました」とは言わない**（推定はしていない）。
    static func truncationNotice(distinct: Int, rows: Int) -> String {
        let d = NumberFormatter.localizedString(from: NSNumber(value: distinct), number: .decimal)
        let r = NumberFormatter.localizedString(from: NSNumber(value: rows), number: .decimal)
        return t("異なる値が多すぎるため \(d) 種類で打ち切りました（ID のような列を指定していませんか？）。"
                 + "表の件数は正確ですが、打ち切り後に初めて出た値 \(r) 行は表に出ていません。",
                 "Stopped at \(d) distinct values — did you pick an ID-like column? "
                 + "The counts shown are exact, but \(r) rows whose value first appeared after the cut-off are not listed.")
    }

    // MARK: - 列の統計（C2）

    static let tabStats             = t("列の統計", "Column stats")
    static let tabSanity            = t("整合性チェック", "Sanity check")
    static let sanityNoIssues       = t("✓ 歪み・異常は検出されませんでした", "✓ No structure or type anomalies detected")
    static func sanityIssueCount(_ count: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return t("🚨 異常行: \(n) 件（ダブルクリックで該当行へジャンプ）",
                 "🚨 \(n) anomalous rows (double-click to jump to line)")
    }
    static let colSanityLine        = t("行番号", "Line")
    static let colSanityKind        = t("種別", "Kind")
    static let colSanityColumn      = t("列名", "Column")
    static let colSanityExpected    = t("期待値", "Expected")
    static let colSanityActual      = t("実際値", "Actual")
    static let colSanityPreview     = t("プレビュー", "Preview")
    static let kindColumnMismatch   = t("列数不一致", "Column mismatch")
    static let kindTypeContam       = t("型混入", "Type contamination")

    // MARK: - 異常行の編集ポップオーバー
    static func sanityEditTitle(line: Int) -> String {
        t("🚨 \(line) 行目の修正", "🚨 Edit line \(line)")
    }
    static let sanityReverify       = t("再検証", "Re-verify")
    static let sanityCancel         = t("キャンセル", "Cancel")
    static let sanityJumpToBody     = t("本文へジャンプ", "Jump to line")
    static func sanityColumnMismatchDetail(actual: String, expected: String) -> String {
        t("カラム数不一致: 実際 \(actual) / 期待 \(expected)",
          "Column mismatch: actual \(actual) / expected \(expected)")
    }
    static func sanityTypeContamDetail(col: String?, actual: String, expected: String) -> String {
        let prefix = col.map { t("列 [\($0)] ", "Column [\($0)] ") } ?? ""
        return t("型混入: \(prefix)実際 \(actual) / 期待 \(expected)",
                 "Type contamination: \(prefix)actual \(actual) / expected \(expected)")
    }
    static func sanityExtremeLengthDetail(actual: String) -> String {
        t("異常な行長: \(actual)", "Extreme line length: \(actual)")
    }

    static let colName      = t("列", "Column")
    static let colKind      = t("型", "Type")
    static let colPresent   = t("件数", "Values")
    static let colBlank     = t("空欄", "Blank")
    static let colDistinct  = t("ユニーク", "Unique")
    static let colMin       = t("最小", "Min")
    static let colMax       = t("最大", "Max")
    static let colSum       = t("合計", "Sum")
    static let colAverage   = t("平均", "Average")
    static let colTop       = t("代表値", "Top values")

    static let kindText     = t("文字列", "Text")
    static let kindNumber   = t("数値", "Number")
    static let kindDatetime = t("日時", "Date/time")
    static let kindMixed    = t("混在", "Mixed")
    static let kindEmpty    = t("空", "Empty")

    /// 合計が Int の桁を越えたとき。**近い数を出さずに、出せないと言う。**
    static let sumOverflow  = t("桁あふれ", "too large")
    static let needsStructured = t("列の統計は構造化表示（CSV / TSV / NDJSON）のときに出せます。"
                                   + "「表示 > 構造化表示」を入れてから、もう一度実行してください。",
                                   "Column stats need structured view (CSV / TSV / NDJSON). "
                                   + "Turn on View ▸ Structured view and run again.")
    /// 固定長（桁で区切る表示）。**「0 件」「空欄」ではなく「出せない」と言う。**
    /// 桁の定義は桁ガイド（`ColumnGuides`）側にあり、分析まで渡す口が core に無い。
    /// 走らせれば「全列が空」という、正しそうに見えて意味の無い表が出てしまう。
    static let fixedWidthUnsupported = t(
        "固定長（桁で区切る表示）の列には、まだ対応していません。CSV / TSV / NDJSON なら出せます。",
        "Fixed-width columns are not supported yet — CSV, TSV and NDJSON are.")
    static let inspectColumnHint = t("行をダブルクリック: 日時の列は時間分布、それ以外は値の集計",
                                     "Double-click a row: a date/time column opens the time histogram, any other counts its values")

    /// 「混在（数値 5,801,627 / それ以外 14,907）」。**内訳を必ず出す。**
    static func mixedBreakdown(numeric: Int, other: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: numeric), number: .decimal)
        let o = NumberFormatter.localizedString(from: NSNumber(value: other), number: .decimal)
        return t("混在（数値 \(n) / それ以外 \(o)）", "Mixed (\(n) numeric / \(o) other)")
    }

    /// 上限に達したユニーク数。**「約」ではなく「以上」**（推定はしていない）。
    static func distinctAtLeast(_ n: Int) -> String {
        let v = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return t("\(v)+", "\(v)+")
    }

    /// 「5,816,534 行 / 4.38 秒 / 31 列」。**丸めない。**
    static func columnStatsSummary(lines: Int, seconds: TimeInterval, columns: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: lines), number: .decimal)
        let sec = String(format: "%.2f", seconds)
        return t("\(n) 行 / \(sec) 秒 / \(columns) 列", "\(n) lines / \(sec) s / \(columns) columns")
    }

    // MARK: - 時間分布（C3）

    static let logScale     = t("対数", "Log scale")
    static let clearRange   = t("絞り込みを解除", "Clear range")
    static let rangeHint = t("棒をドラッグして時間帯を選ぶと、本文をその時間帯に絞れます",
                             "Drag across the bars to narrow the document to that time range")
    static let aggregateRange = t("この時間帯を集計", "Count this range")
    static let suppliedLabel = t("行に無い分を補う:", "Fill in what the line lacks:")
    static let noTimestamps = t("このファイルからは時刻を読み取れませんでした（対応: ISO8601 / syslog / Apache / epoch）。",
                                "No timestamps found (supported: ISO8601 / syslog / Apache / epoch).")

    static func formatLabel(_ format: TimestampFormat) -> String {
        let name: String
        switch format {
        case .iso8601:      name = "ISO8601"
        case .syslog:       name = "syslog"
        case .apache:       name = "Apache"
        case .epochSeconds: name = t("epoch 秒", "epoch seconds")
        case .epochMillis:  name = t("epoch ミリ秒", "epoch millis")
        }
        return t("形式: \(name)", "Format: \(name)")
    }

    /// 「ピーク 06-30 01:40 / 3,210,000 件」。**グラフだけにしない。**
    static func peakLabel(_ time: String, count: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return t("ピーク \(time) / \(n) 件", "Peak \(time) / \(n)")
    }

    /// 時刻を持たない行。**捨てずに数えたことを言う。**
    static func untimedLines(_ n: Int) -> String {
        let v = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return t("時刻なし \(v) 行", "\(v) lines without a timestamp")
    }

    static func rangeLabel(from: String, to: String, count: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        return t("\(from)–\(to) / \(n) 件", "\(from)–\(to) / \(n)")
    }

    static func histogramSummary(lines: Int, seconds: TimeInterval, bars: Int, width: Int) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: lines), number: .decimal)
        let sec = String(format: "%.2f", seconds)
        return t("\(n) 行 / \(sec) 秒 / \(bars) 本 × \(bucketWidthLabel(width))",
                 "\(n) lines / \(sec) s / \(bars) bars × \(bucketWidthLabel(width))")
    }

    static func bucketWidthLabel(_ seconds: Int) -> String {
        switch seconds {
        case ..<60:     return t("\(seconds) 秒", "\(seconds)s")
        case ..<3600:   return t("\(seconds / 60) 分", "\(seconds / 60)m")
        case ..<86400:  return t("\(seconds / 3600) 時間", "\(seconds / 3600)h")
        case ..<604800: return t("\(seconds / 86400) 日", "\(seconds / 86400)d")
        default:        return t("\(seconds / 604800) 週", "\(seconds / 604800)w")
        }
    }

    /// 目盛りの時刻。バケット幅に合わせて**必要な桁だけ**出す
    /// （1 時間刻みのグラフに秒まで出しても読めない）。
    static func timeLabel(_ epochSecond: Int, width: Int, offset: Int) -> String {
        let shifted = epochSecond + offset
        let days = Int(floor(Double(shifted) / 86400))
        let rest = shifted - days * 86400
        let (year, month, day) = TimestampDetector.civilFromDays(days)
        let hour = rest / 3600, minute = (rest % 3600) / 60, second = rest % 60
        if width >= 86400 {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        if width >= 60 {
            return String(format: "%02d-%02d %02d:%02d", month, day, hour, minute)
        }
        return String(format: "%02d:%02d:%02d", hour, minute, second)
    }

    // MARK: - 横断検索（C5）

    static let chooseFolders   = t("フォルダを選ぶ…", "Choose folders…")
    static let noFolders       = t("フォルダ未指定（ここへドラッグしても指定できます）",
                                   "No folder yet — you can also drop one here")
    static let needFolders     = t("先にフォルダを選んでください。", "Choose a folder first.")
    static let needQuery       = t("探す語を入れてください。", "Type something to search for.")
    static let invalidRegex    = t("正規表現が壊れています。", "That regular expression does not compile.")
    static let queryPlaceholder = t("探す語（空白で AND）", "words to find (space = AND)")
    static let searchAcross    = t("横断して探す", "Search")
    static let contextLines    = t("前後", "Context")
    static let respectGitignore = t(".gitignore を尊重", "Respect .gitignore")
    static let aggregateThisMatch = t("この一致を、このファイルで集計", "Count this match in this file")
    static let aggregateHitHint = t("結果を右クリック: 検索した式で、そのファイルの一致を値ごとに集計します",
                                    "Right-click a result: count what the expression matched in that file, by value")
    static let noMatches       = t("一致はありませんでした。", "No matches.")

    static func fileRow(_ name: String, matches: Int, encoding: String) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: matches), number: .decimal)
        return t("\(name)  —  \(n) 件  ·  \(encoding)", "\(name)  —  \(n)  ·  \(encoding)")
    }

    /// バイナリは読まずに飛ばす。**飛ばしたことを言う**（黙って減らさない）。
    static func skippedBinary(_ n: Int) -> String {
        let v = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return t("バイナリ \(v) 個は読み飛ばしました", "Skipped \(v) binary files")
    }

    /// 上限。**丸めた数を言わない**（検索バーの既定作法と同じ）。
    static func crossSearchCapped(_ cap: Int) -> String {
        let v = NumberFormatter.localizedString(from: NSNumber(value: cap), number: .decimal)
        return t("一致行が \(v) 件を超えたので、そこで打ち切りました",
                 "Stopped after \(v) matching lines")
    }

    static func crossSearchProgress(files: Int, lines: Int) -> String {
        let f = NumberFormatter.localizedString(from: NSNumber(value: files), number: .decimal)
        let l = NumberFormatter.localizedString(from: NSNumber(value: lines), number: .decimal)
        return t("\(f) ファイル / \(l) 行…", "\(f) files / \(l) lines…")
    }

    static func crossSearchSummary(files: Int, lines: Int, scanned: Int,
                                   seconds: TimeInterval, capped: Bool) -> String {
        let f = NumberFormatter.localizedString(from: NSNumber(value: files), number: .decimal)
        let l = NumberFormatter.localizedString(from: NSNumber(value: lines), number: .decimal)
        let s = NumberFormatter.localizedString(from: NSNumber(value: scanned), number: .decimal)
        let sec = String(format: "%.2f", seconds)
        let plus = capped ? "+" : ""
        return t("\(f) ファイル / \(l)\(plus) 行 / \(s) ファイルを見て \(sec) 秒",
                 "\(f) files / \(l)\(plus) lines / scanned \(s) files in \(sec) s")
    }

    /// 「8,642万行 / 3.32 秒」。**丸めない**（端数のある実測値が信用を作る）。
    static func scanSummary(lines: Int, seconds: TimeInterval) -> String {
        let n = NumberFormatter.localizedString(from: NSNumber(value: lines), number: .decimal)
        let sec = String(format: "%.2f", seconds)
        return t("\(n) 行 / \(sec) 秒", "\(n) lines / \(sec) s")
    }

    // MARK: - ビュープリセット（C9）

    static let viewPresetApply       = t("適用", "Apply")
    static let viewPresetRename      = t("名前を変更…", "Rename…")
    static let viewPresetDelete      = t("削除", "Delete")
    static let viewPresetSaveCurrent = t("現在の表示を保存…", "Save current view…")
    static let viewPresetSaveTitle   = t("ビュープリセットを保存", "Save view preset")
    static let viewPresetSaveMessage = t("この列構成の並び順と幅に名前を付けます。",
                                         "Name this column order and width layout.")
    static let viewPresetRenameTitle = t("プリセット名を変更", "Rename preset")
    static let viewPresetNamePlaceholder = t("名前", "Name")
    static let viewPresetSave        = t("保存", "Save")
    static let viewPresetCancel      = t("キャンセル", "Cancel")
    static let viewPresetNoDocument  = t("構造化表示中のドキュメントがありません",
                                         "No document is showing a structured view.")

}
