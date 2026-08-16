import AppKit

/// 小ファイル編集用 `NSTextView` の派生。標準の機能（IME・アンドゥ・選択）は
/// そのままに、キャレット形状と現在行ハイライトだけを config 連動で差し替える。
/// 加えてマルチカーソル（⌘クリック／⌥⌘↑↓／⌘D）を載せる。複数キャレットの実体は
/// NSTextView が元から持つ `selectedRanges`（不連続選択）で、範囲計算は `MultiCursor`。
final class EditorTextView: NSTextView {
    var cursorShape: CursorShape = AppSettings.cursorShape
    var highlightCurrentLine: Bool = AppSettings.highlightCurrentLine
    /// 不可視文字（タブ・改行・全角スペース・行末の半角スペース）を記号で見せるか。
    var showInvisibles: Bool = AppSettings.showInvisibles

    private var caretWidth: CGFloat {
        EditorStyle.caretWidth(for: font ?? EditorFont.current())
    }

    // MARK: - 現在行ハイライト

    /// 桁ガイド線を引く桁（1 始まり）。空なら描かない。桁の計算は `ColumnRuler` と共有する。
    var columnGuides = ColumnGuides() { didSet { if columnGuides != oldValue { needsDisplay = true } } }
    /// ガイド線を伏せる（構造化表示中）。**定義は生の本文の桁**なので、整形後の表示に
    /// 重ねると別の場所を指す。定義そのものは消さずに描画だけ止める。
    var columnGuidesHidden = false { didSet { if columnGuidesHidden != oldValue { needsDisplay = true } } }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCurrentLineHighlight(in: rect)
        drawColumnGuides(in: rect)
    }

    /// 桁ガイド線。**本文より下（背景段階）に描く。** 小ファイル側は文字の描画を
    /// AppKit に任せているので、後から重ねる口が無い代わりに帯に消される心配も無い。
    private func drawColumnGuides(in rect: NSRect) {
        guard !columnGuides.isEmpty, !columnGuidesHidden,
              let tc = textContainer, !tc.widthTracksTextView else { return }
        let width = EditorStyle.columnWidth(for: font ?? EditorFont.current())
        let originX = textContainerOrigin.x + tc.lineFragmentPadding
        let theme = EditorTheme.current()

        // 項目を 1 つおきに薄く塗る。**線を引いた瞬間に列が立ち上がって見える**のがこれ。
        // 整形はしない（固定長は元から桁が揃っている）ので、本文は編集できるまま。
        // **塗るのはデータのある桁まで。** 画面の右端まで塗ると、線を 1 本引いただけで
        // 「右半分が塗られた」に見えて、列に見えない。本文がどこまであるかは
        // AppKit が既に測っているので、それを使う（自分で全行を数え直さない）。
        var lastVisible = ColumnRuler.column(atX: rect.maxX - originX, columnWidth: width)
        if let lm = layoutManager {
            let used = lm.usedRect(for: tc).width - tc.lineFragmentPadding * 2
            lastVisible = min(lastVisible, ColumnRuler.column(atX: used, columnWidth: width))
        }
        theme.columnGuide(alpha: 0.13).setFill()
        for span in columnGuides.stripes(upTo: lastVisible) {
            let x0 = originX + ColumnRuler.x(ofColumn: span.lowerBound, columnWidth: width)
            let x1 = originX + ColumnRuler.x(ofColumn: span.upperBound + 1, columnWidth: width)
            NSRect(x: x0, y: rect.minY, width: max(0, x1 - x0), height: rect.height).fill()
        }

        theme.columnGuide(alpha: 0.45).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for col in columnGuides.columns {
            let x = floor(originX + ColumnRuler.x(ofColumn: col, columnWidth: width)) + 0.5
            guard x >= rect.minX - 1, x <= rect.maxX + 1 else { continue }
            path.move(to: NSPoint(x: x, y: rect.minY))
            path.line(to: NSPoint(x: x, y: rect.maxY))
        }
        path.stroke()
    }

    /// 記号は**本文とその選択ハイライトを描いた後**に重ねる。背景段階で描くと、
    /// 選択した瞬間に選択の帯へ塗り潰されて記号が消える（実機で発覚）。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showInvisibles { drawInvisibles(in: dirtyRect) }
        drawExtraCarets()
    }

    deinit { caretBlinkTimer?.invalidate() }

    // MARK: - テスト用フック（マルチカーソルは selectedRanges に載らないので専用の口が要る）

    func _testSetCarets(_ ranges: [NSRange]) { applyCarets(ranges) }
    var _testCarets: [NSRange] { carets.isEmpty ? [selectedRange()] : carets }

    private func drawCurrentLineHighlight(in rect: NSRect) {
        guard highlightCurrentLine, selectedRange().length == 0,
              let lm = layoutManager, let tc = textContainer else { return }
        let len = (string as NSString).length
        let loc = min(selectedRange().location, len)
        let glyph = lm.glyphIndexForCharacter(at: loc)
        var frag: NSRect
        if lm.numberOfGlyphs == 0 {
            frag = lm.extraLineFragmentRect            // 空ドキュメント
        } else {
            frag = lm.lineFragmentRect(forGlyphAt: min(glyph, lm.numberOfGlyphs - 1), effectiveRange: nil)
        }
        frag.origin.x = 0
        frag.size.width = bounds.width
        frag = frag.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        _ = tc
        EditorTheme.current().currentLine.setFill()
        frag.fill()
    }

    // MARK: - 不可視文字

    /// 可視範囲の行を走査し、タブ・全角スペース・行末スペース・改行の位置へ記号を重ねる。
    /// **本文は書き換えない**（置換するとタブの桁揃えも選択位置も崩れるため）。
    private func drawInvisibles(in rect: NSRect) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let text = string as NSString
        guard text.length > 0 else { return }

        let font = EditorFont.current()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: EditorTheme.current().chromeSecondaryText.withAlphaComponent(0.7),
        ]
        let origin = textContainerOrigin
        let glyphRange = lm.glyphRange(forBoundingRect: rect, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        /// 文字位置 `index` のグリフ矩形（ビュー座標）。
        func glyphRect(_ index: Int) -> NSRect {
            let g = lm.glyphIndexForCharacter(at: index)
            return lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
                .offsetBy(dx: origin.x, dy: origin.y)
        }

        var lineStart = text.lineRange(for: NSRange(location: charRange.location, length: 0)).location
        while lineStart < min(NSMaxRange(charRange) + 1, text.length) {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            // 改行を除いた本文部分（記号の算出は改行なしの1行に対して行う）。
            let contentEnd = NSMaxRange(lineRange)
            var end = contentEnd
            while end > lineStart, isNewline(text.character(at: end - 1)) { end -= 1 }

            let line = text.substring(with: NSRange(location: lineStart, length: end - lineStart))
            for marker in InvisibleGlyphs.markers(in: line) {
                let r = glyphRect(lineStart + marker.utf16Index)
                NSAttributedString(string: marker.glyph, attributes: attrs)
                    .draw(at: NSPoint(x: r.minX, y: r.minY))
            }
            // 改行記号（この行が改行で終わっているときだけ）。
            if end < contentEnd {
                let r = glyphRect(end)
                NSAttributedString(string: InvisibleGlyphs.eol, attributes: attrs)
                    .draw(at: NSPoint(x: r.minX, y: r.minY))
            }
            if NSMaxRange(lineRange) == lineStart { break }   // 進まない＝末尾
            lineStart = NSMaxRange(lineRange)
        }
    }

    private func isNewline(_ unit: unichar) -> Bool { unit == 0x000A || unit == 0x000D }

    /// 選択（キャレット）移動で現在行ハイライトを描き直す。
    /// **AppKit 由来の選択変更はマルチカーソルの解除**（普通のクリック・矢印キーで元に戻る）。
    /// 自分で複数キャレットを置くときは `applyCarets` から `super` を直接呼ぶのでここを通らない。
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !carets.isEmpty { carets = []; needsDisplay = true }
        if highlightCurrentLine { needsDisplay = true }
        syncCaretBlink()
    }

    // MARK: - マルチカーソル

    /// 複数キャレット（UTF-16・昇順）。**空のとき＝単一キャレットの通常状態**。
    ///
    /// NSTextView の `selectedRanges` は**長さ 0 の範囲を複数持てない**（1 つに畳まれる）ので、
    /// キャレットの列はここで自前に持つ。長さのある範囲（⌘D で集めた語）は AppKit にも渡して
    /// 選択の帯を描かせ、長さ 0 のキャレットだけ `drawExtraCarets` で自分で描く。
    private var carets: [NSRange] = []

    /// マルチカーソル中か。
    var hasMultipleCarets: Bool { carets.count > 1 }

    /// 編集・追加操作の起点になる現在の範囲（マルチなら全キャレット、単一なら選択そのもの）。
    private var activeRanges: [NSRange] { hasMultipleCarets ? carets : [selectedRange()] }

    /// 副キャレットの点滅位相（AppKit が点滅させるのは主キャレット 1 つだけ）。
    private var extraCaretsOn = true
    private var caretBlinkTimer: Timer?

    /// キャレット列を確定して表示へ反映する。1 個に畳まれたら通常の単一選択へ戻す。
    private func applyCarets(_ new: [NSRange]) {
        let normalized = MultiCursor.normalize(new)
        guard let primary = normalized.last else { return }
        carets = normalized.count > 1 ? normalized : []

        // 長さのある範囲が複数あるときは AppKit の不連続選択に載せる（帯を描いてもらう）。
        let selections = normalized.filter { $0.length > 0 }
        let handOff = selections.count > 1 ? selections : [normalized.count > 1 ? (selections.first ?? primary) : primary]
        super.setSelectedRanges(handOff.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)

        needsDisplay = true
        syncCaretBlink()
    }

    /// ⌘クリックでキャレットを足す／同じ位置をもう一度クリックで外す。
    /// ⌥ドラッグの矩形選択（AppKit 標準）はそのまま残す＝そちらも複数範囲として編集できる。
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.shift), isEditable else {
            super.mouseDown(with: event); return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        applyCarets(MultiCursor.toggling(activeRanges, at: NSRange(location: index, length: 0)))
    }

    /// 上／下の行の同じ桁にキャレットを足す（⌥⌘↑ / ⌥⌘↓）。
    func addCaret(above: Bool) {
        applyCarets(MultiCursor.addingCaret(to: activeRanges, above: above, in: string as NSString))
    }

    /// 選択中の語と同じ次の語を選択に足す（⌘D）。選択が無ければキャレット位置の語を選ぶ。
    func selectNextOccurrence() {
        let text = string as NSString
        let current = activeRanges
        guard let last = current.max(by: { NSMaxRange($0) < NSMaxRange($1) }) else { return }
        guard last.length > 0 else {
            // まず語を掴む段階（VSCode の ⌘D 1 回目と同じ）。
            guard let word = MultiCursor.wordRange(at: last.location, in: text) else { NSSound.beep(); return }
            applyCarets([word])
            return
        }
        let word = text.substring(with: last)
        guard let found = MultiCursor.nextOccurrence(of: word, in: text, after: NSMaxRange(last),
                                                     excluding: current) else { NSSound.beep(); return }
        applyCarets(current + [found])
        scrollRangeToVisible(found)
    }

    /// Esc でマルチカーソルを解除（主キャレット 1 つに畳む）。単一なら標準の動作へ。
    override func cancelOperation(_ sender: Any?) {
        guard hasMultipleCarets else { super.cancelOperation(sender); return }
        applyCarets([carets.last ?? selectedRange()])
    }

    // MARK: - 複数キャレットへの編集（アンドゥは NSTextView の機構にそのまま載せる）

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // IME 変換中は主キャレットだけを相手にする（marked text は 1 か所にしか置けない）。
        guard !hasMarkedText(), applyToAllCarets(replacing: nil, with: text) else {
            super.insertText(string, replacementRange: replacementRange); return
        }
    }

    override func insertNewline(_ sender: Any?) {
        guard applyToAllCarets(replacing: nil, with: "\n") else { super.insertNewline(sender); return }
    }

    override func insertTab(_ sender: Any?) {
        guard applyToAllCarets(replacing: nil, with: "\t") else { super.insertTab(sender); return }
    }

    override func deleteBackward(_ sender: Any?) {
        guard applyToAllCarets(replacing: false, with: "") else { super.deleteBackward(sender); return }
    }

    override func deleteForward(_ sender: Any?) {
        guard applyToAllCarets(replacing: true, with: "") else { super.deleteForward(sender); return }
    }

    /// 全キャレットに同じ編集を適用する。`forward` が nil なら選択（キャレットなら 0 文字）を
    /// `text` で置換、非 nil なら削除方向。単一キャレットのときは false を返して標準処理に任せる。
    private func applyToAllCarets(replacing forward: Bool?, with text: String) -> Bool {
        guard hasMultipleCarets, isEditable, let storage = textStorage else { return false }
        let targets: [NSRange] = {
            guard let forward else { return MultiCursor.normalize(carets) }
            return MultiCursor.deletionRanges(carets, forward: forward, in: string as NSString)
        }()
        guard !targets.isEmpty else { return true }   // 消すものが無い＝何もせず握り潰す

        let replacements = Array(repeating: text, count: targets.count)
        guard shouldChangeText(inRanges: targets.map { NSValue(range: $0) },
                               replacementStrings: replacements) else { return true }
        let inserted = NSAttributedString(string: text, attributes: typingAttributes)
        storage.beginEditing()
        // 後ろから適用すれば前方のオフセットが動かない。
        for r in targets.reversed() { storage.replaceCharacters(in: r, with: inserted) }
        storage.endEditing()
        didChangeText()
        applyCarets(MultiCursor.caretsAfterReplacing(targets, with: replacements))
        return true
    }

    // MARK: - 副キャレットの描画（点滅も自前）

    /// キャレットが 2 個以上のときだけ点滅タイマーを回す。
    private func syncCaretBlink() {
        let needed = hasMultipleCarets && carets.contains { $0.length == 0 }
        if needed, caretBlinkTimer == nil {
            extraCaretsOn = true
            caretBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.56, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.extraCaretsOn.toggle()
                self.setNeedsDisplay(self.extraCaretsBounds)
            }
        } else if !needed, caretBlinkTimer != nil {
            caretBlinkTimer?.invalidate()
            caretBlinkTimer = nil
            extraCaretsOn = true
        }
    }

    /// 副キャレットを含む再描画範囲（点滅で全面を描き直さないため）。
    private var extraCaretsBounds: NSRect {
        extraCaretRects().reduce(NSRect.zero) { $0.isEmpty ? $1 : $0.union($1) }
    }

    /// 自前で描くキャレット矩形。AppKit が描く主キャレット（空選択のとき）とは重ねない。
    private func extraCaretRects() -> [NSRect] {
        guard hasMultipleCarets else { return [] }
        let primary = selectedRange()
        let drawnByAppKit = primary.length == 0 ? primary.location : -1
        return carets.filter { $0.length == 0 && $0.location != drawnByAppKit }
                     .compactMap { caretRect(atCharIndex: $0.location) }
    }

    /// 文字位置 `ci` のキャレット矩形（ビュー座標）。末尾・空文書・行末の改行直後も扱う。
    private func caretRect(atCharIndex ci: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let text = string as NSString
        let len = text.length
        let index = min(max(0, ci), len)
        let origin = textContainerOrigin
        let width = cursorShape == .bar ? 1.5 : caretWidth

        func atEndOfText() -> NSRect {
            if len == 0 || isNewline(text.character(at: len - 1)) {
                var r = lm.extraLineFragmentRect
                r.size.width = width
                return r
            }
            let g = lm.glyphIndexForCharacter(at: len - 1)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let box = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            return NSRect(x: box.maxX, y: frag.minY, width: width, height: frag.height)
        }

        var rect: NSRect
        if index >= len {
            rect = atEndOfText()
        } else {
            let g = lm.glyphIndexForCharacter(at: index)
            guard g < lm.numberOfGlyphs else { rect = atEndOfText(); return rect.offsetBy(dx: origin.x, dy: origin.y) }
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let p = lm.location(forGlyphAt: g)
            rect = NSRect(x: frag.minX + p.x, y: frag.minY, width: width, height: frag.height)
        }
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// 副キャレットを描く（形状は主キャレットと同じ config 連動）。
    private func drawExtraCarets() {
        guard extraCaretsOn, hasMultipleCarets else { return }
        let color = insertionPointColor ?? .textColor
        for var r in extraCaretRects() {
            switch cursorShape {
            case .bar:
                color.setFill()
            case .block:
                color.withAlphaComponent(0.4).setFill()
            case .underline:
                r.origin.y = r.maxY - 2
                r.size.height = 2
                color.setFill()
            }
            r.fill()
        }
    }

    // MARK: - キャレット形状

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard cursorShape != .bar else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        guard flag else { return }
        var r = rect
        r.size.width = caretWidth
        if cursorShape == .block {
            color.withAlphaComponent(0.4).setFill()
        } else { // underline
            r.origin.y = rect.maxY - 2
            r.size.height = 2
            color.setFill()
        }
        r.fill()
    }

    /// ブロック／アンダーラインは幅を持つため、消去範囲を 1 文字ぶん広げる。
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = invalidRect
        if cursorShape != .bar { r.size.width += caretWidth }
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }
}
