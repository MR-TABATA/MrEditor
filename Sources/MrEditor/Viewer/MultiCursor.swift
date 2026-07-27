import Foundation

/// マルチカーソルの範囲計算（UI 非依存の純ロジック）。
///
/// 保持しているのは `NSTextView.selectedRanges` そのもの（UTF-16 の範囲配列）で、
/// このファイルには「どこにキャレットを足すか」「編集後にキャレットがどこへ動くか」
/// だけを置く。実際の本文書き換えとアンドゥは `EditorTextView` が
/// `shouldChangeTextInRanges` 経由で行う（NSTextView のアンドゥにそのまま載る）。
enum MultiCursor {
    // MARK: - 範囲の集合を保つ

    /// 範囲を追加して正規化する。同じ位置のキャレットは足さずに**取り除く**
    /// （⌘クリックで付けた点をもう一度クリックして消せる）。
    static func toggling(_ ranges: [NSRange], at range: NSRange) -> [NSRange] {
        if let hit = ranges.firstIndex(where: { $0 == range }), ranges.count > 1 {
            var out = ranges
            out.remove(at: hit)
            return out
        }
        return normalize(ranges + [range])
    }

    /// 昇順に並べ、重なり合う範囲を 1 つに畳む。空（キャレット）が別の範囲に含まれる場合も畳む。
    static func normalize(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location != $1.location ? $0.location < $1.location : $0.length < $1.length }
        var out: [NSRange] = []
        for r in sorted {
            guard var last = out.last else { out.append(r); continue }
            // 触れていない（間が空いている）なら別のキャレットとして残す。
            guard r.location <= NSMaxRange(last) else { out.append(r); continue }
            // 端で接するだけの空キャレットは、隣の選択に飲ませない限り重複扱いにする。
            if r.length == 0 && last.length > 0 && r.location == NSMaxRange(last) { continue }
            if r.length == 0 && last.length == 0 && r.location != last.location { out.append(r); continue }
            last.length = max(NSMaxRange(last), NSMaxRange(r)) - last.location
            out[out.count - 1] = last
        }
        return out
    }

    // MARK: - 上下にキャレットを足す（⌥⌘↑ / ⌥⌘↓）

    /// `ranges` の最も上（`above` が true）／下のキャレットと同じ桁に、1 行ぶん隣のキャレットを足す。
    /// 隣の行が無い（先頭行の上・末尾行の下）ときは `ranges` をそのまま返す。
    static func addingCaret(to ranges: [NSRange], above: Bool, in text: NSString) -> [NSRange] {
        guard let edge = above ? ranges.min(by: { $0.location < $1.location })
                               : ranges.max(by: { $0.location < $1.location }) else { return ranges }
        let anchor = above ? edge.location : NSMaxRange(edge)
        let line = text.lineRange(for: NSRange(location: min(anchor, text.length), length: 0))
        let column = min(anchor, text.length) - line.location

        let neighbor: NSRange
        if above {
            guard line.location > 0 else { return ranges }
            neighbor = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
        } else {
            guard NSMaxRange(line) < text.length else { return ranges }
            neighbor = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
        }
        // 短い行では行末に寄せる（改行を飛び越えて次の行に入らないよう content 長で止める）。
        let target = neighbor.location + min(column, contentLength(of: neighbor, in: text))
        return normalize(ranges + [NSRange(location: target, length: 0)])
    }

    /// 改行を除いた行の長さ（CRLF も 1 行として扱う）。
    private static func contentLength(of line: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, isNewline(text.character(at: end - 1)) { end -= 1 }
        return end - line.location
    }

    private static func isNewline(_ unit: unichar) -> Bool { unit == 0x000A || unit == 0x000D }

    // MARK: - 次の同じ語を選択に足す（⌘D）

    /// `word` と同じ文字列を `after` 以降（末尾まで行ったら先頭へ回り込んで）探し、その範囲を返す。
    /// 既に `ranges` に入っている一致は飛ばす。見つからなければ nil。
    static func nextOccurrence(of word: String, in text: NSString, after: Int,
                               excluding ranges: [NSRange]) -> NSRange? {
        guard !word.isEmpty else { return nil }
        let taken = Set(ranges.map { $0.location })
        var from = min(max(0, after), text.length)
        var wrapped = false
        while true {
            let searchRange = NSRange(location: from, length: text.length - from)
            let found = text.range(of: word, options: [], range: searchRange)
            if found.location == NSNotFound {
                if wrapped { return nil }
                wrapped = true; from = 0; continue
            }
            if !taken.contains(found.location) { return found }
            from = found.location + 1
            if from >= text.length {
                if wrapped { return nil }
                wrapped = true; from = 0
            }
        }
    }

    /// `index` を含む（または直前で終わる）語の範囲。語が無ければ nil。
    static func wordRange(at index: Int, in text: NSString) -> NSRange? {
        guard text.length > 0 else { return nil }
        let isWord: (unichar) -> Bool = { u in
            let c = Character(UnicodeScalar(u) ?? " ")
            return c.isLetter || c.isNumber || c == "_"
        }
        var start = min(index, text.length)
        // キャレットが語の直後にあるときも、その語を掴む。
        if start == text.length || !isWord(text.character(at: start)) {
            guard start > 0, isWord(text.character(at: start - 1)) else { return nil }
            start -= 1
        }
        var end = start
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWord(text.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: - 編集後のキャレット位置

    /// 各範囲を `replacements[i]` で置き換えたあとのキャレット位置（挿入した文字列の直後）を返す。
    /// 前の編集で生じた長さの差を積み上げてずらす（`ranges` は昇順であること）。
    static func caretsAfterReplacing(_ ranges: [NSRange], with replacements: [String]) -> [NSRange] {
        var delta = 0
        var out: [NSRange] = []
        out.reserveCapacity(ranges.count)
        for (i, r) in ranges.enumerated() {
            let inserted = (replacements[min(i, replacements.count - 1)] as NSString).length
            out.append(NSRange(location: r.location + delta + inserted, length: 0))
            delta += inserted - r.length
        }
        return out
    }

    /// 削除キーが消す範囲を各キャレットについて求める。
    /// 選択があればその選択を、キャレットだけなら前（`forward` が false）／後ろの 1 文字を消す。
    /// 消すものが無い（文頭で前を消す等）範囲は落とす。
    static func deletionRanges(_ ranges: [NSRange], forward: Bool, in text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges {
            if r.length > 0 { out.append(r); continue }
            if forward {
                guard r.location < text.length else { continue }
                // サロゲートペア・結合文字を 1 文字として消す。
                out.append(text.rangeOfComposedCharacterSequence(at: r.location))
            } else {
                guard r.location > 0 else { continue }
                out.append(text.rangeOfComposedCharacterSequence(at: r.location - 1))
            }
        }
        return normalize(out)
    }
}
