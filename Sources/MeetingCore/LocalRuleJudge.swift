import Foundation

/// A deliberately limited, inspectable fallback for demos and API-free operation.
/// Keyword matching cannot provide a general understanding of meeting intent.
public enum LocalRuleJudge {
    public static func evaluate(event: TranscriptEvent, policy: MeetingPolicy) -> Judgment {
        guard event.source != .assistant, event.isFinal else { return Judgment() }
        let text = RuleText.normalized(event.text)
        guard !text.isEmpty else { return Judgment() }
        var result = Judgment(topic: String(event.text.prefix(120)))

        let nickname = RuleText.normalized(policy.nickname)
        if !nickname.isEmpty, RuleText.containsName(nickname, in: text) {
            result.wakeScore = 1
        }

        if RuleText.requestsStop(text), !RuleText.negatesStop(text) {
            result.stopScore = 1
            return result
        }

        if !RuleText.negatesCreation(text) {
            let isDoNotBuild = policy.doNotBuildCriteria.contains { criterion in
                let norm = RuleText.normalized(criterion)
                guard !norm.isEmpty else { return false }
                return text.contains(norm)
            }

            if isDoNotBuild {
                result.buildScore = 0
            } else if RuleText.containsAny(text, ["作って", "作成して", "実装して", "試作して", "組んで", "build an", "build a ", "create an", "create a ", "make an app", "make a prototype"]) {
                result.buildScore = 0.95
            } else if RuleText.containsAny(text, ["あったらいい", "あったら便利", "あると便利", "できたらいい", "欲しい", "ほしい", "作りたい", "wish we had", "need an app"]),
                      matchesObjective(text, objective: RuleText.normalized(policy.objective)) {
                result.buildScore = 0.8
            } else if !policy.buildCriteria.isEmpty, matchesCriteria(text, criteria: policy.buildCriteria) {
                result.buildScore = 0.85
            }
        }

        if !RuleText.negatesModification(text),
           RuleText.containsAny(text, ["修正して", "変更して", "変えて", "直して", "代わりに", "modify the", "change the", "update the"]) {
            result.modifyScore = 0.95
        }
        if RuleText.containsAny(text, ["どう思う", "意見を", "ツッコミ", "反論して", "問題点を", "what do you think"]) {
            result.speakScore = 0.85
        } else if !policy.speakCriteria.isEmpty, matchesCriteria(text, criteria: policy.speakCriteria) {
            result.speakScore = 0.85
        }

        let isThinkRequested = RuleText.containsAny(text, ["深く考えて", "考えてみて", "考えて", "比較して", "検討して", "整理して", "計画を立てて", "設計を考えて", "どちらがいい", "トレードオフ", "think about", "plan this", "compare"])
        let isConditionalBuild = RuleText.containsAny(text, ["良さそうなら作", "良ければ作", "いけそうなら作", "問題なければ作", "可能性があれば作", "実用的なら作", "実用的なら試作", "実用的であれば", "使えそうなら", "なら作", "なら試作", "build if viable", "if good then build", "if it looks good"])

        if RuleText.containsAny(text, ["要約して", "まとめて", "論点を整理", "これまでの話", "経緯を整理", "summarize", "recap"]) {
            result.summaryScore = 0.9
        }

        result.requestsDeepThinking = RuleText.requestsDeepThinking(text)
        if isThinkRequested {
            result.thinkScore = 0.9
            if isConditionalBuild {
                result.thinkMode = "think_then_decide"
                // 最初のイベントで直接buildを開始させないためbuildScoreは抑制
                result.buildScore = 0
            } else {
                result.thinkMode = "think_only"
                result.buildScore = 0
            }
        } else if result.buildScore >= 0.7 {
            result.thinkMode = "build"
        }
        return result
    }

    private static func matchesCriteria(_ text: String, criteria: [String]) -> Bool {
        criteria.contains { criterion in
            let norm = RuleText.normalized(criterion)
            guard !norm.isEmpty else { return false }
            if norm.count >= 3 && text.contains(norm) { return true }
            let tokens = norm.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
            return !tokens.isEmpty && tokens.contains { text.contains($0) }
        }
    }

    private static func matchesObjective(_ text: String, objective: String) -> Bool {
        guard !objective.isEmpty else { return false }
        let concreteTopics = ["アプリ", "ツール", "サイト", "議事録", "カレンダー", "タスク", "通知", "メモ", "ゲーム", "予約", "家計", "翻訳", "文字起こし", "チャット", "ダッシュボード"]
        if concreteTopics.contains(where: { objective.contains($0) && text.contains($0) }) { return true }
        let tokens = objective.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return tokens.contains { token in
            token.count >= 4 && token.unicodeScalars.allSatisfy({ $0.isASCII })
                && RuleText.containsName(token, in: text)
        }
    }
}

public enum RuleText {
    public static func normalized(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains(where: text.contains)
    }

    static func containsName(_ name: String, in text: String) -> Bool {
        if name.unicodeScalars.allSatisfy({ $0.isASCII }), name.rangeOfCharacter(from: .alphanumerics) != nil {
            let pattern = "(?<![a-z0-9_])" + NSRegularExpression.escapedPattern(for: name) + "(?![a-z0-9_])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        return text.contains(name)
    }

    static func requestsCreation(_ text: String) -> Bool {
        containsAny(text, ["作って", "作成して", "実装して", "試作して", "組んで", "build an", "build a ", "create an", "create a ", "make an app", "make a prototype"])
    }

    static func negatesCreation(_ text: String) -> Bool {
        containsAny(text, ["作らない", "作らなく", "作らなくて", "作ってほしくない", "作るな", "作成しない", "作成しなく", "実装しない", "実装しなく", "試作しない", "作るのはやめ", "作るのをやめ", "作成は不要", "実装は不要", "don't build", "do not build", "don't create", "do not create", "don't make", "do not make", "no need to build", "no need to create", "not build"])
            || requestsStop(text)
    }

    static func negatesModification(_ text: String) -> Bool {
        containsAny(text, ["変えない", "変更しない", "変更しなく", "修正しない", "直さない", "don't change", "do not change", "don't modify", "do not modify", "don't update", "do not update"])
    }

    static func negatesStop(_ text: String) -> Bool {
        containsAny(text, ["止めない", "やめない", "停止しない", "中止しない", "キャンセルしない", "don't stop", "do not stop", "don't cancel", "do not cancel", "never stop"])
    }

    static func requestsStop(_ text: String) -> Bool {
        containsAny(text, ["止めて", "やめて", "停止して", "中止して", "キャンセルして", "ストップ", "作らないで", "作成しないで", "実装しないで"])
            || text.range(of: "\\b(stop|cancel|abort)\\b", options: .regularExpression) != nil
    }

    /// 明示的な深い思考・比較・計画要求の判定（名前呼び単独の短い質問と区別）
    static func requestsDeepThinking(_ text: String) -> Bool {
        containsAny(text, [
            "深く考えて", "深く検討", "比較して", "検討して", "計画して",
            "比較検討", "アーキテクチャ", "設計して", "論理的に考えて", "深掘りして",
            "プランを練って", "メリットと問題点", "トレードオフ", "長所と短所",
            "think deeply", "compare", "plan", "analyze", "tradeoff"
        ])
    }

    /// 一般的すぎる技術用語・略語の判定（調査の二重防御用）
    public static let commonGenericTerms: Set<String> = [
        "api", "json", "ai", "ui", "ux", "web", "http", "https", "pc", "os", "app", "apps",
        "database", "db", "server", "client", "html", "css", "js", "sql", "rest", "crud",
        "cpu", "gpu", "ram", "url", "uri", "ip", "dns", "sdk", "cli", "gui", "cloud",
        "アプリ", "サーバー", "データベース", "クライアント", "ウェブ", "ネット", "パソコン", "クラウド"
    ]

    public static func isCommonGenericTerm(_ term: String) -> Bool {
        let norm = normalized(term)
        guard !norm.isEmpty else { return true }
        if commonGenericTerms.contains(norm) { return true }
        let tokens = norm.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if !tokens.isEmpty && tokens.allSatisfy({ commonGenericTerms.contains($0) }) {
            return true
        }
        return false
    }
}

