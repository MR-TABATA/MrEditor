import Foundation

/// 遠隔で開いた宛先の履歴（新しい順・重複なし）。**宛先の文字列だけ**を持つ ――
/// 鍵もパスワードも持たない（認証は `/usr/bin/ssh` と ssh-agent 任せ）。
public enum RemoteHistory {
    public static let limit = 10
    private static let key = "remote.history"

    /// 先頭へ入れる。同じものは前から消し、上限を越えたぶんは古いほうから捨てる。
    public static func adding(_ entry: String, to list: [String]) -> [String] {
        let e = entry.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return list }
        return Array(([e] + list.filter { $0 != e }).prefix(limit))
    }

    public static func load(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public static func record(_ entry: String, _ defaults: UserDefaults = .standard) {
        defaults.set(adding(entry, to: load(defaults)), forKey: key)
    }

    public static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
