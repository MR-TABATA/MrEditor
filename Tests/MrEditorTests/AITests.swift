import XCTest
@testable import MrEditor

/// AI 連携（BYOK）の純粋コアを検証する。ネットワーク送信・GUI は対象外。
/// `AIConfig`（既定/上書き/https 限定）・`AIRequestBuilder`（組立/解析/エラー）・
/// `AIPrompts.extractRegex`（フェンス/囲み/説明剥がし）を突く。
final class AITests: XCTestCase {

    // MARK: - AIConfig

    func testDefaultConfig() {
        let c = AIConfig.default
        XCTAssertEqual(c.provider, .anthropic)
        XCTAssertEqual(c.model, "claude-opus-4-8")
        XCTAssertEqual(c.baseURL, URL(string: "https://api.anthropic.com"))
    }

    func testBaseURLOverrideHTTPSOnly() {
        // 有効な https 上書きは採用。
        var c = AIConfig(provider: .openAI, model: "m", baseURLOverride: "https://proxy.example.com")
        XCTAssertEqual(c.baseURL, URL(string: "https://proxy.example.com"))
        // 平文 http は拒否＝既定へフォールバック（配布 .app の ATS 例外なし）。
        c.baseURLOverride = "http://insecure.example.com"
        XCTAssertEqual(c.baseURL, AIProvider.openAI.defaultBaseURL)
        // 空も既定。
        c.baseURLOverride = ""
        XCTAssertEqual(c.baseURL, AIProvider.openAI.defaultBaseURL)
    }

    // MARK: - AIRequestBuilder（組立）

    private func body(_ req: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testMakeAnthropicRequest() throws {
        let cfg = AIConfig(provider: .anthropic, model: "claude-opus-4-8", baseURLOverride: "")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: "SYS", user: "hello", maxTokens: 512), config: cfg, apiKey: "sk-ant-XXX")
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-XXX")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let b = body(req)
        XCTAssertEqual(b["model"] as? String, "claude-opus-4-8")
        XCTAssertEqual(b["max_tokens"] as? Int, 512)
        XCTAssertEqual(b["system"] as? String, "SYS")
        let msgs = b["messages"] as? [[String: Any]]
        XCTAssertEqual(msgs?.first?["role"] as? String, "user")
        XCTAssertEqual(msgs?.first?["content"] as? String, "hello")
    }

    func testMakeOpenAIRequest() throws {
        let cfg = AIConfig(provider: .openAI, model: "gpt-4o", baseURLOverride: "")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: "SYS", user: "hi", maxTokens: 256), config: cfg, apiKey: "sk-XXX")
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-XXX")
        XCTAssertNil(req.value(forHTTPHeaderField: "x-api-key"))
        let msgs = body(req)["messages"] as? [[String: String]]
        XCTAssertEqual(msgs?.count, 2)
        XCTAssertEqual(msgs?[0]["role"], "system")
        XCTAssertEqual(msgs?[1]["role"], "user")
        XCTAssertEqual(msgs?[1]["content"], "hi")
    }

    func testMakeGeminiRequest() throws {
        let cfg = AIConfig(provider: .gemini, model: "gemini-2.5-flash", baseURLOverride: "")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: "SYS", user: "hi", maxTokens: 256), config: cfg, apiKey: "AIza-XXX")
        // モデルはパスに入る（コロンは %3A 化しない）／キーは x-goog-api-key。
        XCTAssertEqual(req.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-XXX")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let b = body(req)
        XCTAssertNotNil(b["system_instruction"])
        let contents = b["contents"] as? [[String: Any]]
        let parts = contents?.first?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "hi")
        let gen = b["generationConfig"] as? [String: Any]
        XCTAssertEqual(gen?["maxOutputTokens"] as? Int, 256)
    }

    func testParseGeminiResponse() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"likely OOM"}],"role":"model"}}]}"#
        let text = try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .gemini)
        XCTAssertEqual(text, "likely OOM")
    }

    func testParseGeminiErrorResponse() {
        let json = #"{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}"#
        XCTAssertThrowsError(try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .gemini)) { err in
            XCTAssertEqual((err as? AIRequestBuilder.AIError)?.message, "API key not valid")
        }
    }

    func testMissingKeyThrows() {
        XCTAssertThrowsError(try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 10), config: .default, apiKey: ""))
    }

    // MARK: - AIRequestBuilder（解析）

    func testParseAnthropicResponse() throws {
        let json = #"{"content":[{"type":"text","text":"root cause: OOM"}],"stop_reason":"end_turn"}"#
        let text = try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .anthropic)
        XCTAssertEqual(text, "root cause: OOM")
    }

    func testParseOpenAIResponse() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"try -Xmx"}}]}"#
        let text = try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .openAI)
        XCTAssertEqual(text, "try -Xmx")
    }

    func testParseErrorResponse() {
        let json = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        XCTAssertThrowsError(try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .anthropic)) { err in
            XCTAssertEqual((err as? AIRequestBuilder.AIError)?.message, "invalid x-api-key")
        }
    }

    // MARK: - モデル候補（ドロップダウンの中身）

    func testSuggestedModelsIncludeDefault() {
        for provider in AIProvider.allCases {
            XCTAssertFalse(provider.suggestedModels.isEmpty, "\(provider) の候補が空")
            XCTAssertTrue(provider.suggestedModels.contains(provider.defaultModel),
                          "\(provider) の既定 \(provider.defaultModel) が候補に無い")
            // 一覧は手掛かり＝重複していると選びにくい。
            XCTAssertEqual(Set(provider.suggestedModels).count, provider.suggestedModels.count)
        }
    }

    /// 候補に無い ID（OpenAI 互換サーバの独自モデル等）もそのまま通ること。
    func testArbitraryModelIsUsedVerbatim() throws {
        let cfg = AIConfig(provider: .openAI, model: "my-local-llama", baseURLOverride: "https://llm.example.com")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 8), config: cfg, apiKey: "k")
        XCTAssertEqual(body(req)["model"] as? String, "my-local-llama")
        XCTAssertEqual(req.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
    }

    // MARK: - 思考トークン対策（Anthropic）

    /// Opus 5 以降は指定が無いと思考オンが既定＝max_tokens を思考が食い、短い診断で本文が出ない。
    /// 一問一答なので明示的に切る。
    func testAnthropicDisablesThinking() throws {
        let cfg = AIConfig(provider: .anthropic, model: "claude-opus-5", baseURLOverride: "")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: "SYS", user: "x", maxTokens: 2048), config: cfg, apiKey: "k")
        XCTAssertEqual((body(req)["thinking"] as? [String: String])?["type"], "disabled")
    }

    /// 思考が常時オンのモデル（Fable / Mythos）は「切る」指定自体が 400 なので送らない。
    func testAlwaysThinkingModelsGetNoThinkingField() throws {
        for model in ["claude-fable-5", "claude-mythos-5"] {
            let cfg = AIConfig(provider: .anthropic, model: model, baseURLOverride: "")
            let req = try AIRequestBuilder.makeRequest(
                AIPrompt(system: nil, user: "x", maxTokens: 2048), config: cfg, apiKey: "k")
            XCTAssertNil(body(req)["thinking"], "\(model) に thinking を送っている")
        }
        // 判定はモデル ID 由来（一覧に無い ID も打ち込めるため）。
        XCTAssertTrue(AIRequestBuilder.thinkingIsAlwaysOn("claude-fable-5"))
        XCTAssertFalse(AIRequestBuilder.thinkingIsAlwaysOn("claude-opus-5"))
    }

    /// 候補は「少なすぎない」こと（打ち込みに頼らず選べる幅）。
    func testSuggestedModelsAreEnoughToChooseFrom() {
        for provider in AIProvider.allCases {
            XCTAssertGreaterThanOrEqual(provider.suggestedModels.count, 3,
                                        "\(provider) の候補が少なすぎる")
        }
    }

    /// 思考を切ると内部タグが本文へ漏れることがあるので、プロンプト側でも封じている。
    func testErrorCausePromptForbidsInternalTags() {
        let p = AIPrompts.errorCause("x", language: "Japanese")
        XCTAssertTrue(p.system?.contains("XML") ?? false)
    }

    // MARK: - 失敗の言葉づかい（日本語の見出し＋プロバイダ原文）

    func testProviderErrorSpeaksUserLanguage() {
        let raw = "models/gemini-does-not-exist is not found for API version v1beta"
        let text = AIClient.ClientError.provider(code: 404, message: raw).errorDescription ?? ""
        // 1 行目＝何が起きたか（利用者の言語）、2 行目以降＝原文（診断の手がかり）。
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("404"))
        XCTAssertNotEqual(lines[0], raw)                 // 見出しは原文の丸写しではない
        XCTAssertTrue(text.contains(raw))                // 原文は捨てない
    }

    func testProviderErrorHeadlineVariesByStatus() {
        func headline(_ code: Int) -> String {
            let d = AIClient.ClientError.provider(code: code, message: "x").errorDescription ?? ""
            return d.split(separator: "\n").first.map(String.init) ?? ""
        }
        // 401 / 404 / 429 / 5xx は別々の言い方（「どれも同じ HTTP エラー」にしない）。
        let heads = [headline(401), headline(404), headline(429), headline(503)]
        XCTAssertEqual(Set(heads).count, 4, "状態ごとの言い分けが足りない: \(heads)")
        for (code, h) in zip([401, 404, 429, 503], heads) { XCTAssertTrue(h.contains("\(code)")) }
    }

    // MARK: - 接続テスト

    func testConnectionTestPromptIsTiny() {
        let p = AIPrompts.connectionTest()
        XCTAssertFalse(p.user.isEmpty)
        XCTAssertNotNil(p.system)
        // 中身は見ない＝短い返事で足りる。ただし思考ぶんの余裕は要る。
        XCTAssertGreaterThan(p.maxTokens, 0)
        XCTAssertLessThan(p.maxTokens, AIPrompts.errorCause("x", language: "English").maxTokens)
    }

    // MARK: - ストリーミング（組立）

    func testStreamRequestsOptIn() throws {
        let anthropic = try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 8),
            config: AIConfig(provider: .anthropic, model: "m", baseURLOverride: ""), apiKey: "k", stream: true)
        XCTAssertEqual(body(anthropic)["stream"] as? Bool, true)

        let openAI = try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 8),
            config: AIConfig(provider: .openAI, model: "m", baseURLOverride: ""), apiKey: "k", stream: true)
        XCTAssertEqual(body(openAI)["stream"] as? Bool, true)

        // Gemini はメソッド名と ?alt=sse で切り替わる（本文には stream を入れない）。
        let gemini = try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 8),
            config: AIConfig(provider: .gemini, model: "gemini-flash-latest", baseURLOverride: ""),
            apiKey: "k", stream: true)
        XCTAssertEqual(gemini.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:streamGenerateContent?alt=sse")
        XCTAssertNil(body(gemini)["stream"])
    }

    func testNonStreamRequestsUnchanged() throws {
        // 既定（stream 省略）は従来どおり＝非ストリーム。
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 8), config: .default, apiKey: "k")
        XCTAssertNil(body(req)["stream"])
    }

    // MARK: - ストリーミング（SSE の解釈）

    private func feed(_ decoder: inout AIStreamDecoder, _ text: String) -> [AIStreamEvent] {
        decoder.consume(Data(text.utf8))
    }

    func testDecodeAnthropicStream() {
        var d = AIStreamDecoder(provider: .anthropic)
        var events = feed(&d, """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OOM "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"が原因"}}

        event: message_stop
        data: {"type":"message_stop"}

        """)
        events.append(contentsOf: d.finish())
        XCTAssertEqual(events, [.delta("OOM "), .delta("が原因"), .done])
    }

    func testDecodeOpenAIStream() {
        var d = AIStreamDecoder(provider: .openAI)
        let events = feed(&d, """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"try "}}]}

        data: {"choices":[{"delta":{"content":"-Xmx"}}]}

        data: [DONE]

        """)
        XCTAssertEqual(events, [.delta("try "), .delta("-Xmx"), .done])
    }

    func testDecodeGeminiStream() {
        var d = AIStreamDecoder(provider: .gemini)
        let events = feed(&d, """
        data: {"candidates":[{"content":{"parts":[{"text":"ヒープ"}],"role":"model"}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"不足"}],"role":"model"}}]}

        """)
        XCTAssertEqual(events, [.delta("ヒープ"), .delta("不足")])
    }

    /// チャンクは行の途中で切れて届く。持ち越して 1 つの差分に戻せること。
    func testDecodeSplitAcrossChunks() {
        var d = AIStreamDecoder(provider: .anthropic)
        XCTAssertEqual(feed(&d, #"data: {"type":"content_block_delta","delta":{"type":"text_"#), [])
        XCTAssertEqual(feed(&d, "delta\",\"text\":\"半分\"}}\n"), [.delta("半分")])
    }

    /// CRLF・コメント行・空行を捨てても本文が残ること。
    func testDecodeIgnoresNoiseLines() {
        var d = AIStreamDecoder(provider: .openAI)
        let events = feed(&d, ": ping\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\r\n")
        XCTAssertEqual(events, [.delta("ok")])
    }

    /// 途中で降ってくるエラーイベントは失敗として拾う。
    func testDecodeMidStreamError() {
        var d = AIStreamDecoder(provider: .anthropic)
        let events = feed(&d, """
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

        """)
        XCTAssertEqual(events, [.failure("Overloaded")])
    }

    func testErrorMessageFromBody() {
        let json = #"{"error":{"message":"invalid x-api-key"}}"#
        XCTAssertEqual(AIRequestBuilder.errorMessage(in: Data(json.utf8)), "invalid x-api-key")
        XCTAssertNil(AIRequestBuilder.errorMessage(in: Data("not json".utf8)))
    }

    // MARK: - AIPrompts.extractRegex

    func testExtractRegexPlain() {
        XCTAssertEqual(AIPrompts.extractRegex(from: #"ERROR|FATAL"#), "ERROR|FATAL")
    }

    func testExtractRegexTrimsWhitespace() {
        XCTAssertEqual(AIPrompts.extractRegex(from: "  \n\\d{3}\n  "), #"\d{3}"#)
    }

    func testExtractRegexStripsCodeFence() {
        let raw = "```regex\n^(?!.*200 ).*POST.*$\n```"
        XCTAssertEqual(AIPrompts.extractRegex(from: raw), "^(?!.*200 ).*POST.*$")
    }

    func testExtractRegexStripsBareFence() {
        XCTAssertEqual(AIPrompts.extractRegex(from: "```\nfoo.*bar\n```"), "foo.*bar")
    }

    func testExtractRegexStripsSlashes() {
        XCTAssertEqual(AIPrompts.extractRegex(from: "/^abc$/"), "^abc$")
    }

    func testExtractRegexTakesFirstNonEmptyLine() {
        // 説明が混ざったときは最初の非空行を採る。
        XCTAssertEqual(AIPrompts.extractRegex(from: "\n\n\\bwarn\\b\nthis matches warnings"), #"\bwarn\b"#)
    }

    // MARK: - AIPrompts（テンプレの中身）

    func testErrorCausePromptCarriesSelection() {
        let p = AIPrompts.errorCause("NullPointerException at Foo.bar", language: "Japanese")
        XCTAssertEqual(p.user, "NullPointerException at Foo.bar")
        XCTAssertNotNil(p.system)
        XCTAssertTrue(p.system?.contains("Japanese") ?? false)   // UI 言語で返すよう指示している
        XCTAssertGreaterThan(p.maxTokens, 0)
    }

    func testRegexPromptBudget() {
        let p = AIPrompts.naturalLanguageToRegex("4xx 以外の POST")
        XCTAssertEqual(p.user, "4xx 以外の POST")
        // regex 本体は短いが推論トークンぶんの余裕は要る。エラー診断より小さく、0 より大きい。
        XCTAssertGreaterThan(p.maxTokens, 0)
        XCTAssertLessThanOrEqual(p.maxTokens, AIPrompts.errorCause("x", language: "English").maxTokens)
    }
}
