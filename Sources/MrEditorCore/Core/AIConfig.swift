import Foundation

/// BYOK（ユーザー自前キー）で対応する AI プロバイダ。
/// 原価はユーザーの鍵持ち＝アプリ側は無料機能として提供する（M3.5 の物語エンジン）。
enum AIProvider: String, CaseIterable, Codable {
    case anthropic
    case openAI
    case gemini
    /// ローカルの Ollama（OpenAI 互換 API）。キーは要らない。B18。
    case ollama

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI:    return "OpenAI"
        case .gemini:    return "Google (Gemini)"
        case .ollama:    return "Ollama (local)"
        }
    }

    /// キーが要るか。**Ollama だけ要らない**（ローカルなので鍵で守る相手がいない）。
    /// [[AIClient]] のキー必須ガード、[[AIRequestBuilder.makeRequest]] の空キー拒否はここを見る。
    var requiresAPIKey: Bool { self != .ollama }

    /// 既定のエンドポイント。config の baseURLOverride で上書きでき、OpenAI 互換サーバへ向けられる。
    /// Ollama だけ既定が http ── ローカル向けの ATS 例外（NSAllowsLocalNetworking）を
    /// Info.plist に足してあるので、127.0.0.1 / localhost / .local 相手はこれで届く。
    var defaultBaseURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://api.anthropic.com")!
        case .openAI:    return URL(string: "https://api.openai.com")!
        case .gemini:    return URL(string: "https://generativelanguage.googleapis.com")!
        case .ollama:    return URL(string: "http://localhost:11434")!
        }
    }

    /// モデル欄のドロップダウンに並べる候補。**先頭が既定**。
    /// 一覧は手掛かりであって縛りではない（欄は編集可＝ここに無い ID も打てる）。
    /// モデルは改名・引退するので、エイリアスがあるものはエイリアスを優先して並べる。
    var suggestedModels: [String] {
        switch self {
        case .anthropic:
            return ["claude-opus-5", "claude-sonnet-5",
                    "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
                    "claude-sonnet-4-6", "claude-haiku-4-5"]
        case .openAI:
            return ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "o4-mini"]
        case .gemini:
            // `-latest` は常に現行を指すエイリアス。**固定版は並べない**：確認した時点で
            // gemini-2.5-flash は既に 404（新規ユーザーには提供終了）だった。Google は版を
            // 次々引退させるので、一覧に固定版を焼き込むと腐る。使いたい人は打ち込めばよく、
            // 接続テストに通れば次から一覧に出る。
            return ["gemini-flash-latest", "gemini-pro-latest", "gemini-flash-lite-latest"]
        case .ollama:
            // インストールしたモデルは人によって違う。`ollama list` で入っているものが正で、
            // ここは「よくある名前」の手がかりでしかない。
            return ["llama3.2", "qwen2.5", "mistral", "gemma2"]
        }
    }

    /// ドロップダウンに実際に並べるもの＝**自分で確かめたモデル（新しい順）＋既定の候補**。
    /// 一覧に無い ID を打ち込んで接続テストに通れば、次からは選ぶだけで済む。
    /// 重複は落とし、確かめた側を上に出す（打った本人にとってはそれが「自分の一覧」）。
    func modelChoices(remembered: [String]) -> [String] {
        var seen = Set<String>()
        return (remembered + suggestedModels).filter { model in
            let m = model.trimmingCharacters(in: .whitespaces)
            guard !m.isEmpty, !seen.contains(m) else { return false }
            seen.insert(m)
            return true
        }
    }

    /// 既定モデル（環境設定で変更できる初期値）。**一覧の先頭とは限らない**：
    /// 一覧は新しい順に並べるが、既定は実機で確かめた版に据え置く（勝手に乗り換えさせない）。
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-4-8"
        case .openAI:    return "gpt-4o"
        case .gemini:    return "gemini-flash-latest"
        case .ollama:    return "llama3.2"
        }
    }

    /// API キーを収める Keychain のアカウント名（プロバイダごとに別々に持てる）。
    var keychainAccount: String { "ai.\(rawValue).apiKey" }
}

/// AI 連携の設定（**キー本体は含まない**。キーは平文の UserDefaults ではなく [[Keychain]] に置く）。
/// `Codable` は Pro とのプロバイダ共有（[[AppSettings.aiConfig]] 参照）のため。
struct AIConfig: Equatable, Codable {
    var provider: AIProvider
    var model: String
    /// OpenAI 互換サーバ等へ向けるためのベース URL 上書き（空＝既定）。**https 限定、
    /// ただし loopback／.local 相手は http も通す**（配布 .app は ATS に
    /// `NSAllowsLocalNetworking` を足してあるので、そこだけ平文が届く。
    /// それ以外の http は実機で -1022。[[ats-url-fetch-https-only]]）。
    var baseURLOverride: String

    static let `default` = AIConfig(provider: .anthropic,
                                    model: AIProvider.anthropic.defaultModel,
                                    baseURLOverride: "")

    /// ループバック／mDNS など、ATS の `NSAllowsLocalNetworking` が平文でも通す相手か。
    private static func isLocalHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    /// 実効ベース URL。上書きが有効な https URL、または loopback 相手の http ならそれ、
    /// 無ければプロバイダ既定（Ollama の既定自体が http なのでここは通らない）。
    var baseURL: URL {
        if let u = URL(string: baseURLOverride), let host = u.host,
           u.scheme == "https" || (u.scheme == "http" && Self.isLocalHost(host)) {
            return u
        }
        return provider.defaultBaseURL
    }
}
