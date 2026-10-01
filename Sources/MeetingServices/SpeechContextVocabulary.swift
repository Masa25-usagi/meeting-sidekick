import Foundation

/// SFSpeechAudioBufferRecognitionRequest.contextualStrings 用の語彙管理および抽出ユーティリティ
public enum SpeechContextVocabulary: Sendable {
    /// 固定の基本技術語彙（音声認識の誤認を防ぐための基準辞書）
    public static let defaultBaseVocabulary: [String] = [
        "OCuLink",
        "eGPU",
        "NVLink",
        "RDMA",
        "RoCE",
        "CXL",
        "MCP",
        "Gemini",
        "Codex",
        "Antigravity"
    ]

    /// 音声認識を偏らせないための英語一般語除外リスト（ストップワード）
    public static let englishStopwords: Set<String> = [
        "the", "and", "or", "in", "on", "at", "to", "for", "of", "with", "by", "from", "up",
        "about", "into", "over", "after", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "shall", "should", "can",
        "could", "may", "might", "must", "that", "this", "these", "those", "what", "which",
        "who", "when", "where", "why", "how", "all", "any", "both", "each", "few", "more",
        "most", "other", "some", "such", "no", "nor", "not", "only", "own", "same", "so",
        "than", "too", "very", "just", "now", "true", "false", "null", "none", "test",
        "file", "path", "user", "name", "code", "data", "text", "type", "item", "list",
        "http", "https", "com", "org", "net", "app", "dev", "io", "src", "bin"
    ]

    /// テキストから専門用語・略語・英数字キーワード・カタカナ用語を抽出
    public static func extractKeywords(from text: String) -> [String] {
        var results: [String] = []
        var seen = Set<String>()

        // 1. 英数字・記号混じりの単語（例: "OCuLink", "eGPU", "Next.js", "WebRTC", "CI/CD", "SwiftUI"）
        // ※日本語混じりのテキストでは「eGPUなら」の「U」と「な」の間に \b が成立しないため、
        // 英数字で始まり英数字で終わるトークン（または2文字以上の英数字）を直接マッチ
        let alphaPattern = #"[A-Za-z0-9][A-Za-z0-9\._\+\-]{0,28}[A-Za-z0-9]|[A-Za-z0-9]{2,30}"#
        if let regex = try? NSRegularExpression(pattern: alphaPattern) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                var word = nsText.substring(with: match.range)
                word = word.trimmingCharacters(in: CharacterSet(charactersIn: ".-_+,:;()[]{}<>\"'`"))
                guard word.count >= 2, word.count <= 30 else { continue }
                // 純粋な数字のみ（例: 2026, 123）は除外
                guard !word.allSatisfy({ $0.isNumber }) else { continue }
                let lower = word.lowercased()
                guard !englishStopwords.contains(lower) else { continue }
                if seen.insert(lower).inserted {
                    results.append(word)
                }
            }
        }

        // 2. カタカナ専門用語（3文字以上、例: "プロトタイプ", "マイクロサービス", "アーキテクチャ", "インターコネクト"）
        let katakanaPattern = #"[\u30A1-\u30FA\u30FC]{3,20}"#
        if let regex = try? NSRegularExpression(pattern: katakanaPattern) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let word = nsText.substring(with: match.range)
                let lower = word.lowercased()
                if seen.insert(lower).inserted {
                    results.append(word)
                }
            }
        }

        return results
    }

    /// 基本語彙、会議の目的、プロジェクト文脈、直近の調査用語を動的にマージし、
    /// 重複排除の上、上限（50〜100語程度）に切り詰めて返却
    public static func buildContextualStrings(
        baseVocabulary: [String] = defaultBaseVocabulary,
        objective: String? = nil,
        projectContext: String? = nil,
        recentTerms: [String]? = nil,
        limit: Int = 100
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func addTerm(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 50 else { return }
            let lower = trimmed.lowercased()
            guard !seen.contains(lower) else { return }
            seen.insert(lower)
            result.append(trimmed)
        }

        // 1. 固定の基本語彙（最優先）
        for term in baseVocabulary {
            addTerm(term)
        }

        // 2. 直近の調査済み用語・進行中用語
        if let recentTerms {
            for term in recentTerms {
                addTerm(term)
            }
        }

        // 3. 会議の目的から抽出した語彙
        if let objective, !objective.isEmpty {
            for term in extractKeywords(from: objective) {
                addTerm(term)
            }
        }

        // 4. プロジェクトコンテキストから抽出した語彙
        if let projectContext, !projectContext.isEmpty {
            for term in extractKeywords(from: projectContext) {
                addTerm(term)
            }
        }

        let maxCap = max(10, min(limit, 100))
        return Array(result.prefix(maxCap))
    }
}

/// 音声認識候補 (transcriptions) からドメイン語彙の合致度に基づいて最良仮説を選択するセレクター
public enum SpeechTranscriptionSelector: Sendable {
    /// 2つの文字列間のレーベンシュタイン距離（編集距離）を算出
    public static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let (m, n) = (a.count, b.count)
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(0...n)
        for i in 1...m {
            var prev = dp[0]
            dp[0] = i
            for j in 1...n {
                let temp = dp[j]
                if a[i - 1] == b[j - 1] {
                    dp[j] = prev
                } else {
                    dp[j] = min(dp[j] + 1, dp[j - 1] + 1, prev + 1)
                }
                prev = temp
            }
        }
        return dp[n]
    }

    /// 候補がベスト仮説と十分に類似しているかを判定（乖離した別文の誤採用を防止）
    public static func isSufficientlySimilar(best: String, alt: String) -> Bool {
        let lenBest = best.count
        let lenAlt = alt.count
        guard lenBest > 0, lenAlt > 0 else { return false }

        // 1. 文字数比率チェック（0.5 <= ratio <= 2.0）
        let ratio = Double(lenAlt) / Double(lenBest)
        guard ratio >= 0.5 && ratio <= 2.0 else { return false }

        // 2. 編集距離による類似度算出
        let maxLen = max(lenBest, lenAlt)
        let dist = levenshteinDistance(best, alt)
        let similarity = 1.0 - (Double(dist) / Double(maxLen))

        // 用語置換（カタカナ→英字など）では前後の文脈が一致するため similarity >= 0.35 となる
        // 全く異なる文（例: 「今日の議題について話します」 vs 「OCuLink 昨日の夜ご飯」）は similarity < 0.2 となり棄却される
        return similarity >= 0.35
    }

    public static func selectCandidate(
        best: String,
        alternatives: [String],
        domainVocabulary: [String]
    ) -> (rawTranscript: String, normalizedTranscript: String) {
        let raw = best
        guard !domainVocabulary.isEmpty else {
            return (rawTranscript: raw, normalizedTranscript: raw)
        }

        let normalizedVocab = domainVocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        func score(_ text: String) -> Int {
            let lower = text.lowercased()
            var matches = 0
            for term in normalizedVocab {
                if lower.contains(term) {
                    matches += 1
                }
            }
            return matches
        }

        let bestScore = score(best)
        var selected = best
        var maxScore = bestScore

        for alt in alternatives {
            let s = score(alt)
            // 語彙スコアがベストより高く、かつベスト仮説と十分に類似している場合のみ採用
            if s > maxScore && isSufficientlySimilar(best: best, alt: alt) {
                maxScore = s
                selected = alt
            }
        }

        return (rawTranscript: raw, normalizedTranscript: selected)
    }
}
