import Foundation

/// ストリーム中に届くもの。本文の差分・正常終了・プロバイダ側のエラー。
enum AIStreamEvent: Equatable {
    case delta(String)
    case done
    case failure(String)
}

/// SSE（`text/event-stream`）のバイト列を行に切り、プロバイダごとのイベントから
/// **本文の差分だけ**を取り出す純粋なデコーダ。**副作用なし＝テスト可能**。
/// 実際の受信は [[AIClient]] の URLSession デリゲートが担う。
///
/// チャンクは行の途中で切れて届くので、未完了の行は次の `consume` まで持ち越す。
/// `data:` 以外の行（`event:` ・コメント `:` ・空行）は捨てる＝プロバイダ差を吸収する。
struct AIStreamDecoder {
    let provider: AIProvider
    private var pending = Data()

    init(provider: AIProvider) { self.provider = provider }

    /// 届いたチャンクを食わせ、確定した行から取り出せたイベントを返す。
    mutating func consume(_ chunk: Data) -> [AIStreamEvent] {
        pending.append(chunk)
        var events: [AIStreamEvent] = []
        while let newline = pending.firstIndex(of: 0x0A) {   // \n
            let line = String(data: pending[..<newline], encoding: .utf8) ?? ""
            pending = Data(pending[pending.index(after: newline)...])
            events.append(contentsOf: self.events(fromLine: line))
        }
        return events
    }

    /// 受信終了。改行で終わらなかった最後の行を絞り出す。
    mutating func finish() -> [AIStreamEvent] {
        guard !pending.isEmpty else { return [] }
        let line = String(data: pending, encoding: .utf8) ?? ""
        pending = Data()
        return events(fromLine: line)
    }

    private func events(fromLine raw: String) -> [AIStreamEvent] {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }        // CRLF
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return [] }
        if payload == "[DONE]" { return [.done] }             // OpenAI の終端
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            return []
        }
        // 途中で降ってくるエラー（Anthropic の `event: error` 等）は三者共通の形。
        if let message = AIRequestBuilder.errorMessage(in: obj) { return [.failure(message)] }

        switch provider {
        case .anthropic:
            switch obj["type"] as? String {
            case "content_block_delta":
                guard let delta = obj["delta"] as? [String: Any],
                      (delta["type"] as? String) == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty else { return [] }
                return [.delta(text)]
            case "message_stop":
                return [.done]
            default:
                return []                                     // ping / message_start / usage 等
            }
        case .openAI:
            guard let choices = obj["choices"] as? [[String: Any]] else { return [] }
            let text = choices.compactMap { ($0["delta"] as? [String: Any])?["content"] as? String }.joined()
            return text.isEmpty ? [] : [.delta(text)]
        case .gemini:
            guard let candidates = obj["candidates"] as? [[String: Any]] else { return [] }
            let text = candidates.compactMap { candidate -> String? in
                guard let content = candidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else { return nil }
                return parts.compactMap { $0["text"] as? String }.joined()
            }.joined()
            return text.isEmpty ? [] : [.delta(text)]
        }
    }
}
