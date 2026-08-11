import Foundation

/// 課金境界を機械化したもの。**「どれが Pro か」を人間の記憶ではなくここに置く。**
///
/// 2026-08-04 に時刻マージ（`Pro v1:` と書いたコミット）が無料版で出荷された事故は、
/// 「Pro のつもり」がコミットメッセージにしか無く、コードのどこにも書かれていなかった
/// ことが原因だった。判定を 1 箇所に集め、UI から必ずここを通す。
///
/// 線（`notes/freemium-split.md`）: **1 本を見る＝無料 / 束ねる・答えを出す＝Pro。**
public enum ProFeature: String, CaseIterable, Sendable {
    /// 値ごとの出現回数（`sort | uniq -c | sort -rn` 相当）。ロードマップ C1。
    case aggregate
    /// 列の統計（ユニーク数・最小最大・空欄数）。ロードマップ C2。
    case columnStats
    /// 時間分布（いつ増えたか）。ロードマップ C3。
    case timeHistogram
    /// フォルダを跨ぐ横断検索。ロードマップ C5。
    case crossFileSearch
    /// 複数ホストを束ねる（SSH 横断 grep・時刻マージ・集計）。ロードマップ C7。
    case crossHostMerge
    /// 畳んだ俯瞰を AI に渡す（GB 級）。ロードマップ C4 ＝ M5 の旗艦。
    case aiOverview

    // ⚠️ ここに **無い** ものは無料。特に:
    //   - 時刻マージ（ローカル複数ファイル・⇧⌘O）… v1.11 で無料版として出荷済み。
    //     配布済みバイナリから取り上げることはできないので、無料で確定させた（2026-08-11）。
    //     Pro 側は `crossHostMerge`（束ねる先がリモート）だけ。
    //   - 単発の AI 診断（BYOK）… v1.9 以降、無料コアの看板の一部。
}

/// この起動が Pro として動けるか。ライセンス層（Pro リポ）が答える。
public enum ProEntitlement: Equatable, Sendable {
    /// 未ライセンス。**無料ビルドは常にこれ**（Pro ビルドでも、買う前はこれ）。
    case free
    /// 有効。`until` が nil なら買い切りで期限なし。
    case unlocked(until: Date?)

    public var isUnlocked: Bool {
        if case .unlocked = self { return true }
        return false
    }
}

/// Pro（クローズド）が core へ自分を差し込むための**唯一の口**。
///
/// core は Pro の型を一切知らない。知っているのはこのプロトコルだけで、
/// 依存の向きは **Pro → core の一方向**に保たれる。
public protocol ProProvider: AnyObject {
    /// 現在の権利。ライセンスの有効期限切れ等で起動中に変わりうる。
    var entitlement: ProEntitlement { get }
    /// 起動直後に一度だけ呼ばれる。メニュー項目の追加などはここで行う。
    func activate()
}

/// 機能ゲート。UI からはこれだけを見る。
public enum Pro {
    /// 差し込まれた Pro 層（無料ビルドでは nil のまま）。
    public private(set) static var provider: ProProvider?

    /// 起動時に 1 度だけ Pro 層を差し込む（`MrEditorApp.main(pro:)` が呼ぶ）。
    /// この時点ではまだメニューが無いので、`activate()` は呼ばない。
    public static func install(_ provider: ProProvider) {
        self.provider = provider
    }

    /// メニューとウィンドウが揃ってから core が呼ぶ。Pro 層が UI を足すのはこの後。
    static func activateProvider() {
        provider?.activate()
    }

    /// この起動が Pro か。無料ビルドでは常に false。
    public static var isUnlocked: Bool {
        provider?.entitlement.isUnlocked ?? false
    }

    /// その機能を今使ってよいか。**Pro 機能の入口は必ずこれを通す。**
    public static func allows(_ feature: ProFeature) -> Bool {
        isUnlocked
    }

    /// テスト用。差し込みを外す。
    static func resetForTesting() {
        provider = nil
    }
}