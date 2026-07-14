import AppKit

/// 2 つのソースを並べて差分を見るペイン。
///
/// 巨大ファイルの流儀をそのまま踏襲する: **見えている行しか組み立てない**。
/// 差分の手（`DiffModel`）は行を実体化せず、画面に出る数十行だけをその場で左右に組む。
/// 8,600 万行の diff でも、描画側が持つのは 1 画面分の `NSAttributedString` だけ。
///
/// 読み取り専用。編集・検索・追従は持たない（`DocumentPane` の既定実装に委ねる）。
final class DiffViewer: NSView, DocumentPane {

    // MARK: - DocumentPane

    /// diff は特定の 1 ファイルに属さない（左右 2 つある）。サイドバー名は `displayTitle` を使う。
    var fileURL: URL? { nil }
    var onStateChange: ((ViewerState) -> Void)?
    var onSearchState: ((Int, Int, Bool, Int, Bool) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var onDirtyChange: ((Bool) -> Void)?

    var supportsSearch: Bool { false }
    var supportsFollow: Bool { false }
    var supportsStructured: Bool { false }
    var canPrint: Bool { false }
    func printDocument() {}

    /// サイドバーとタイトルに出す名前。
    private(set) var displayTitle: String = "Diff"

    // MARK: - 中身

    private let leftView = DocumentView()
    private let rightView = DocumentView()
    private let scroller = DiffScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))
    private let header = NSView()
    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let gutter = MergeGutter()

    private var left: DiffSource?
    private var right: DiffSource?
    private var model: DiffModel?

    private var topRow = 0
    private var scrollAccumulator: CGFloat = 0
    private let scrollerWidth: CGFloat = 16
    private let headerHeight: CGFloat = 28

    /// 行内差分のキャッシュ（可視行のぶんだけ。スクロールで捨てる）。
    private var charDiffCache: [Int: (left: [Range<Int>], right: [Range<Int>])] = [:]

    // MARK: - 選択（片方の列の中だけ。左右にまたがる選択は意味を成さない）

    private enum Side { case left, right }
    /// 選択の起点と終点。表示行（絶対）と行内 UTF-16 オフセットで持つ。
    private var selSide: Side?
    private var selAnchor: (row: Int, idx: Int)?
    private var selFocus: (row: Int, idx: Int)?

    // MARK: - マージ（左が土台。採用したハンクだけ右を採る）

    /// 適用したハンク（`DiffModel.ops` 上の添字）。矢印（→）＝左の内容を右へ持っていく。
    /// 空なら「右のまま」。
    private var adopted: Set<Int> = []
    /// いま選んでいるハンク（⌥→ で採用/取り消しする対象）。
    private var currentHunkOp: Int?

    /// 採用した行の帯（左は「消える／置き換わる」、右は「入る」）。
    private var adoptedBG: NSColor { NSColor.systemBlue.withAlphaComponent(0.35) }
    /// 採用していないハンクのうち、いま選んでいるもの。
    private var currentHunkBG: NSColor { NSColor.systemTeal.withAlphaComponent(0.10) }

    private func view(_ side: Side) -> DocumentView { side == .left ? leftView : rightView }
    private func source(_ side: Side) -> DiffSource? { side == .left ? left : right }

    /// その行の、その列に出ている文字列（相手側にしか無い行なら空）。
    private func text(_ side: Side, row: Int) -> String {
        guard let model, let r = model.row(at: row), let src = source(side) else { return "" }
        let line = side == .left ? r.left : r.right
        return line.map { src.line(at: $0) } ?? ""
    }

    // MARK: - 色（テーマの背景に馴染ませる。ライト/ダークどちらでも読める濃度にする）

    private var addBG: NSColor { NSColor.systemGreen.withAlphaComponent(0.16) }
    private var delBG: NSColor { NSColor.systemRed.withAlphaComponent(0.16) }
    private var modBG: NSColor { NSColor.systemYellow.withAlphaComponent(0.14) }
    /// 相手側に行が無いところ（空白で埋める側）。中身が無いことを示す薄いグレー。
    private var fillerBG: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.07) }
    /// 行内で実際に変わった文字。帯より濃く塗る。
    private var addInline: NSColor { NSColor.systemGreen.withAlphaComponent(0.38) }
    private var delInline: NSColor { NSColor.systemRed.withAlphaComponent(0.38) }

    // MARK: - 組み立て

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let theme = EditorTheme.current()

        header.wantsLayer = true
        header.layer?.backgroundColor = theme.chromeBackground.cgColor
        addSubview(header)
        for (label, align) in [(leftLabel, NSTextAlignment.left), (rightLabel, .left)] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = theme.chromeText
            label.alignment = align
            header.addSubview(label)
        }
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = theme.chromeSecondaryText
        summary.alignment = .right
        header.addSubview(summary)

        gutter.onToggle = { [weak self] op in self?.toggleHunk(op) }
        addSubview(gutter)

        for (v, side) in [(leftView, Side.left), (rightView, Side.right)] {
            // 隣のカラムへはみ出させない（折り返し無しの長い行も、背景の塗りも）。
            v.clipsToBounds = true
            v.onScrollWheel = { [weak self] in self?.handleScrollWheel($0) }
            v.onKeyDown = { [weak self] in self?.handleKeyDown($0) }
            v.onMouseDown = { [weak self] in self?.beginSelection(side, $0) }
            v.onMouseDragged = { [weak self] in self?.extendSelection(side, $0) }
            v.onCopy = { [weak self] in self?.copySelection() }
            v.onSelectAll = { [weak self] in self?.selectAll(side) }
            addSubview(v)
        }

        scroller.scrollerStyle = .legacy
        scroller.knobStyle = .default
        scroller.target = self
        scroller.action = #selector(scrollerAction(_:))
        addSubview(scroller)

        applyCurrentFontSize()
        applyDisplaySettings()
    }

    // MARK: - 入口

    /// 比較を始める（**メインスレッドから呼ぶ**）。ソースの用意と diff の計算は背景で走らせ、
    /// 済んだらメインで描画する。10GB 同士だと索引と diff で数十秒かかるので、
    /// ここを同期にするとウィンドウが固まる（実際に固めた）。
    ///
    /// `makeSources` は**背景スレッドで呼ばれる**。ここで mmap と索引を作る。
    func beginCompare(title: String,
                      makeSources: @escaping () -> (DiffSource, DiffSource)?,
                      onFailure: @escaping (String) -> Void) {
        displayTitle = title
        summary.stringValue = L("diff.comparing")
        leftLabel.stringValue = ""
        rightLabel.stringValue = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let sources = makeSources() else {
                DispatchQueue.main.async { onFailure(L("diff.cannotRead")) }
                return
            }
            let (l, r) = sources

            // 索引は 1 行 16 バイト。閲覧と違い本当にメモリを使うので、機械に載るか先に見る。
            guard DiffBudget.fits(leftLines: l.lineCount, rightLines: r.lineCount) else {
                let msg = DiffBudget.describe(leftLines: l.lineCount, rightLines: r.lineCount)
                DispatchQueue.main.async { onFailure(msg) }
                return
            }

            let ops = LineDiff.compute(l.lineHashes(), r.lineHashes())
            let m = DiffModel(ops: ops)

            DispatchQueue.main.async {
                guard let self else { return }
                self.left = l
                self.right = r
                self.model = m
                self.displayTitle = "\(l.displayName) ↔ \(r.displayName)"
                self.leftLabel.stringValue = l.displayName
                self.rightLabel.stringValue = r.displayName
                self.charDiffCache.removeAll()
                self.adopted.removeAll()
                self.currentHunkOp = m.hunkOpIndices.first
                // 最初の差分まで飛ぶ（先頭が数万行同じ、はログでは普通）。
                self.topRow = m.hunkStarts.first.map { max(0, $0 - 3) } ?? 0
                self.scroller.markers = m.markers().map {
                    DiffScroller.Marker(position: $0.position, kind: {
                        switch $0.kind {
                        case .delete:  return .delete
                        case .insert:  return .insert
                        default:       return .replace
                        }
                    }($0))
                }
                self.refresh()
                self.onCompared?()
            }
        }
    }

    /// 比較が終わったときの通知（サイドバー名の更新用）。
    var onCompared: (() -> Void)?

    @discardableResult func open(url: URL) -> Bool { false }   // diff ペインは compare(_:_:) で作る

    // MARK: - 描画（見えている行だけ組む）

    private var visibleRowCount: Int {
        max(1, Int((bounds.height - headerHeight) / max(1, leftView.lineHeight)))
    }
    private var maxTopRow: Int { max(0, (model?.rowCount ?? 0) - visibleRowCount) }

    private func refresh() {
        guard let model, let left, let right else { return }
        topRow = min(max(0, topRow), maxTopRow)

        let count = min(visibleRowCount, max(0, model.rowCount - topRow))
        var lTexts: [NSAttributedString] = [], rTexts: [NSAttributedString] = []
        var lNums: [Int] = [], rNums: [Int] = []
        var lBGs: [NSColor?] = [], rBGs: [NSColor?] = []
        lTexts.reserveCapacity(count); rTexts.reserveCapacity(count)

        for k in 0..<count {
            let rowIdx = topRow + k
            guard let row = model.row(at: rowIdx) else { break }

            let op = model.opIndex(at: rowIdx)
            let isAdopted = op.map { adopted.contains($0) } ?? false

            // **右が結果。** 矢印（→）を押した差分は、その場で右の中身が左に入れ替わる。
            // 印だけ覚えて保存時に適用する方式では画面が変わらず、「マージされない」と
            // 言われる（実際に言われた）。見えないものは、無いのと同じ。
            let lStr = row.left.map { left.line(at: $0) } ?? ""
            var rStr = row.right.map { right.line(at: $0) } ?? ""
            var rStruck = false          // 適用した insert＝右から落ちる行（打ち消し線で見せる）
            switch row.kind {
            case .replace where isAdopted:
                rStr = lStr                                  // 左の内容に置き換わった
            case .delete where isAdopted:
                rStr = lStr                                  // 左にしかない行が右へ入った
            case .insert where isAdopted:
                rStruck = true                               // 左に合わせて落とす
            default:
                break
            }

            // 行内差分は「変更行」だけ。可視分しか計算しない。
            var lRanges: [Range<Int>] = [], rRanges: [Range<Int>] = []
            if row.kind == .replace, !isAdopted, row.left != nil, row.right != nil {
                if let cached = charDiffCache[rowIdx] {
                    lRanges = cached.left; rRanges = cached.right
                } else {
                    let d = CharDiff.ranges(left: lStr, right: rStr)
                    charDiffCache[rowIdx] = d
                    lRanges = d.left; rRanges = d.right
                }
            }

            lTexts.append(attributed(lStr, inline: lRanges, color: delInline))
            rTexts.append(attributed(rStr, inline: rRanges, color: addInline, struck: rStruck))
            lNums.append(row.left ?? DocumentView.noLineNumber)
            rNums.append(row.right ?? DocumentView.noLineNumber)

            let isCurrent = op != nil && op == currentHunkOp

            switch row.kind {
            case .equal:
                lBGs.append(nil); rBGs.append(nil)
            case .delete:
                // 適用＝左にしかない行を右へ持っていく（右の空白が埋まる）。
                lBGs.append(delBG)
                rBGs.append(isAdopted ? adoptedBG : fillerBG)
            case .insert:
                // 適用＝右にしかない行を落とす（左に合わせる）。
                lBGs.append(fillerBG)
                rBGs.append(isAdopted ? adoptedBG : addBG)
            case .replace:
                lBGs.append(row.left == nil ? fillerBG : (isAdopted ? adoptedBG : modBG))
                rBGs.append(row.right == nil ? fillerBG : (isAdopted ? adoptedBG : modBG))
            }
            // 選んでいるハンクは、採用していなくても分かるように薄く重ねる。
            if isCurrent, !isAdopted, row.kind != .equal {
                if lBGs[k] == nil { lBGs[k] = currentHunkBG }
                if rBGs[k] == nil { rBGs[k] = currentHunkBG }
            }
        }

        leftView.lines = lTexts;   rightView.lines = rTexts
        leftView.lineNumbers = lNums; rightView.lineNumbers = rNums
        leftView.rowBackgrounds = lBGs; rightView.rowBackgrounds = rBGs
        let visible = topRow..<(topRow + count)
        leftView.selectionByRow = selectionRows(.left, visible: visible)
        rightView.selectionByRow = selectionRows(.right, visible: visible)

        // マージ帯: ハンクの**先頭行**にだけ矢印を出す。
        var gutterRows: [MergeGutter.Row] = []
        gutterRows.reserveCapacity(count)
        var lastOp: Int? = topRow > 0 ? model.opIndex(at: topRow - 1) : nil
        for k in 0..<count {
            let rowIdx = topRow + k
            let op = model.opIndex(at: rowIdx)
            let isDiff = op.map { if case .equal = model.ops[$0] { return false } else { return true } } ?? false
            let isHead = isDiff && op != lastOp
            gutterRows.append(MergeGutter.Row(
                hunkOp: isDiff ? op : nil,      // ハンクの全行で押せる（先頭行だけだと外れる）
                isHead: isHead,                 // 矢印は先頭行にだけ描く
                adopted: op.map { adopted.contains($0) } ?? false,
                current: op != nil && op == currentHunkOp))
            lastOp = op
        }
        gutter.rows = gutterRows
        gutter.lineHeight = leftView.lineHeight
        gutter.window?.invalidateCursorRects(for: gutter)
        updateSummary()
        leftView.needsDisplay = true; rightView.needsDisplay = true

        // キャッシュは可視付近だけ残す（延々スクロールしても太らない）。
        if charDiffCache.count > 2_000 {
            let keep = topRow..<(topRow + count)
            charDiffCache = charDiffCache.filter { keep.contains($0.key) }
        }

        updateScroller()
        emitState()
    }

    /// 行内で変わった文字だけを濃く塗った 1 行。`struck` は結果から落ちる行（打ち消し線）。
    private func attributed(_ s: String, inline: [Range<Int>], color: NSColor,
                            struck: Bool = false) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: s, attributes: leftView.textAttributes)
        if struck {
            attr.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                .strikethroughColor: NSColor.systemRed],
                               range: NSRange(location: 0, length: attr.length))
        }
        guard !inline.isEmpty else { return attr }
        let chars = Array(s)
        for r in inline {
            guard r.lowerBound >= 0, r.upperBound <= chars.count, r.lowerBound < r.upperBound else { continue }
            // Character 単位の範囲 → UTF-16 の範囲へ（絵文字を割らない）。
            let pre = String(chars[0..<r.lowerBound]).utf16.count
            let len = String(chars[r.lowerBound..<r.upperBound]).utf16.count
            let ns = NSRange(location: pre, length: len)
            if ns.location + ns.length <= attr.length {
                attr.addAttribute(.backgroundColor, value: color, range: ns)
            }
        }
        return attr
    }

    /// ヘッダの要約。**適用した数を出す** ―― 行の色だけだと配色テーマによっては気づけない。
    private func updateSummary() {
        guard let model else { return }
        let base = model.isIdentical
            ? L("diff.identical")
            : L("diff.summary", model.hunkStarts.count, model.changedRowCount)
        summary.stringValue = adopted.isEmpty ? base : base + " ／ " + L("diff.adopted", adopted.count)
    }

    private func emitState() {
        guard let model else { return }
        // ファイルサイズの欄は diff では意味がない（左右 2 つある）。差分の要約を出す。
        let label = model.isIdentical
            ? L("diff.identical")
            : L("diff.summary", model.hunkStarts.count, model.changedRowCount)
        onStateChange?(ViewerState(encodingName: label,
                                   lineCount: model.rowCount,
                                   lineCountIsExact: true,
                                   fileSize: 0,
                                   indexProgress: 1.0))
    }

    // MARK: - 選択とコピー

    /// クリックした列で選択を始める。もう片方の列の選択は捨てる
    /// （左右にまたがる選択は「並べて比べる」画面では意味を成さない）。
    private func beginSelection(_ side: Side, _ event: NSEvent) {
        let v = view(side)
        let p = v.convert(event.locationInWindow, from: nil)
        guard let hit = v.index(at: p) else { return }
        let row = topRow + hit.row
        if event.modifierFlags.contains(.shift), selSide == side, selAnchor != nil {
            selFocus = (row, hit.utf16Index)          // Shift+クリックで範囲を伸ばす
        } else {
            selSide = side
            selAnchor = (row, hit.utf16Index)
            selFocus = (row, hit.utf16Index)
            selectHunk(at: row)                       // クリックした差分を採用の対象にする
        }
        window?.makeFirstResponder(v)
        refresh()
    }

    private func extendSelection(_ side: Side, _ event: NSEvent) {
        guard selSide == side else { return }
        let v = view(side)
        let p = v.convert(event.locationInWindow, from: nil)
        guard let hit = v.index(at: p) else { return }
        selFocus = (topRow + hit.row, hit.utf16Index)
        refresh()
    }

    /// その列の全行を選ぶ。巨大ファイルでも選択自体は範囲を持つだけなので安い
    /// （コピーするときに初めて行を読む）。
    private func selectAll(_ side: Side) {
        guard let model, model.rowCount > 0 else { return }
        selSide = side
        selAnchor = (0, 0)
        let last = model.rowCount - 1
        selFocus = (last, text(side, row: last).utf16.count)
        refresh()
    }

    /// 選択の正規化（起点 ≤ 終点）。
    private func normalizedSelection() -> (start: (row: Int, idx: Int), end: (row: Int, idx: Int))? {
        guard let a = selAnchor, let f = selFocus else { return nil }
        if a.row < f.row || (a.row == f.row && a.idx <= f.idx) { return (a, f) }
        return (f, a)
    }

    /// 選択されている本文をクリップボードへ。相手側にしか無い行（空白で埋めた行）は飛ばす
    /// ―― 存在しない行をコピーして空行を混ぜたら、貼り付け先で嘘になる。
    private func copySelection() {
        guard let side = selSide, let model, let sel = normalizedSelection() else { NSSound.beep(); return }
        let text = model.selectedText(from: sel.start, to: sel.end) { [weak self] row in
            guard let self, let r = model.row(at: row) else { return nil }
            let exists = (side == .left) ? r.left != nil : r.right != nil
            return exists ? self.text(side, row: row) : nil    // 埋め草の行は nil＝飛ばす
        }
        guard !text.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 可視行の選択ハイライトを組む（DocumentView に渡す形へ）。
    private func selectionRows(_ side: Side, visible: Range<Int>) -> [Int: DocumentView.RowSelection] {
        guard selSide == side, let sel = normalizedSelection() else { return [:] }
        var out: [Int: DocumentView.RowSelection] = [:]
        for row in visible where row >= sel.start.row && row <= sel.end.row {
            let u = text(side, row: row).utf16.count
            let from = (row == sel.start.row) ? min(sel.start.idx, u) : 0
            let to   = (row == sel.end.row)   ? min(sel.end.idx, u)   : u
            guard from <= to else { continue }
            out[row - visible.lowerBound] = DocumentView.RowSelection(
                range: NSRange(location: from, length: to - from),
                extendsToLineEnd: row < sel.end.row)     // 行をまたぐ選択は行末まで帯を伸ばす
        }
        return out
    }

    // MARK: - 差分間の移動

    /// 次の差分へ。移動先を「選んでいるハンク」にする（⌥→ の対象になる）。
    func nextHunk() { goToHunk(model?.hunk(after: currentHunkOp)) }
    /// 前の差分へ。
    func previousHunk() { goToHunk(model?.hunk(before: currentHunkOp)) }

    private func goToHunk(_ op: Int?) {
        guard let model, let op else { NSSound.beep(); return }
        currentHunkOp = op
        let row = model.startRow(ofOp: op)
        // 画面外なら寄せる。見えているならスクロールしない（目が飛ばない）。
        if row < topRow || row >= topRow + visibleRowCount - 1 {
            topRow = max(0, row - 3)
        }
        refresh()
    }

    // MARK: - マージ

    /// 選んでいるハンクがあるか（メニューの有効化）。
    var hasCurrentHunk: Bool { currentHunkOp != nil }
    /// 採用したハンクがあるか（「マージして保存」の有効化）。
    var hasAdoptedHunks: Bool { !adopted.isEmpty }

    /// 選んでいるハンクで、右の内容を採用する（左が土台）。
    func adoptCurrentHunk() {
        guard let op = currentHunkOp else { NSSound.beep(); return }
        adopted.insert(op)
        refresh()
    }

    /// 採用を取り消す（左のままに戻す）。
    func revertCurrentHunk() {
        guard let op = currentHunkOp else { NSSound.beep(); return }
        adopted.remove(op)
        refresh()
    }

    /// 矢印を押したとき: 採用していなければ採用し、していれば取り消す。
    private func toggleHunk(_ op: Int) {
        currentHunkOp = op
        if adopted.contains(op) { adopted.remove(op) } else { adopted.insert(op) }
        refresh()
    }

    /// クリックしたハンクを「選んでいるハンク」にする。
    private func selectHunk(at row: Int) {
        guard let model, let op = model.opIndex(at: row) else { return }
        if case .equal = model.ops[op] { return }     // 差分でない行は選ばない
        currentHunkOp = op
    }

    /// マージ結果を別名で保存する。**元の 2 ファイルには触らない。**
    ///
    /// 本文をメモリに載せず、ops を辿って左右のソースからバイトを流す（10GB でも成立する）。
    func saveMerged() {
        guard let model, let left, let right else { NSSound.beep(); return }

        let panel = NSSavePanel()
        panel.message = L("diff.saveMergedMessage")
        panel.prompt = L("diff.saveMerged")
        panel.nameFieldStringValue = mergedFileName()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let adoptedNow = adopted
        let eol: [UInt8] = [0x0A]        // 出力は LF。混在させない。

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let out = try FileHandle(forWritingTo: url)
            defer { try? out.close() }
            try model.writeMerged(left: left, right: right, applied: adoptedNow, eol: eol, to: out)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("diff.saveFailed")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        onMergedSaved?(url)
    }

    /// マージ結果を保存したときの通知（開いて見せるため）。
    var onMergedSaved: ((URL) -> Void)?

    /// 「元のファイル名-merged.拡張子」を作る。
    private func mergedFileName() -> String {
        let base = right?.displayName ?? "merged.txt"
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem)-merged" : "\(stem)-merged.\(ext)"
    }

    /// 左右のカラムを同じ水平位置に保つ。
    private func setHorizontalOffset(_ x: CGFloat) {
        leftView.setHorizontalOffset(x)
        rightView.setHorizontalOffset(leftView.horizontalOffset)   // クランプ後の値で揃える
    }

    private func handleKeyDown(_ event: NSEvent) {
        let step = leftView.lineHeight * 4
        // ⌥→ で右を採用、⌥← で取り消し（マージ）。⌥無しは水平スクロール。
        if event.modifierFlags.contains(.option) {
            switch event.keyCode {
            case 124: adoptCurrentHunk(); return      // ⌥→
            case 123: revertCurrentHunk(); return     // ⌥←
            default: break
            }
        }
        switch event.keyCode {
        case 123: setHorizontalOffset(leftView.horizontalOffset - step); return   // ←
        case 124: setHorizontalOffset(leftView.horizontalOffset + step); return   // →
        default: break
        }
        switch event.keyCode {
        case 125: topRow += 1; refresh()                       // ↓
        case 126: topRow -= 1; refresh()                       // ↑
        case 121: topRow += visibleRowCount - 1; refresh()     // PageDown
        case 116: topRow -= visibleRowCount - 1; refresh()     // PageUp
        case 115: topRow = 0; refresh()                        // Home
        case 119: topRow = maxTopRow; refresh()                // End
        default: break
        }
    }

    private func handleScrollWheel(_ event: NSEvent) {
        // 横は左右そろえて動かす。片方だけずれたら「並べて比べる」が成立しない。
        if event.scrollingDeltaX != 0 {
            setHorizontalOffset(leftView.horizontalOffset - event.scrollingDeltaX)
        }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= leftView.lineHeight }
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator / leftView.lineHeight)
        if lines != 0 {
            scrollAccumulator -= CGFloat(lines) * leftView.lineHeight
            topRow -= lines
            refresh()
        }
    }

    @objc private func scrollerAction(_ sender: NSScroller) {
        let page = max(1, visibleRowCount - 1)
        switch sender.hitPart {
        case .knob, .knobSlot: topRow = Int(Double(maxTopRow) * sender.doubleValue)
        case .decrementPage: topRow -= page
        case .incrementPage: topRow += page
        case .decrementLine: topRow -= 1
        case .incrementLine: topRow += 1
        default: break
        }
        refresh()
    }

    private func updateScroller() {
        let total = model?.rowCount ?? 0
        scroller.isEnabled = total > visibleRowCount
        scroller.knobProportion = total > 0 ? CGFloat(visibleRowCount) / CGFloat(total) : 1
        scroller.doubleValue = maxTopRow > 0 ? Double(topRow) / Double(maxTopRow) : 0
    }

    // MARK: - レイアウト

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        header.frame = NSRect(x: 0, y: h - headerHeight, width: w, height: headerHeight)
        let gutterW: CGFloat = 30
        let colW = max(0, (w - scrollerWidth - gutterW) / 2)
        leftLabel.frame = NSRect(x: 10, y: 5, width: colW - 20, height: 18)
        rightLabel.frame = NSRect(x: colW + 40, y: 5, width: max(0, colW - 160), height: 18)
        summary.frame = NSRect(x: w - scrollerWidth - 240, y: 5, width: 230, height: 18)

        let bodyH = max(0, h - headerHeight)
        leftView.frame = NSRect(x: 0, y: 0, width: colW, height: bodyH)
        gutter.frame = NSRect(x: colW, y: 0, width: gutterW, height: bodyH)
        rightView.frame = NSRect(x: colW + gutterW, y: 0, width: colW, height: bodyH)
        scroller.frame = NSRect(x: w - scrollerWidth, y: 0, width: scrollerWidth, height: bodyH)
        refresh()
    }

    // MARK: - DocumentPane の残り

    func reEmitState() { emitState() }
    func focusContent() { window?.makeFirstResponder(leftView) }
    func ensureVisibleLayout() { refresh() }

    func applyCurrentFontSize() {
        for v in [leftView, rightView] { v.configure(font: EditorFont.current()) }
        needsLayout = true
        refresh()
    }
    func applyLineWrap() {
        // diff は左右の行を突き合わせて見るもの。折り返すと行が縦にずれて対応が崩れるので、
        // 折り返しは常に無効（横スクロールで見る）。
        for v in [leftView, rightView] { v.wrapEnabled = false }
        refresh()
    }
    func applyDisplaySettings() {
        for v in [leftView, rightView] {
            v.highlightCurrentLine = false      // diff の帯と喧嘩する
            v.cursorShape = AppSettings.cursorShape
            v.configure(font: EditorFont.current())   // タブ幅・行間・配色を織り込む
        }
        refresh()
    }
}
