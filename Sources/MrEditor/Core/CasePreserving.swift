import Foundation

/// 置換で「元の語の大文字小文字を引き継ぐ」ためのロジック（UI 非依存の純関数）。
///
/// 検索を大小区別なしで走らせると `Timeout` / `timeout` / `TIMEOUT` が 1 つの
/// パターンで採れるが、素直に置換すると全部同じ綴りになってしまう。ここでは
/// **一致した実際の文字列**から書式を読み取り、置換文字列へ同じ書式を移す。
enum CasePreserving {
    /// 一致文字列から読み取れる書式。判定できないものは `mixed`＝置換文字列をそのまま使う。
    enum Style {
        case upper       // TIMEOUT
        case lower       // timeout
        case capitalized // Timeout
        case mixed       // timeOut / t1 / 記号のみ など
    }

    /// 一致文字列 `matched` の書式を読み取る。英字（cased 文字）が無ければ `mixed`。
    static func style(of matched: String) -> Style {
        let cased = matched.filter { $0.isCased }
        guard !cased.isEmpty else { return .mixed }
        if cased.allSatisfy({ $0.isUppercase }) {
            // 1 文字の大文字は "A" → capitalized とも取れるが、upper として扱えば
            // 置換文字列が 1 文字でも複数文字でも自然な結果になる。
            return .upper
        }
        if cased.allSatisfy({ $0.isLowercase }) { return .lower }
        if let first = cased.first, first.isUppercase,
           cased.dropFirst().allSatisfy({ $0.isLowercase }) { return .capitalized }
        return .mixed
    }

    /// 一致文字列 `matched` の書式を `replacement` へ移して返す。
    /// `mixed`（判定できない／英字が無い）のときは置換文字列を一切いじらない。
    static func apply(_ replacement: String, matching matched: String) -> String {
        switch style(of: matched) {
        case .upper:  return replacement.uppercased()
        case .lower:  return replacement.lowercased()
        case .capitalized:
            // 先頭の英字だけ大文字にし、残りは打たれたまま（`newValue` → `NewValue`）。
            guard let i = replacement.firstIndex(where: { $0.isCased }) else { return replacement }
            return replacement.replacingCharacters(in: i...i, with: replacement[i].uppercased())
        case .mixed:  return replacement
        }
    }
}

private extension Character {
    /// 大文字・小文字の区別を持つ文字か（日本語・数字・記号は false＝書式の判定に使わない）。
    var isCased: Bool { isUppercase || isLowercase }
}
