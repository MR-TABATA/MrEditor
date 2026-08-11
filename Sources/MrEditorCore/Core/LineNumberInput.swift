import Foundation

/// 行ジャンプ欄に打ち込まれた文字列を行番号に読む。
///
/// 素の `Int(_:)` では日本語ユーザーが確実に転ぶ。日本語入力が有効なまま数字を打つと
/// IME を通って全角になり、「８６４２０３３７」や、変換候補から選んだ「86,420,337」が
/// そのまま入る。どちらも `Int(_:)` は nil を返すので、ジャンプは無言で失敗していた。
///
/// 全角を半角へ畳み、桁区切りと空白を落としてから読む。数字以外が混じっていたら nil。
enum LineNumberInput {

    static func parse(_ raw: String) -> Int? {
        let halfwidth = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        let digits = halfwidth.filter { !$0.isWhitespace && $0 != "," }
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(digits), n > 0
        else { return nil }
        return n
    }
}
