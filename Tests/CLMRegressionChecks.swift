import Foundation
import Speech
import MeetingServices

private actor CLMPreparationCounter {
    private(set) var calls = 0
    func next() -> Int { calls += 1; return calls }
}

/// No speech authorization, microphones, or actual Apple model compilation are invoked.
@MainActor
func runCLMRegressionChecks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CLM-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let modelA = directory.appendingPathComponent("model-a.bin")
    let modelB = directory.appendingPathComponent("model-b.bin")
    try Data("compiled fixture a".utf8).write(to: modelA)
    try Data("compiled fixture b".utf8).write(to: modelB)
    let configA = CustomLanguageModelHelper.makeConfiguration(modelURL: modelA)
    let configB = CustomLanguageModelHelper.makeConfiguration(modelURL: modelB)

    // A reordered corpus reuses the same model, while a different locale/version/corpus does not.
    let key = CustomLanguageModelHelper.cacheIdentity(vocabulary: ["OCuLink", "eGPU"], identifier: "base")
    expectEqual(key, CustomLanguageModelHelper.cacheIdentity(vocabulary: [" eGPU ", "OCuLink", "OCuLink"], identifier: "base"))
    expectFalse(key == CustomLanguageModelHelper.cacheIdentity(vocabulary: ["OCuLink"], identifier: "base"))
    expectFalse(key == CustomLanguageModelHelper.cacheIdentity(vocabulary: ["OCuLink", "eGPU"], locale: Locale(identifier: "en-US"), identifier: "base"))

    // Failure returns promptly and a later meeting retries successfully.
    let retryCounter = CLMPreparationCounter()
    let retrying = CustomLanguageModelPrewarmer(prepare: { _, _ in
        if await retryCounter.next() == 1 { throw NSError(domain: "CLMTest", code: 1) }
        return configA
    })
    let failed = await retrying.waitForConfiguration(timeoutSeconds: 1.0)
    expectTrue(failed == nil)
    let recovered = await retrying.waitForConfiguration(timeoutSeconds: 1.0)
    expectEqual(recovered?.languageModel, modelA)
    let retryCalls = await retryCounter.calls
    expectEqual(retryCalls, 2)

    // A cancelled waiter must leave immediately instead of spinning until the CLM deadline.
    let slow = CustomLanguageModelPrewarmer(prepare: { _, _ in
        try await Task.sleep(for: .milliseconds(150))
        return configA
    })
    let start = ContinuousClock.now
    let waiter = Task { await slow.waitForConfiguration(timeoutSeconds: 3) }
    try await Task.sleep(for: .milliseconds(20))
    waiter.cancel()
    let cancelled = await waiter.value
    expectTrue(cancelled == nil)
    expectTrue(start.duration(to: .now) < .seconds(1))
    let afterCancellation = await slow.waitForConfiguration(timeoutSeconds: 1)
    expectEqual(afterCancellation?.languageModel, modelA)

    // Replacing a preparation generation cannot let its late result overwrite the new one.
    let replacement = CustomLanguageModelPrewarmer()
    replacement.setPrewarmTaskForTesting(Task {
        try? await Task.sleep(for: .milliseconds(80))
        return configA
    })
    replacement.setReadyConfigForTesting(configB)
    try await Task.sleep(for: .milliseconds(120))
    expectEqual(replacement.availableConfiguration()?.languageModel, modelB)

    // The shared cache deduplicates simultaneous consumers and isolates distinct corpora.
    let cacheCounter = CLMPreparationCounter()
    let cache = CustomLanguageModelCache(prepare: { vocabulary, _ in
        _ = await cacheCounter.next()
        try await Task.sleep(for: .milliseconds(30))
        return vocabulary.contains("OCuLink") ? configA : configB
    })
    async let first = cache.prewarmBaseModel(vocabulary: ["OCuLink"], identifier: "base")
    async let second = cache.prewarmBaseModel(vocabulary: ["OCuLink"], identifier: "base")
    let pair = try await (first, second)
    expectEqual(pair.0.languageModel, pair.1.languageModel)
    var calls = await cacheCounter.calls
    expectEqual(calls, 1)
    let other = try await cache.prewarmBaseModel(vocabulary: ["eGPU"], identifier: "base")
    expectEqual(other.languageModel, modelB)
    calls = await cacheCounter.calls
    expectEqual(calls, 2)

    // Deleting compiled files invalidates both memory caches; a URL alone is not readiness.
    try FileManager.default.removeItem(at: modelA)
    let missing = await cache.getCachedBaseConfiguration(vocabulary: ["OCuLink"], identifier: "base")
    expectTrue(missing == nil)
    expectTrue(retrying.availableConfiguration() == nil)
    expectFalse(CustomLanguageModelHelper.hasCompiledArtifacts(configA))
    let missingVocabulary = SFSpeechLanguageModel.Configuration(languageModel: modelB, vocabulary: modelA)
    expectFalse(CustomLanguageModelHelper.hasCompiledArtifacts(missingVocabulary))
}
