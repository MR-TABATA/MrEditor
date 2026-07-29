import Foundation

/// AI への 1 回きりの問い合わせ（単発解析）。プロバイダ非依存の内部表現。
/// 「収まる分だけ＝無料 / 収まらない規模＝Pro」の線は呼び出し側（選択範囲＝収まる分）で引く。
struct AIPrompt: Equatable {
    var system: String?
    var user: String
    var maxTokens: Int
}

/// プロンプトをプロバイダ固有の HTTP へ変換する純関数群＋レスポンス解析。**副作用なし＝テスト可能**。
/// 実際の送信は GUI 層の AIClient（URLSession）が担う。
enum AIRequestBuilder {
    struct AIError: Error, Equatable { let message: String }

    /// URLRequest を組み立てる。キーは呼び出し側が [[Keychain]] から取り出して渡す。
    /// `stream` が真なら SSE（`text/event-stream`）で受け取る形にする＝差分表示用。
    static func makeRequest(_ prompt: AIPrompt, config: AIConfig, apiKey: String,
                            stream: Bool = false) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw AIError(message: "missing API key") }
        switch config.provider {
        case .anthropic: return anthropic(prompt, config: config, apiKey: apiKey, stream: stream)
        case .openAI:    return openAI(prompt, config: config, apiKey: apiKey, stream: stream)
        case .gemini:    return try gemini(prompt, config: config, apiKey: apiKey, stream: stream)
        }
    }

    private static func anthropic(_ p: AIPrompt, config: AIConfig, apiKey: String, stream: Bool) -> URLRequest {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": p.maxTokens,
            "messages": [["role": "user", "content": p.user]],
        ]
        if let system = p.system { body["system"] = system }
        if stream { body["stream"] = true }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func openAI(_ p: AIPrompt, config: AIConfig, apiKey: String, stream: Bool) -> URLRequest {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var messages: [[String: String]] = []
        if let system = p.system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": p.user])
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": p.maxTokens,
            "messages": messages,
        ]
        if stream { body["stream"] = true }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Gemini（generativelanguage）。モデルは URL パスに入り（`models/<model>:generateContent`）、
    /// キーは `x-goog-api-key` ヘッダ。system は `system_instruction`、本文は `contents`。
    /// ストリームはメソッド名が変わり（`:streamGenerateContent`）、SSE にするには `?alt=sse` が要る。
    private static func gemini(_ p: AIPrompt, config: AIConfig, apiKey: String, stream: Bool) throws -> URLRequest {
        // モデルにコロンを含むパスなので appendingPathComponent（コロンを %3A 化する）を避け、文字列で組む。
        let base = config.baseURL.absoluteString.hasSuffix("/")
            ? String(config.baseURL.absoluteString.dropLast()) : config.baseURL.absoluteString
        let method = stream ? "streamGenerateContent?alt=sse" : "generateContent"
        guard let url = URL(string: "\(base)/v1beta/models/\(config.model):\(method)") else {
            throw AIError(message: "invalid Gemini URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        var body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": p.user]]]],
            "generationConfig": ["maxOutputTokens": p.maxTokens],
        ]
        if let system = p.system {
            body["system_instruction"] = ["parts": [["text": system]]]
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// プロバイダのエラー形（`error.message`）を拾う。三者とも同じ形。
    static func errorMessage(in obj: [String: Any]) -> String? {
        (obj["error"] as? [String: Any])?["message"] as? String
    }

    /// JSON 本文からエラーメッセージを拾う（本文が JSON でなければ nil）。
    static func errorMessage(in data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return errorMessage(in: obj)
    }

    /// レスポンス JSON からテキストを取り出す。プロバイダのエラー形（`error.message`）も拾って投げる。
    static func parseResponse(_ data: Data, provider: AIProvider) throws -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIError(message: "invalid response")
        }
        if let msg = errorMessage(in: obj) { throw AIError(message: msg) }
        switch provider {
        case .anthropic:
            guard let content = obj["content"] as? [[String: Any]] else {
                throw AIError(message: "no content")
            }
            let text = content.compactMap { block -> String? in
                (block["type"] as? String) == "text" ? block["text"] as? String : nil
            }.joined()
            guard !text.isEmpty else { throw AIError(message: "empty response") }
            return text
        case .openAI:
            guard let choices = obj["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String, !text.isEmpty else {
                throw AIError(message: "no content")
            }
            return text
        case .gemini:
            guard let candidates = obj["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw AIError(message: "no content")
            }
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw AIError(message: "empty response") }
            return text
        }
    }
}
