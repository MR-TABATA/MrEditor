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

    /// 現在の設定＋ Keychain のキーで prompt を**ストリーミング**送信する。
    /// `onDelta` は届いた本文の差分（メインスレッド）、`completion` は締め（全文 or 失敗）。
    /// 戻り値の取っ手で途中キャンセルできる（パネルを閉じた・解析し直した）。
    @discardableResult
    static func stream(_ prompt: AIPrompt,
                       onDelta: @escaping (String) -> Void,
                       completion: @escaping (Result<String, ClientError>) -> Void) -> AIStreamHandle {
        let handle = AIStreamHandle(onDelta: onDelta, completion: completion)
        let config = AppSettings.aiConfig
        guard let key = Keychain.get(account: config.provider.keychainAccount), !key.isEmpty else {
            handle.failLater(.notConfigured)
            return handle
        }
        let request: URLRequest
        do {
            var r = try AIRequestBuilder.makeRequest(prompt, config: config, apiKey: key, stream: true)
            r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            // 初回バイトまでの待ち時間。以後は差分が届くたびに更新される。
            r.timeoutInterval = 60
            request = r
        } catch {
            handle.failLater(.notConfigured)
            return handle
        }
        handle.start(request: request, provider: config.provider)
        return handle
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

/// 進行中のストリームを指す取っ手 兼 URLSession のデリゲート。
/// デリゲートキューは main＝差分も完了もメインスレッドで届く（[[AIClient]] の流儀）。
/// 一度でも締めたら以後は何も呼ばない（`cancel()` 後の遅れて来た差分も捨てる）。
final class AIStreamHandle: NSObject, URLSessionDataDelegate {
    private var onDelta: ((String) -> Void)?
    private var completion: ((Result<String, AIClient.ClientError>) -> Void)?
    private var session: URLSession?
    private var decoder: AIStreamDecoder?
    private var text = ""
    private var status = 200
    private var errorBody = Data()      // 2xx でないときの本文（SSE ではなく JSON のエラー）

    init(onDelta: @escaping (String) -> Void,
         completion: @escaping (Result<String, AIClient.ClientError>) -> Void) {
        self.onDelta = onDelta
        self.completion = completion
    }

    fileprivate func start(request: URLRequest, provider: AIProvider) {
        decoder = AIStreamDecoder(provider: provider)
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        session.dataTask(with: request).resume()
    }

    /// 送る前に判った失敗（キー未設定など）。呼び出し側が取っ手を受け取ってから通知する。
    fileprivate func failLater(_ error: AIClient.ClientError) {
        DispatchQueue.main.async { [weak self] in self?.finish(.failure(error)) }
    }

    /// 以後の差分・完了を止める。パネルを閉じた／解析し直したときに呼ぶ。
    func cancel() {
        onDelta = nil
        completion = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func finish(_ result: Result<String, AIClient.ClientError>) {
        guard let completion else { return }
        self.completion = nil
        onDelta = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion(result)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard completion != nil else { return }
        guard (200...299).contains(status) else { errorBody.append(data); return }
        for event in decoder?.consume(data) ?? [] {
            switch event {
            case .delta(let chunk):
                text += chunk
                onDelta?(chunk)
            case .done:
                break                       // 締めは didCompleteWithError 側で一本化する
            case .failure(let message):
                finish(.failure(.api(message)))
                return
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard completion != nil else { return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { cancel(); return }
            finish(.failure(.network(error)))
            return
        }
        guard (200...299).contains(status) else {
            if let message = AIRequestBuilder.errorMessage(in: errorBody) { finish(.failure(.api(message))) }
            else { finish(.failure(.http(status))) }
            return
        }
        // 改行で終わらなかった最後の行を絞り出してから締める。
        for event in decoder?.finish() ?? [] {
            if case .delta(let chunk) = event {
                text += chunk
                onDelta?(chunk)
            }
        }
        guard !text.isEmpty else { finish(.failure(.api("empty response"))); return }
        finish(.success(text))
    }
}
