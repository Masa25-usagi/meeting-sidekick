import Foundation

/// 制作ジョブの開始可否を判定する中央ゲート
public struct ExecutionGate: Sendable {
    public static func evaluate(
        candidate: BuildCandidate,
        policy: MeetingPolicy,
        activeJobID: String?,
        totalJobs: Int
    ) -> GateEvaluation {
        let normTopic = RuleText.normalized(candidate.topic)

        // 1. 禁止・見送り基準 (doNotBuildCriteria) の多面的照合（全文部分一致 + トークン照合）
        if let matchedCriterion = findMatchingDoNotBuildCriterion(topic: normTopic, criteria: policy.doNotBuildCriteria) {
            return GateEvaluation(decision: .rejected, reason: "見送り基準「\(matchedCriterion)」に該当するため制作を却下しました。", candidate: candidate)
        }

        // 2. 否定・停止指示の照合
        if RuleText.negatesCreation(normTopic) || RuleText.requestsStop(normTopic) {
            return GateEvaluation(decision: .rejected, reason: "制作取りやめ・停止指示を検出したため却下しました。", candidate: candidate)
        }

        // 3. 最大ジョブ数上限チェック
        if totalJobs >= max(1, policy.maxJobs) {
            return GateEvaluation(decision: .rejected, reason: "制作可能数（上限 \(policy.maxJobs)件）に達しています。", candidate: candidate)
        }

        // 4. 実行中ジョブ (activeJobID) の deterministic check:
        // 制作は1件ずつ直列実行するため、既に実行中のジョブがある場合は新規ジョブを保留 (defer)
        if let active = activeJobID, !active.isEmpty {
            return GateEvaluation(decision: .deferred, reason: "現在制作ジョブ（\(active)）が実行中のため、完了まで新規試作を保留（defer）しました。", candidate: candidate)
        }

        // 5. 自動試作設定がオフで、手動明示依頼でない場合（音声AIからの提案も含め、autoBuildがオフなら保留）
        if !policy.autoBuild, candidate.origin != "manual" {
            return GateEvaluation(decision: .deferred, reason: "自動試作がオフに設定されているため制作を保留しました。", candidate: candidate)
        }

        return GateEvaluation(decision: .approved, reason: "制作ゲートを通過しました。", candidate: candidate)
    }

    /// 見送り基準の柔軟かつ厳格な照合（単純な全文一致に加え、主要概念トークンの重なりを判定）
    private static func findMatchingDoNotBuildCriterion(topic: String, criteria: [String]) -> String? {
        let genericTokens: Set<String> = ["連携", "作成", "実装", "開発", "機能", "画面", "アプリ", "ツール", "対応", "利用", "ユーザー"]
        for criterion in criteria {
            let norm = RuleText.normalized(criterion)
            guard !norm.isEmpty else { continue }
            // 1. 直接のsubstring一致
            if topic.contains(norm) { return criterion }

            // 2. 文字種別（漢字・カタカナ・英数字）に基づく意味トークン抽出
            let tokens = extractSemanticTokens(from: norm)
            if !tokens.isEmpty {
                for token in tokens {
                    // 一般的な補助語でなく、長さが2以上の主要概念トークン（例: "決済", "認証基盤", "課金", "api"）がトピックに含まれるか
                    if !genericTokens.contains(token) && token.count >= 2 {
                        if topic.contains(token) {
                            return criterion
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func extractSemanticTokens(from text: String) -> [String] {
        var tokens: [String] = []
        var currentChunk = ""
        var currentCategory = 0 // 1: Kanji, 2: Katakana, 3: Alphanumeric

        func category(for scalar: Unicode.Scalar) -> Int {
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                return 1 // Kanji
            } else if (0x30A0...0x30FF).contains(scalar.value) {
                return 2 // Katakana
            } else if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                return 3 // ASCII alphanumeric
            } else {
                return 0 // Hiragana, symbols, whitespace
            }
        }

        for scalar in text.unicodeScalars {
            let cat = category(for: scalar)
            if cat != 0 && cat == currentCategory {
                currentChunk.unicodeScalars.append(scalar)
            } else {
                if currentChunk.count >= 2 && currentCategory != 0 {
                    tokens.append(currentChunk.lowercased())
                }
                if cat != 0 {
                    currentChunk = String(scalar)
                    currentCategory = cat
                } else {
                    currentChunk = ""
                    currentCategory = 0
                }
            }
        }
        if currentChunk.count >= 2 && currentCategory != 0 {
            tokens.append(currentChunk.lowercased())
        }
        return tokens
    }
}

/// Deterministic execution gates around either a remote judge or the limited local rules.
/// This does not grant authority to perform external actions; workers must enforce their scope.
public struct DecisionRouter: Sendable {
    private var processedIDs: Set<String> = []
    private var processedOrder: [String] = []
    private var lastActionAt: [DecisionAction: Date] = [:]
    private let staleAfterSeconds: TimeInterval

    public init(staleAfterSeconds: TimeInterval = 45) {
        self.staleAfterSeconds = staleAfterSeconds.isFinite ? max(0, staleAfterSeconds) : 45
    }

    public mutating func route(event: TranscriptEvent, judgment: Judgment, policy: MeetingPolicy,
                               activeJobID: String?, totalJobs: Int, now: Date = Date()) -> [Decision] {
        // Partial IDs must remain eligible when their final transcription arrives.
        guard event.isFinal, event.source != .assistant,
              !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !event.id.isEmpty, !processedIDs.contains(event.id) else { return [] }
        let age = now.timeIntervalSince(event.timestamp)
        guard age.isFinite, age <= staleAfterSeconds, age >= -10 else { return [] }
        remember(event.id)

        let threshold = policy.threshold.isFinite ? min(1, max(0, policy.threshold)) : 0.7
        func passes(_ score: Double) -> Bool { score.isFinite && score > 0 && score >= threshold }
        let text = RuleText.normalized(event.text)
        let topic = String((judgment.topic.isEmpty ? event.text : judgment.topic).prefix(240))
        func decision(_ action: DecisionAction, _ reason: String) -> Decision {
            Decision(action: action, reason: reason, evidenceID: event.id, topic: topic)
        }

        // Cancellation is never delayed by creation limits or an earlier action's cooldown.
        if passes(judgment.stopScore), !RuleText.negatesStop(text) {
            return [decision(.stop, "停止の判断を優先しました。")]
        }

        var results: [Decision] = []
        let isWake = passes(judgment.wakeScore)
        if isWake {
            results.append(decision(.wake, "呼びかけを検出しました。"))
        }

        let cooldown = policy.cooldownSeconds.isFinite ? max(0, policy.cooldownSeconds) : 20
        func isReady(_ action: DecisionAction) -> Bool {
            guard let last = lastActionAt[action] else { return true }
            return now.timeIntervalSince(last) >= cooldown
        }

        // Explicit cancellation/negative creation language wins over an erroneous build score.
        let creationIsNegated = RuleText.negatesCreation(text)
        let modificationIsNegated = RuleText.negatesModification(text)
        let explicitDeepThinking = judgment.requestsDeepThinking || RuleText.requestsDeepThinking(text)

        // wake と think の協調ポリシー:
        // - 通常の呼びかけ・短い意見質問（「どう思う？」「どうかな」等）は wake 優先（thinkは抑制して二重起動を防止）
        // - 明示的に「深く考えて」「比較して」「計画して」等を要求した場合は think / think_then_decide
        // - 名前を呼びながら明示的に深い思考を要求した場合のみ、wake + think の同時起動を許可
        let thinkAllowed = !isWake || explicitDeepThinking
        let thinkEligible = passes(judgment.thinkScore) && isReady(.think) && thinkAllowed
        let mode = judgment.thinkMode.isEmpty
            ? (thinkEligible && passes(judgment.buildScore) ? (RuleText.requestsCreation(text) ? "think_then_decide" : "think_only") : (thinkEligible ? "think_only" : (passes(judgment.buildScore) ? "build" : "")))
            : judgment.thinkMode

        if activeJobID != nil, passes(judgment.modifyScore), !modificationIsNegated,
           !creationIsNegated, isReady(.modify) {
            results.append(decision(.modify, "進行中の制作への変更を検出しました。"))
            lastActionAt[.modify] = now
        } else if mode == "think_only", thinkEligible {
            // 1. think_only: 思考・比較・計画のみ。制作は行わない
            results.append(decision(.think, "未解決の疑問・設計・計画の検討が必要と判断されました。"))
            lastActionAt[.think] = now
        } else if mode == "think_then_decide", thinkEligible {
            // 2. think_then_decide: まず思考・比較を行い、結果を受けてから制作可否を判断する（初期イベントで同時buildは行わない）
            results.append(decision(.thinkThenDecide, "比較・検討を行い、結果を踏まえて制作可否を判断します。"))
            lastActionAt[.think] = now
        } else if mode == "build" || (mode.isEmpty && passes(judgment.buildScore) && !creationIsNegated) {
            // 3. build: 共通ExecutionGateで厳格に審査
            let candidate = BuildCandidate(topic: topic, origin: "meeting_transcript", evidenceID: event.id, timestamp: now)
            let gateEval = ExecutionGate.evaluate(candidate: candidate, policy: policy, activeJobID: activeJobID, totalJobs: totalJobs)
            if gateEval.decision == .approved, isReady(.build) {
                results.append(decision(.build, "会議目的に沿う制作候補として判断されました。"))
                lastActionAt[.build] = now
            }
        }

        // A wake and a proactive utterance must not start two voice sessions for one event.
        if policy.proactiveSpeech, !results.contains(where: { $0.action == .wake }),
           passes(judgment.speakScore), isReady(.speak) {
            results.append(decision(.speak, "発話候補を検出しました。発話タイミングは音声側で調整します。"))
            lastActionAt[.speak] = now
        }

        // 専門用語・略語の調査判定（JEVのtermResearchScoreが閾値以上）
        let researchTriggered = passes(judgment.termResearchScore)
        if researchTriggered {
            results.append(decision(.researchTerm, "発話に含まれる専門用語・略語の調査が必要と判断されました。"))
            // 用語調査が発火した場合、ユーザーが「深く考えて」「検討して」等と言っていない限り、
            // 一般的な思考 (think) は抑止する (researchTermのみ発火)。
            if !explicitDeepThinking {
                results.removeAll { $0.action == .think || $0.action == .thinkThenDecide }
            }
        }

        return results
    }

    /// 会議リセットや制作停止時にルーターの内部状態を初期化
    public mutating func reset() {
        processedIDs.removeAll()
        processedOrder.removeAll()
        lastActionAt.removeAll()
    }

    private mutating func remember(_ id: String) {
        processedIDs.insert(id)
        processedOrder.append(id)
        // A bounded replay cache is sufficient because old timestamps are separately rejected.
        if processedOrder.count > 4_096 {
            let removed = processedOrder.removeFirst()
            processedIDs.remove(removed)
        }
    }
}
