import Foundation

/// ログ／テキストビューア特化の単発プロンプト群。**純関数＝テスト可能**。
/// 汎用チャットではなく「今見ている箇所に AI をぶつける」用途に絞る。
enum AIPrompts {

    /// 選択したエラー / スタックトレース / 謎のログ行の原因推測。
    /// - Parameter language: 回答に使う言語名（アプリの UI 言語。ログが英語でも利用者の言語で返す）。
    static func errorCause(_ selection: String, language: String) -> AIPrompt {
        let system = """
        You are a debugging assistant embedded in a log/text viewer. \
        Given a log excerpt, stack trace, or error message, explain concisely: \
        (1) what went wrong, (2) the most likely root cause, (3) one concrete next step to fix or investigate. \
        Reply in \(language), regardless of the language of the excerpt. \
        Be brief and specific; do not repeat the input back. \
        Use plain text only — no Markdown, no asterisks, no backticks, no headings. \
        Do not include internal or system XML tags in your response.
        """
        // 2048: 推論系モデル（Gemini flash-latest 等）は思考にトークンを使い、1024 だと回答が途中で切れることがある。
        return AIPrompt(system: system, user: selection, maxTokens: 2048)
    }

    /// 接続テスト（環境設定の「接続テスト」ボタン）。
    /// キー・モデル ID・ベース URL・SSE 受信までを、**本番と同じ経路**で一往復して確かめる。
    /// 答えの中身は見ない（届いたこと自体が答え）ので、いちばん短い返事を頼む。
    static func connectionTest() -> AIPrompt {
        let system = "Reply with exactly the two characters: OK"
        // 上限は「思考＋本文」の合計＝推論系モデル（Gemini flash・OpenAI o 系・思考が切れない
        // Claude Fable 等）は思考で食い切り、鍵が正しいのに本文が空＝失敗表示になりうる。
        // 上限は課金されない（実際に使った分だけ）ので、診断と同じだけ余裕を持たせる。
        return AIPrompt(system: system, user: "ping", maxTokens: 2048)
    }

    /// 自然文 → 正規表現。検索／フィルタ窓へそのまま流し込むため、regex 本体だけを返させる。
    static func naturalLanguageToRegex(_ description: String) -> AIPrompt {
        let system = """
        You convert a natural-language description into a single regular expression \
        for searching and filtering log lines. Output ONLY the regular expression itself — \
        no explanation, no code fences, no surrounding delimiters, no flags. \
        Use ICU / NSRegularExpression syntax (the viewer supports lookahead and lookbehind).
        """
        // 出力の regex 自体は短いが、推論系モデル（Gemini flash-latest 等）は思考にトークンを使うため、
        // 256 だと思考で使い切って出力が空になる。余裕を持たせる（regex 本体だけ抽出するので無駄は少ない）。
        return AIPrompt(system: system, user: description, maxTokens: 1024)
    }

    /// モデル出力から regex 本体を取り出す（コードフェンス・囲みスラッシュ・前後空白・説明行を剥がす）。
    /// モデルが指示を守らず ```regex ``` や `/pattern/` で包んでも検索窓に入れられる形へ整える。
    static func extractRegex(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // ```...``` フェンスを剥がす。
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])            // ```regex 行を落とす
            } else {
                s = String(s.dropFirst(3))
            }
            if let close = s.range(of: "```", options: .backwards) {
                s = String(s[..<close.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 複数行が残ったら最初の非空行を採る（説明が混ざった場合の保険）。
        if let firstLine = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            s = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // /pattern/ の囲みスラッシュを剥がす。
        if s.count >= 2, s.hasPrefix("/"), let last = s.lastIndex(of: "/"), last != s.startIndex {
            let inner = String(s[s.index(after: s.startIndex)..<last])
            if !inner.isEmpty { s = inner }
        }
        return s
    }
}
