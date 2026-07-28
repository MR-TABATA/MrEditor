import Foundation

/// AI への単発問い合わせを実際に送る層（URLSession）。組立・解析は純粋な [[AIRequestBuilder]]、
/// キーは [[Keychain]]、ここは送受信と失敗の言葉づかいだけを担う。
/// 完了は必ずメインスレッドで呼ぶ（[[UpdateChecker]] と同じ流儀）。
enum AIClient {

    enum ClientError: LocalizedError {
        case notConfigured          // キー未設定
        case network(Error)
        case http(Int)              // 2xx 以外（本文からメッセージが拾えなかったとき）
        case api(String)            // プロバイダのエラーメッセージ

        var errorDescription: String? {
            switch self {
            case .notConfigured: return L("ai.error.notConfigured")
            case .network(let e): return e.localizedDescription
            case .http(let code): return L("ai.error.http", code)
            case .api(let msg):   return msg
            }
        }
    }

    /// 現在の設定（AppSettings）＋ Keychain のキーで prompt を送る。
    static func send(_ prompt: AIPrompt,
                     completion: @escaping (Result<String, ClientError>) -> Void) {
        let config = AppSettings.aiConfig
        guard let key = Keychain.get(account: config.provider.keychainAccount), !key.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return
        }
        send(prompt, config: config, apiKey: key, completion: completion)
    }

    /// 設定・キーを明示して送る（テスト時に別プロバイダを差し込めるよう分離）。
    static func send(_ prompt: AIPrompt,
                     config: AIConfig,
                     apiKey: String,
                     completion: @escaping (Result<String, ClientError>) -> Void) {
        let request: URLRequest
        do {
            var r = try AIRequestBuilder.makeRequest(prompt, config: config, apiKey: apiKey)
            r.timeoutInterval = 60
            request = r
        } catch {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return
        }

        let provider = config.provider
        let finish: (Result<String, ClientError>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let error {
                finish(.failure(.network(error)))
                return
            }
            let data = data ?? Data()
            // まず本文を解析。プロバイダのエラー形なら message を優先して見せる。
            do {
                let text = try AIRequestBuilder.parseResponse(data, provider: provider)
                finish(.success(text))
            } catch let e as AIRequestBuilder.AIError {
                finish(.failure(.api(e.message)))
            } catch {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                finish(.failure(.http(code)))
            }
        }.resume()
    }
}
