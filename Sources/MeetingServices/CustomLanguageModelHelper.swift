import Foundation
import Speech
import CryptoKit

/// The exported training corpus and the compiled recognizer model are different artifacts.
public enum CustomLanguageModelHelper {
    public static var isSupportedOnCurrentOS: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    @available(macOS 14.0, *)
    public static func createCustomLanguageModelData(
        vocabulary: [String], locale: Locale = Locale(identifier: "ja-JP"),
        identifier: String = "local.meeting-sidekick.custom-lm", version: String = "1.0"
    ) -> SFCustomLanguageModelData {
        let data = SFCustomLanguageModelData(locale: locale, identifier: identifier, version: version)
        for phrase in normalizedVocabulary(vocabulary) {
            data.insert(phraseCount: SFCustomLanguageModelData.PhraseCount(phrase: phrase, count: 10))
        }
        return data
    }

    @available(macOS 14.0, *)
    public static func makeConfiguration(modelURL: URL) -> SFSpeechLanguageModel.Configuration {
        SFSpeechLanguageModel.Configuration(languageModel: modelURL)
    }

    /// Stable identity prevents different corpora from sharing an in-memory or on-disk cache.
    public static func cacheIdentity(vocabulary: [String], locale: Locale = Locale(identifier: "ja-JP"),
                                     identifier: String, version: String = "1.0") -> String {
        let fields = ["compiled-clm-v2", locale.identifier, identifier, version,
                      String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)] + normalizedVocabulary(vocabulary)
        let encoded = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedVocabulary(_ vocabulary: [String]) -> [String] {
        Array(Set(vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    @available(macOS 14.0, *)
    public static func hasCompiledArtifacts(_ configuration: SFSpeechLanguageModel.Configuration) -> Bool {
        let urls = [configuration.languageModel] + [configuration.vocabulary].compactMap { $0 }
        return urls.allSatisfy { url in
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else { return false }
            return attributes[.type] as? FileAttributeType == .typeRegular && size.int64Value > 0
        }
    }

    @available(macOS 14.0, *)
    public static func prepareCustomLanguageModel(
        vocabulary: [String], locale: Locale = Locale(identifier: "ja-JP"),
        identifier: String = "local.meeting-sidekick.custom-lm", version: String = "1.0",
        cacheDirectory: URL? = nil
    ) async throws -> SFSpeechLanguageModel.Configuration {
        try Task.checkCancellation()
        let cacheRoot = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingSidekick/CustomLanguageModels", isDirectory: true)
        let identity = cacheIdentity(vocabulary: vocabulary, locale: locale, identifier: identifier, version: version)
        let baseDir = cacheRoot.appendingPathComponent(identity, isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let trainingURL = baseDir.appendingPathComponent("training.bin")
        let configuration = SFSpeechLanguageModel.Configuration(
            languageModel: baseDir.appendingPathComponent("language-model.bin"),
            vocabulary: baseDir.appendingPathComponent("vocabulary.bin"))
        let readyURL = baseDir.appendingPathComponent("ready")
        if (try? String(contentsOf: readyURL, encoding: .utf8)) == identity,
           hasCompiledArtifacts(configuration) { return configuration }

        // A failed or interrupted preparation must never look like a usable cache entry.
        try? FileManager.default.removeItem(at: readyURL)
        let data = createCustomLanguageModelData(vocabulary: vocabulary, locale: locale,
                                                identifier: identifier, version: version)
        try await data.export(to: trainingURL)
        try Task.checkCancellation()
        try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: trainingURL, configuration: configuration)
        try Task.checkCancellation()
        guard hasCompiledArtifacts(configuration) else {
            throw NSError(domain: "MeetingSidekick.CLM", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "専門語の音声認識モデルを準備できませんでした。"])
        }
        try Data(identity.utf8).write(to: readyURL, options: .atomic)
        return configuration
    }
}

/// One shared preparation per corpus. The compiled files are checked before reuse.
@available(macOS 14.0, *)
public actor CustomLanguageModelCache {
    public typealias Preparation = @Sendable ([String], String) async throws -> SFSpeechLanguageModel.Configuration
    public static let shared = CustomLanguageModelCache()
    private var cached: [String: SFSpeechLanguageModel.Configuration] = [:]
    private struct PreparationEntry {
        let id = UUID()
        let task: Task<SFSpeechLanguageModel.Configuration, Error>
    }
    private var inFlight: [String: PreparationEntry] = [:]
    private var generation = UUID()
    private let prepare: Preparation

    public init(prepare: @escaping Preparation = { vocabulary, identifier in
        try await CustomLanguageModelHelper.prepareCustomLanguageModel(vocabulary: vocabulary, identifier: identifier)
    }) { self.prepare = prepare }

    public func prewarmBaseModel(vocabulary: [String] = SpeechContextVocabulary.defaultBaseVocabulary,
                                identifier: String = "local.meeting-sidekick.base-clm") async throws -> SFSpeechLanguageModel.Configuration {
        try Task.checkCancellation()
        let key = CustomLanguageModelHelper.cacheIdentity(vocabulary: vocabulary, identifier: identifier)
        if let configuration = getCachedBaseConfiguration(vocabulary: vocabulary, identifier: identifier) { return configuration }
        let token = generation
        let entry: PreparationEntry
        if let existing = inFlight[key] { entry = existing }
        else {
            entry = PreparationEntry(task: Task { try await prepare(vocabulary, identifier) })
            inFlight[key] = entry
        }
        do {
            let configuration = try await entry.task.value
            guard token == generation else { throw CancellationError() }
            if inFlight[key]?.id == entry.id { inFlight[key] = nil }
            guard CustomLanguageModelHelper.hasCompiledArtifacts(configuration) else {
                throw NSError(domain: "MeetingSidekick.CLM", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "専門語の音声認識モデルが見つかりません。"])
            }
            cached[key] = configuration
            try Task.checkCancellation()
            return configuration
        } catch {
            if token == generation, inFlight[key]?.id == entry.id { inFlight[key] = nil }
            throw error
        }
    }

    public func getCachedBaseConfiguration(vocabulary: [String] = SpeechContextVocabulary.defaultBaseVocabulary,
                                          identifier: String = "local.meeting-sidekick.base-clm") -> SFSpeechLanguageModel.Configuration? {
        let key = CustomLanguageModelHelper.cacheIdentity(vocabulary: vocabulary, identifier: identifier)
        guard let configuration = cached[key] else { return nil }
        guard CustomLanguageModelHelper.hasCompiledArtifacts(configuration) else { cached[key] = nil; return nil }
        return configuration
    }

    public func clearCacheForTesting() {
        generation = UUID()
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
        cached.removeAll()
    }
}

/// Prewarming survives a short start timeout; cancelling a waiter does not cancel other consumers.
@available(macOS 14.0, *)
public final class CustomLanguageModelPrewarmer: @unchecked Sendable {
    public typealias Preparation = CustomLanguageModelCache.Preparation
    public static let shared = CustomLanguageModelPrewarmer()
    private var prewarmTask: Task<SFSpeechLanguageModel.Configuration?, Never>?
    private let lock = NSLock()
    private var readyConfig: SFSpeechLanguageModel.Configuration?
    private var generation = UUID()
    private var identity: String?
    private let prepare: Preparation

    public init(prepare: @escaping Preparation = { vocabulary, identifier in
        try await CustomLanguageModelCache.shared.prewarmBaseModel(vocabulary: vocabulary, identifier: identifier)
    }) { self.prepare = prepare }

    public func availableConfiguration() -> SFSpeechLanguageModel.Configuration? {
        lock.withLock {
            guard let configuration = readyConfig else { return nil }
            guard CustomLanguageModelHelper.hasCompiledArtifacts(configuration) else { readyConfig = nil; return nil }
            return configuration
        }
    }

    @discardableResult
    public func startPrewarm(vocabulary: [String] = SpeechContextVocabulary.defaultBaseVocabulary,
                             identifier: String = "local.meeting-sidekick.base-clm") -> Task<SFSpeechLanguageModel.Configuration?, Never> {
        lock.withLock {
            let key = CustomLanguageModelHelper.cacheIdentity(vocabulary: vocabulary, identifier: identifier)
            if identity == nil || identity == key {
                if let existing = prewarmTask { return existing }
                if let config = readyConfig, CustomLanguageModelHelper.hasCompiledArtifacts(config) { return Task { config } }
            }
            let token = UUID()
            generation = token
            identity = key
            readyConfig = nil
            let task = Task<SFSpeechLanguageModel.Configuration?, Never> { [weak self, prepare] in
                let result = try? await prepare(vocabulary, identifier)
                self?.complete(result, generation: token)
                return result
            }
            prewarmTask = task
            return task
        }
    }

    private func complete(_ configuration: SFSpeechLanguageModel.Configuration?, generation token: UUID) {
        lock.withLock {
            guard generation == token else { return }
            readyConfig = configuration.flatMap { CustomLanguageModelHelper.hasCompiledArtifacts($0) ? $0 : nil }
            prewarmTask = nil // Failure is retryable at the next start, rather than cached forever.
        }
    }

    public func waitForConfiguration(timeoutSeconds: TimeInterval = 1.5) async -> SFSpeechLanguageModel.Configuration? {
        guard !Task.isCancelled else { return nil }
        if let config = availableConfiguration() { return config }
        _ = startPrewarm()
        let clock = ContinuousClock()
        let duration = timeoutSeconds.isFinite ? max(0, timeoutSeconds) : 1.5
        let deadline = clock.now.advanced(by: .seconds(duration))
        while !Task.isCancelled {
            if let config = availableConfiguration() { return config }
            // Completion can publish readyConfig between the check above and
            // observing a cleared task. Re-read it before reporting failure.
            if lock.withLock({ prewarmTask == nil }) || clock.now >= deadline {
                return availableConfiguration()
            }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return nil }
        }
        return nil
    }

    public func setPrewarmTaskForTesting(_ task: Task<SFSpeechLanguageModel.Configuration?, Never>?) {
        let token = UUID()
        lock.withLock { generation = token; identity = nil; prewarmTask = task; readyConfig = nil }
        if let task { Task { [weak self] in self?.complete(await task.value, generation: token) } }
    }

    public func setReadyConfigForTesting(_ config: SFSpeechLanguageModel.Configuration?) {
        lock.withLock { generation = UUID(); identity = nil; prewarmTask = nil; readyConfig = config }
    }

    public static func configureRecognitionRequest(request: SFSpeechAudioBufferRecognitionRequest,
                                                   clmConfig: SFSpeechLanguageModel.Configuration?,
                                                   contextualStrings: [String] = []) {
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = Array(contextualStrings.prefix(100))
        request.customizedLanguageModel = clmConfig
    }
}
