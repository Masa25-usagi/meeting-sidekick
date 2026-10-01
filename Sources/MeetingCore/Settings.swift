import Foundation
import Security

public struct AppSettings: Codable, Sendable {
    public var policy = MeetingPolicy(objective: "会議中に出たアイデアから、便利なWebアプリを試作する")
    public var voiceProvider = "gemini"
    public var liveModel = "gemini-3.8-live"
    public var openaiModel = "gpt-4o-realtime-preview"
    public var textModel = "gemini-3.8-flash"
    public var ruleSynthesisEngine = "codex"
    public var thinkingEngine = "codex"
    public var ruleEngine: String {
        get { ruleSynthesisEngine }
        set {
            ruleSynthesisEngine = newValue
            thinkingEngine = newValue
        }
    }
    public var judgeModel = "jev-latest"
    public var judgeEndpoint = "https://api.typesafe.ai/v1/systemone"
    public var useJev = true
    public var rules = ""
    public var sendScreen = false
    public var includeMicrophone = true
    public var mixMicrophone = false
    public var liveSeconds = 60
    public var maxJudgeCalls = 120
    public var meetingMinutes = 30
    public var codexPath = ""
    public var agyPath = ""
    public var grokPath = ""
    public var liveInputSource = "microphone"
    public var audioSetupSeen = false
    public var thinkingModel = "gpt-6-sol"
    public var thinkingEffort = "low"
    public var terminologyResearchModel = "gpt-6-sol"
    public var terminologyResearchEffort = "low"
    public var enableTerminologyWebSearch = true

    public enum CodingKeys: String, CodingKey {
        case policy, voiceProvider, liveModel, openaiModel, textModel
        case ruleEngine, ruleSynthesisEngine, thinkingEngine
        case judgeModel, judgeEndpoint, useJev, rules, sendScreen
        case includeMicrophone, mixMicrophone, liveSeconds, maxJudgeCalls, meetingMinutes
        case codexPath, agyPath, grokPath, liveInputSource, audioSetupSeen
        case thinkingModel, thinkingEffort
        case terminologyResearchModel, terminologyResearchEffort, enableTerminologyWebSearch
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policy = try c.decodeIfPresent(MeetingPolicy.self, forKey: .policy) ?? policy
        voiceProvider = try c.decodeIfPresent(String.self, forKey: .voiceProvider) ?? voiceProvider
        liveModel = try c.decodeIfPresent(String.self, forKey: .liveModel) ?? liveModel
        openaiModel = try c.decodeIfPresent(String.self, forKey: .openaiModel) ?? openaiModel
        textModel = try c.decodeIfPresent(String.self, forKey: .textModel) ?? textModel
        let legacyRuleEngine = try c.decodeIfPresent(String.self, forKey: .ruleEngine)
        ruleSynthesisEngine = try c.decodeIfPresent(String.self, forKey: .ruleSynthesisEngine) ?? legacyRuleEngine ?? ruleSynthesisEngine
        thinkingEngine = try c.decodeIfPresent(String.self, forKey: .thinkingEngine) ?? legacyRuleEngine ?? thinkingEngine
        judgeModel = try c.decodeIfPresent(String.self, forKey: .judgeModel) ?? judgeModel
        judgeEndpoint = try c.decodeIfPresent(String.self, forKey: .judgeEndpoint) ?? judgeEndpoint
        useJev = try c.decodeIfPresent(Bool.self, forKey: .useJev) ?? useJev
        rules = try c.decodeIfPresent(String.self, forKey: .rules) ?? rules
        sendScreen = try c.decodeIfPresent(Bool.self, forKey: .sendScreen) ?? sendScreen
        includeMicrophone = try c.decodeIfPresent(Bool.self, forKey: .includeMicrophone) ?? includeMicrophone
        mixMicrophone = try c.decodeIfPresent(Bool.self, forKey: .mixMicrophone) ?? mixMicrophone
        liveSeconds = try c.decodeIfPresent(Int.self, forKey: .liveSeconds) ?? liveSeconds
        maxJudgeCalls = try c.decodeIfPresent(Int.self, forKey: .maxJudgeCalls) ?? maxJudgeCalls
        meetingMinutes = try c.decodeIfPresent(Int.self, forKey: .meetingMinutes) ?? meetingMinutes
        codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath) ?? codexPath
        agyPath = try c.decodeIfPresent(String.self, forKey: .agyPath) ?? agyPath
        grokPath = try c.decodeIfPresent(String.self, forKey: .grokPath) ?? grokPath
        liveInputSource = try c.decodeIfPresent(String.self, forKey: .liveInputSource) ?? liveInputSource
        audioSetupSeen = try c.decodeIfPresent(Bool.self, forKey: .audioSetupSeen) ?? audioSetupSeen
        thinkingModel = try c.decodeIfPresent(String.self, forKey: .thinkingModel) ?? thinkingModel
        thinkingEffort = try c.decodeIfPresent(String.self, forKey: .thinkingEffort) ?? thinkingEffort
        terminologyResearchModel = try c.decodeIfPresent(String.self, forKey: .terminologyResearchModel) ?? terminologyResearchModel
        terminologyResearchEffort = try c.decodeIfPresent(String.self, forKey: .terminologyResearchEffort) ?? terminologyResearchEffort
        enableTerminologyWebSearch = try c.decodeIfPresent(Bool.self, forKey: .enableTerminologyWebSearch) ?? enableTerminologyWebSearch
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(policy, forKey: .policy)
        try container.encode(voiceProvider, forKey: .voiceProvider)
        try container.encode(liveModel, forKey: .liveModel)
        try container.encode(openaiModel, forKey: .openaiModel)
        try container.encode(textModel, forKey: .textModel)
        try container.encode(ruleEngine, forKey: .ruleEngine)
        try container.encode(ruleSynthesisEngine, forKey: .ruleSynthesisEngine)
        try container.encode(thinkingEngine, forKey: .thinkingEngine)
        try container.encode(judgeModel, forKey: .judgeModel)
        try container.encode(judgeEndpoint, forKey: .judgeEndpoint)
        try container.encode(useJev, forKey: .useJev)
        try container.encode(rules, forKey: .rules)
        try container.encode(sendScreen, forKey: .sendScreen)
        try container.encode(includeMicrophone, forKey: .includeMicrophone)
        try container.encode(mixMicrophone, forKey: .mixMicrophone)
        try container.encode(liveSeconds, forKey: .liveSeconds)
        try container.encode(maxJudgeCalls, forKey: .maxJudgeCalls)
        try container.encode(meetingMinutes, forKey: .meetingMinutes)
        try container.encode(codexPath, forKey: .codexPath)
        try container.encode(agyPath, forKey: .agyPath)
        try container.encode(grokPath, forKey: .grokPath)
        try container.encode(liveInputSource, forKey: .liveInputSource)
        try container.encode(audioSetupSeen, forKey: .audioSetupSeen)
        try container.encode(thinkingModel, forKey: .thinkingModel)
        try container.encode(thinkingEffort, forKey: .thinkingEffort)
        try container.encode(terminologyResearchModel, forKey: .terminologyResearchModel)
        try container.encode(terminologyResearchEffort, forKey: .terminologyResearchEffort)
        try container.encode(enableTerminologyWebSearch, forKey: .enableTerminologyWebSearch)
    }
}

public enum AppPaths: Sendable {
    public static var project: URL {
        if let path = Bundle.main.object(forInfoDictionaryKey: "MeetingProjectPath") as? String { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
    public static var data: URL { project.appendingPathComponent("Runtime", isDirectory: true) }
    public static var prototypes: URL { project.appendingPathComponent("Prototypes", isDirectory: true) }
    public static var config: URL { data.appendingPathComponent("settings.json") }
    public static func load() -> AppSettings {
        guard let bytes = try? Data(contentsOf: config), let settings = try? JSONDecoder().decode(AppSettings.self, from: bytes) else { return AppSettings() }
        return settings
    }
    public static func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: config, options: .atomic)
    }
}

public enum KeyStore: Sendable {
    private static let service = "local.meeting-sidekick.credentials"
    public static func read(_ account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data { return String(decoding: data, as: UTF8.self) }
        let variable = account == "gemini" ? "GEMINI_API_KEY" : (account == "openai" ? "OPENAI_API_KEY" : "TYPESAFE_API_KEY")
        if let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty { return value }
        let envFile = AppPaths.project.appendingPathComponent(".env.local")
        guard let content = try? String(contentsOf: envFile, encoding: .utf8) else { return "" }
        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == variable { return parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        return ""
    }
    public static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        } else if update != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(update)) }
    }
}
