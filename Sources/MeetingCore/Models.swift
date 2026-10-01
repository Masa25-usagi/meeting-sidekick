import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, meeting, assistant, manual, mobile
}

public struct TranscriptEvent: Codable, Equatable, Sendable {
    public var id: String
    public var rawTranscript: String
    public var normalizedTranscript: String
    public var text: String {
        get { normalizedTranscript }
        set {
            normalizedTranscript = newValue
            if rawTranscript.isEmpty { rawTranscript = newValue }
        }
    }
    public var source: AudioSource
    public var isFinal: Bool
    public var timestamp: Date

    public init(id: String = UUID().uuidString, text: String = "", rawTranscript: String? = nil,
                source: AudioSource = .microphone, isFinal: Bool = true, timestamp: Date = Date()) {
        self.id = id
        self.normalizedTranscript = text
        self.rawTranscript = rawTranscript ?? text
        self.source = source
        self.isFinal = isFinal
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case id, text, rawTranscript, normalizedTranscript, source, isFinal, timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let decodedText = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        let decodedNormalized = try container.decodeIfPresent(String.self, forKey: .normalizedTranscript) ?? decodedText
        normalizedTranscript = decodedNormalized
        rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript) ?? decodedText
        source = try container.decode(AudioSource.self, forKey: .source)
        isFinal = try container.decode(Bool.self, forKey: .isFinal)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(rawTranscript, forKey: .rawTranscript)
        try container.encode(normalizedTranscript, forKey: .normalizedTranscript)
        try container.encode(source, forKey: .source)
        try container.encode(isFinal, forKey: .isFinal)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

public struct MeetingPolicy: Codable, Equatable, Sendable {
    public var objective: String
    public var nickname: String
    public var memory: String
    public var autoBuild: Bool
    public var proactiveSpeech: Bool
    public var maxJobs: Int
    public var cooldownSeconds: Double
    public var threshold: Double

    public var persona: String
    public var speakCriteria: [String]
    public var buildCriteria: [String]
    public var doNotBuildCriteria: [String]
    public var projectContext: String

    public init(objective: String = "", nickname: String = "サイドキック", memory: String = "",
                autoBuild: Bool = true, proactiveSpeech: Bool = false, maxJobs: Int = 3,
                cooldownSeconds: Double = 20, threshold: Double = 0.7,
                persona: String = "",
                speakCriteria: [String] = [],
                buildCriteria: [String] = [],
                doNotBuildCriteria: [String] = [],
                projectContext: String = "") {
        self.objective = objective
        self.nickname = nickname
        self.memory = memory
        self.autoBuild = autoBuild
        self.proactiveSpeech = proactiveSpeech
        self.maxJobs = maxJobs
        self.cooldownSeconds = cooldownSeconds
        self.threshold = threshold
        self.persona = persona
        self.speakCriteria = speakCriteria
        self.buildCriteria = buildCriteria
        self.doNotBuildCriteria = doNotBuildCriteria
        self.projectContext = projectContext
    }
}

public struct SynthesizedRules: Codable, Equatable, Sendable {
    public var objective: String
    public var nickname: String
    public var persona: String
    public var speakCriteria: [String]
    public var buildCriteria: [String]
    public var doNotBuildCriteria: [String]
    public var projectSummary: String
    public var rawText: String

    public init(
        objective: String = "",
        nickname: String = "サイドキック",
        persona: String = "",
        speakCriteria: [String] = [],
        buildCriteria: [String] = [],
        doNotBuildCriteria: [String] = [],
        projectSummary: String = "",
        rawText: String = ""
    ) {
        self.objective = objective
        self.nickname = nickname
        self.persona = persona
        self.speakCriteria = speakCriteria
        self.buildCriteria = buildCriteria
        self.doNotBuildCriteria = doNotBuildCriteria
        self.projectSummary = projectSummary
        self.rawText = rawText
    }

    public var formattedMarkdown: String {
        var parts: [String] = []
        if !persona.isEmpty {
            parts.append("### 🎭 役割・キャラクター\n\(persona)")
        }
        if !speakCriteria.isEmpty {
            parts.append("### 💬 ツッコミ・発言の判断基準\n" + speakCriteria.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !buildCriteria.isEmpty {
            parts.append("### 🛠️ 自動試作に着手する基準\n" + buildCriteria.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !doNotBuildCriteria.isEmpty {
            parts.append("### 🚫 自動試作しない・見送る基準\n" + doNotBuildCriteria.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !projectSummary.isEmpty {
            parts.append("### 📚 参照プロジェクト・事前コンテキスト要約\n\(projectSummary)")
        }
        return parts.joined(separator: "\n\n")
    }
}

public struct Judgment: Codable, Equatable, Sendable {
    public var wakeScore: Double
    public var buildScore: Double
    public var modifyScore: Double
    public var stopScore: Double
    public var speakScore: Double
    public var thinkScore: Double
    public var summaryScore: Double
    public var termResearchScore: Double
    public var requestsDeepThinking: Bool
    public var thinkMode: String
    public var topic: String

    public var shouldSummarize: Bool { summaryScore >= 0.7 }

    public init(wakeScore: Double = 0, buildScore: Double = 0, modifyScore: Double = 0,
                stopScore: Double = 0, speakScore: Double = 0, thinkScore: Double = 0,
                summaryScore: Double = 0, termResearchScore: Double = 0,
                requestsDeepThinking: Bool = false,
                thinkMode: String = "", topic: String = "") {
        self.wakeScore = wakeScore
        self.buildScore = buildScore
        self.modifyScore = modifyScore
        self.stopScore = stopScore
        self.speakScore = speakScore
        self.thinkScore = thinkScore
        self.summaryScore = summaryScore
        self.termResearchScore = termResearchScore
        self.requestsDeepThinking = requestsDeepThinking
        self.thinkMode = thinkMode
        self.topic = topic
    }

    enum CodingKeys: String, CodingKey {
        case wakeScore, buildScore, modifyScore, stopScore, speakScore
        case thinkScore, summaryScore, termResearchScore, requestsDeepThinking
        case thinkMode, topic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wakeScore = try c.decodeIfPresent(Double.self, forKey: .wakeScore) ?? 0
        buildScore = try c.decodeIfPresent(Double.self, forKey: .buildScore) ?? 0
        modifyScore = try c.decodeIfPresent(Double.self, forKey: .modifyScore) ?? 0
        stopScore = try c.decodeIfPresent(Double.self, forKey: .stopScore) ?? 0
        speakScore = try c.decodeIfPresent(Double.self, forKey: .speakScore) ?? 0
        thinkScore = try c.decodeIfPresent(Double.self, forKey: .thinkScore) ?? 0
        summaryScore = try c.decodeIfPresent(Double.self, forKey: .summaryScore) ?? 0
        termResearchScore = try c.decodeIfPresent(Double.self, forKey: .termResearchScore) ?? 0
        requestsDeepThinking = try c.decodeIfPresent(Bool.self, forKey: .requestsDeepThinking) ?? false
        thinkMode = try c.decodeIfPresent(String.self, forKey: .thinkMode) ?? ""
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wakeScore, forKey: .wakeScore)
        try container.encode(buildScore, forKey: .buildScore)
        try container.encode(modifyScore, forKey: .modifyScore)
        try container.encode(stopScore, forKey: .stopScore)
        try container.encode(speakScore, forKey: .speakScore)
        try container.encode(thinkScore, forKey: .thinkScore)
        try container.encode(summaryScore, forKey: .summaryScore)
        try container.encode(termResearchScore, forKey: .termResearchScore)
        try container.encode(requestsDeepThinking, forKey: .requestsDeepThinking)
        try container.encode(thinkMode, forKey: .thinkMode)
        try container.encode(topic, forKey: .topic)
    }
}

public enum DecisionAction: String, Codable, CaseIterable, Sendable {
    case wake, speak, think, thinkThenDecide, build, modify, stop, researchTerm
}

public struct Decision: Codable, Equatable, Sendable {
    public var action: DecisionAction
    public var reason: String
    public var evidenceID: String
    public var topic: String

    public init(action: DecisionAction, reason: String, evidenceID: String, topic: String = "") {
        self.action = action
        self.reason = reason
        self.evidenceID = evidenceID
        self.topic = topic
    }
}

public struct BuildCandidate: Codable, Equatable, Sendable {
    public var id: String
    public var topic: String
    public var origin: String // "voice_tool", "meeting_transcript", "think_then_decide", "manual"
    public var evidenceID: String
    public var timestamp: Date

    public init(id: String = UUID().uuidString, topic: String, origin: String = "meeting_transcript",
                evidenceID: String = "", timestamp: Date = Date()) {
        self.id = id
        self.topic = topic
        self.origin = origin
        self.evidenceID = evidenceID
        self.timestamp = timestamp
    }
}

public enum GateDecision: String, Codable, Sendable {
    case approved, rejected, deferred
}

public struct GateEvaluation: Codable, Equatable, Sendable {
    public var decision: GateDecision
    public var reason: String
    public var candidate: BuildCandidate

    public init(decision: GateDecision, reason: String, candidate: BuildCandidate) {
        self.decision = decision
        self.reason = reason
        self.candidate = candidate
    }
}

public struct ThinkingNote: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var timestamp: Date
    public var topic: String
    public var content: String
    public var triggersBuildIfViable: Bool

    public init(id: String = UUID().uuidString.prefix(8).lowercased(), timestamp: Date = Date(),
                topic: String, content: String, triggersBuildIfViable: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.topic = topic
        self.content = content
        self.triggersBuildIfViable = triggersBuildIfViable
    }
}

public extension CodingUserInfoKey {
    /// Enable only when decoding the app's own saved research metadata, never model output.
    static let trustedResearchProvenance = CodingUserInfoKey(rawValue: "MeetingSidekick.trustedResearchProvenance")!
}

public struct ResearchSource: Codable, Equatable, Sendable, Hashable {
    public var title: String
    public var url: String
    public var isVerifiedToolSource: Bool

    public init(title: String, url: String, isVerifiedToolSource: Bool = false) {
        self.title = title
        self.url = url
        self.isVerifiedToolSource = isVerifiedToolSource
    }

    public enum CodingKeys: String, CodingKey {
        case title, url, isVerifiedToolSource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        let savedFlag = try c.decodeIfPresent(Bool.self, forKey: .isVerifiedToolSource) ?? false
        isVerifiedToolSource = (decoder.userInfo[.trustedResearchProvenance] as? Bool == true) && savedFlag
    }

    /// URLの安全性検証: httpまたはhttpsスキームのみを許可（file://, javascript:, data: 等は除外）
    public static func isValidWebURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        guard let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }

    /// 安全なWeb URLのみを抽出し、重複排除して最大件数（既定3件）に制限
    /// 将来的なCodexのweb-search toolイベント由来URLとの照合余地（verifiedToolURLs）をサポート
    public static func sanitize(
        _ sources: [ResearchSource],
        verifiedToolURLs: Set<String>? = nil,
        maxCount: Int = 3,
        preserveVerifiedSources: Bool = false
    ) -> [ResearchSource] {
        guard maxCount > 0 else { return [] }
        func provenanceKey(_ raw: String) -> String? {
            guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            parts.scheme = parts.scheme?.lowercased()
            parts.host = parts.host?.lowercased()
            return parts.string // Paths and query strings are case sensitive.
        }
        var seenURLs = Set<String>()
        var sanitized: [ResearchSource] = []

        for source in sources {
            let cleanURL = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidWebURL(cleanURL) else { continue }

            let normalizedURL = cleanURL.lowercased()
            guard !seenURLs.contains(normalizedURL) else { continue }
            seenURLs.insert(normalizedURL)

            let cleanTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // Model extraction always enters with unverified flags. Only observed
            // tool URLs, or an explicitly trusted internal copy, preserve provenance.
            let isVerified = verifiedToolURLs?.contains(where: {
                provenanceKey($0) == provenanceKey(cleanURL)
            }) ?? (preserveVerifiedSources && source.isVerifiedToolSource)

            sanitized.append(ResearchSource(
                title: cleanTitle.isEmpty ? cleanURL : cleanTitle,
                url: cleanURL,
                isVerifiedToolSource: isVerified
            ))

            if sanitized.count >= maxCount {
                break
            }
        }

        return sanitized
    }
}

public struct ResearchNote: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var timestamp: Date
    public var term: String
    public var summary: String
    public var detail: String
    public var sourceEngine: String
    public var evidenceText: String
    public var sources: [ResearchSource]
    public var backend: String
    public var resolvedModel: String
    public var reasoningEffort: String
    public var webSearchMode: String
    public var webSearchRequested: Bool
    public var webSearchUsed: Bool?

    public enum CodingKeys: String, CodingKey {
        case id, timestamp, term, summary, detail, sourceEngine, evidenceText, sources
        case backend, resolvedModel, reasoningEffort, webSearchMode
        case webSearchRequested, webSearchUsed
    }

    public init(
        id: String = UUID().uuidString.prefix(8).lowercased(),
        timestamp: Date = Date(),
        term: String,
        summary: String,
        detail: String,
        sourceEngine: String = "codex",
        evidenceText: String = "",
        sources: [ResearchSource] = [],
        backend: String = "app-server",
        resolvedModel: String = "",
        reasoningEffort: String = "low",
        webSearchMode: String = "live",
        webSearchRequested: Bool = false,
        webSearchUsed: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.term = term
        self.summary = summary
        self.detail = detail
        self.sourceEngine = sourceEngine
        self.evidenceText = evidenceText
        self.sources = ResearchSource.sanitize(sources, preserveVerifiedSources: true)
        self.backend = backend
        self.resolvedModel = resolvedModel
        self.reasoningEffort = reasoningEffort
        self.webSearchMode = webSearchMode
        self.webSearchRequested = webSearchRequested
        self.webSearchUsed = webSearchUsed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.prefix(8).lowercased()
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        term = try c.decodeIfPresent(String.self, forKey: .term) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        sourceEngine = try c.decodeIfPresent(String.self, forKey: .sourceEngine) ?? "codex"
        evidenceText = try c.decodeIfPresent(String.self, forKey: .evidenceText) ?? ""
        let rawSources = try c.decodeIfPresent([ResearchSource].self, forKey: .sources) ?? []
        sources = ResearchSource.sanitize(rawSources, preserveVerifiedSources: true)
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? "app-server"
        resolvedModel = try c.decodeIfPresent(String.self, forKey: .resolvedModel) ?? ""
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? "low"
        webSearchMode = try c.decodeIfPresent(String.self, forKey: .webSearchMode) ?? "live"
        webSearchRequested = try c.decodeIfPresent(Bool.self, forKey: .webSearchRequested) ?? false
        webSearchUsed = try c.decodeIfPresent(Bool.self, forKey: .webSearchUsed)
    }

    public var diagnosticsSummary: String {
        let b = backend.isEmpty ? "codex" : backend
        let m = resolvedModel.isEmpty ? sourceEngine : resolvedModel
        let e = reasoningEffort.isEmpty ? "low" : reasoningEffort
        let s = webSearchMode.isEmpty ? "live" : webSearchMode
        let usedStr = webSearchUsed.map { String($0) } ?? "unknown"
        return "\(b) · \(m) · effort:\(e) · web_search:\(s) (req:\(webSearchRequested), used:\(usedStr), sources:\(sources.count))"
    }
}

public struct ThoughtRecommendation: Codable, Equatable, Sendable {
    public var recommend_build: Bool
    public var decision_reason: String

    public init(recommend_build: Bool, decision_reason: String) {
        self.recommend_build = recommend_build
        self.decision_reason = decision_reason
    }

    public static func parse(from text: String) -> ThoughtRecommendation {
        // 1. JSONブロック ```json ... ``` または { "recommend_build": ... } を抽出してパース
        if let jsonRange = text.range(of: "\\{[\\s\\S]*?\"recommend_build\"[\\s\\S]*?\\}", options: .regularExpression) {
            let jsonString = String(text[jsonRange])
            if let data = jsonString.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rec = obj["recommend_build"] as? Bool {
                let reason = (obj["decision_reason"] as? String) ?? "構造化出力に基づく判定"
                return ThoughtRecommendation(recommend_build: rec, decision_reason: reason)
            }
        }
        // 構造化JSON（recommend_build）が取得できない場合は、例外なく安全側に倒して制作を抑制 (fail-closed)
        return ThoughtRecommendation(recommend_build: false, decision_reason: "構造化JSON（recommend_build）が取得できなかったため安全に見送り（fail-closed）")
    }
}

/// セッション単位の要約クールダウン管理
public struct SummaryCooldownTracker: Sendable {
    public private(set) var lastSummaryAt: Date
    public let cooldownSeconds: TimeInterval

    public init(cooldownSeconds: TimeInterval = 60, lastSummaryAt: Date = .distantPast) {
        self.cooldownSeconds = cooldownSeconds
        self.lastSummaryAt = lastSummaryAt
    }

    public mutating func resetSession() {
        lastSummaryAt = .distantPast
    }

    public mutating func shouldAllowSummary(now: Date = Date()) -> Bool {
        if now.timeIntervalSince(lastSummaryAt) > cooldownSeconds {
            lastSummaryAt = now
            return true
        }
        return false
    }
}

public struct ActivityRow: Identifiable, Sendable {
    public let id: UUID
    public let time: Date
    public let kind: String
    public let message: String

    public init(id: UUID = UUID(), time: Date = Date(), kind: String, message: String) {
        self.id = id
        self.time = time
        self.kind = kind
        self.message = message
    }
}

public struct BuildJob: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let directory: URL
    public var status: String
    public var log: String
    public var prompt: String

    public init(id: String, title: String, directory: URL, status: String, log: String = "", prompt: String) {
        self.id = id
        self.title = title
        self.directory = directory
        self.status = status
        self.log = log
        self.prompt = prompt
    }
}
