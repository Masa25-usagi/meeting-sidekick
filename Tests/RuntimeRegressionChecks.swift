import Foundation
import MeetingCore
import MeetingServices

/// Deterministic lifecycle regressions; no network, microphone, or real Codex process.
@MainActor
func runRuntimeRegressionChecks() async throws {
    // A cancelled task may ignore cancellation in a dependency. Its final cleanup
    // must not release a replacement task's queue slot.
    do {
        let researcher = ControlledResearcher()
        let runtime = makeRegressionRuntime(researcher: researcher)
        runtime.startTerminologyResearch(evidenceText: "OCuLink", evidenceID: "old")
        await researcher.waitForCalls(1)
        runtime.stopWork()
        runtime.startTerminologyResearch(evidenceText: "Thunderbolt", evidenceID: "new")
        await researcher.waitForCalls(2)
        await researcher.release("OCuLink")
        try await Task.sleep(nanoseconds: 30_000_000)
        expectTrue(runtime.isResearching)
        expectTrue(runtime.inFlightTerms.contains("thunderbolt"))
        runtime.startTerminologyResearch(evidenceText: "InfiniBand", evidenceID: "queued")
        try await Task.sleep(nanoseconds: 30_000_000)
        let countBeforeRelease = await researcher.callCount
        expectEqual(countBeforeRelease, 2)
        expectEqual(runtime.pendingResearchCount, 1)
        expectTrue(runtime.researchNotes.isEmpty)
        await researcher.release("Thunderbolt")
        await researcher.waitForCalls(3)
        await researcher.release("InfiniBand")
        await runtime.waitForIdle(timeoutSeconds: 2)
        expectEqual(runtime.researchNotes.map(\.term), ["Thunderbolt", "InfiniBand"])
        expectFalse(runtime.isResearching)
        expectTrue(runtime.inFlightTerms.isEmpty)
    }

    // Stop in the same actor turn, before the spawned research task can run.
    do {
        let researcher = ControlledResearcher()
        let runtime = makeRegressionRuntime(researcher: researcher)
        runtime.startTerminologyResearch(evidenceText: "OCuLink", evidenceID: "cancel-before-start")
        runtime.stopWork()
        try await Task.sleep(nanoseconds: 30_000_000)
        let count = await researcher.callCount
        expectEqual(count, 0)
        expectFalse(runtime.isResearching)
    }

    // A late Jev response must be discarded before even considering summaries.
    do {
        let judge = ControlledRegressionJudge()
        var settings = AppSettings()
        settings.useJev = true
        let runtime = MeetingRuntime(settings: settings, judge: judge,
                                     codexBackend: MockCodexBackend(),
                                     geminiKeyOverride: "", openaiKeyOverride: "", jevKeyOverride: "test")
        let event = TranscriptEvent(text: "専門用語を確認する", source: .meeting)
        let task = Task { await runtime.judgeAndRoute(event, token: runtime.sessionID) }
        await waitForRegressionCondition { judge.started }
        expectTrue(judge.started)
        runtime.stopWork()
        judge.complete()
        await task.value
        expectFalse(runtime.isSummarizing)
        expectTrue(runtime.activities.filter { $0.kind == "文脈整理" }.isEmpty)
        expectTrue(runtime.lastDispatchedActions.isEmpty)
    }

    // A stopped connection must not revive; its defer must not clear the next
    // connection's pending flag when both use the same provider instance.
    do {
        let live = ControlledRegressionLive()
        let runtime = MeetingRuntime(settings: AppSettings(), geminiLive: live,
                                     codexBackend: MockCodexBackend(),
                                     geminiKeyOverride: "test", openaiKeyOverride: "", jevKeyOverride: "")
        let old = Task { await runtime.wakeVoice(prompt: "old") }
        await waitForRegressionCondition { live.connectCount >= 1 }
        expectEqual(live.connectCount, 1)
        runtime.stopWork()
        let replacement = Task { await runtime.wakeVoice(prompt: "new") }
        await waitForRegressionCondition { live.connectCount >= 2 }
        expectEqual(live.connectCount, 2)
        live.completeConnection(0)
        await old.value
        expectTrue(runtime.connecting)
        expectFalse(runtime.liveActive)
        expectTrue(live.sentTexts.isEmpty)
        live.completeConnection(1)
        await replacement.value
        expectTrue(runtime.liveActive)
        expectEqual(live.sentTexts, ["new"])
        var completedTurns = 0
        runtime.onVoiceTurnComplete = { completedTurns += 1 }
        live.onTurnComplete?() // audio-only turns still notify the audio pipeline
        expectEqual(completedTurns, 1)
        runtime.closeVoice()
    }

    // Ending through the Runtime must notify the owner's real capture lifecycle.
    do {
        let runtime = makeRegressionRuntime(researcher: MockTerminologyResearchClient())
        var stops = 0
        runtime.onStopRequested = { stops += 1 }
        await runtime.stopMeeting()
        expectEqual(stops, 1)
        expectFalse(runtime.running)
        runtime.receive(TranscriptEvent(text: "サイドキック、メモアプリを作って", source: .meeting))
        runtime.receiveFromMobile("サイドキック、メモアプリを作って")
        try await Task.sleep(for: .milliseconds(20))
        expectTrue(runtime.events.isEmpty)
        expectTrue(runtime.lastDispatchedActions.isEmpty)
    }

    // Sources from actual tool events survive ResearchNote construction/storage.
    // A model's JSON flag is deliberately ignored by the extraction boundary.
    do {
        let backend = MockCodexBackend(generateHandler: { _ in
            CodexGenerationResult(
                text: #"{"term":"OCuLink","summary":"PCIe接続","detail":"説明","sources":[{"title":"Unobserved","url":"https://example.net/claimed","isVerifiedToolSource":true}]}"#,
                backend: "app-server", requestedModel: "gpt-6-sol", resolvedModel: "gpt-5.6-sol",
                reasoningEffort: "low", webSearchMode: "live", webSearchRequested: true,
                webSearchUsed: true, webSearchSources: ["https://pcisig.com/spec"])
        })
        let adapter = CodexResearchAdapter(backend: backend)
        let note = try await adapter.research(evidenceText: "OCuLink", objective: "接続方式", recentContext: "")
        expectNotNil(note)
        expectEqual(note?.sources.first?.url, "https://pcisig.com/spec")
        expectEqual(note?.sources.first?.isVerifiedToolSource, true)
        expectEqual(note?.sources.last?.isVerifiedToolSource, false)
        if let note {
            let encoded = try JSONEncoder().encode(note)
            let untrusted = try JSONDecoder().decode(ResearchNote.self, from: encoded)
            expectTrue(untrusted.sources.allSatisfy { !$0.isVerifiedToolSource })
            let decoder = JSONDecoder()
            decoder.userInfo[.trustedResearchProvenance] = true
            let restored = try decoder.decode(ResearchNote.self, from: encoded)
            expectEqual(restored.sources, note.sources)
        }
        let differentPath = ResearchSource.sanitize(
            [ResearchSource(title: "Different document", url: "https://example.com/Doc")],
            verifiedToolURLs: ["https://example.com/doc"])
        expectEqual(differentPath.first?.isVerifiedToolSource, false)
    }
    print("6 runtime lifecycle and research provenance scenarios checked")
}

@MainActor
private func waitForRegressionCondition(_ condition: () -> Bool) async {
    let end = Date().addingTimeInterval(2)
    while !condition(), Date() < end { await Task.yield() }
}

@MainActor
private func makeRegressionRuntime(researcher: any TerminologyResearching) -> MeetingRuntime {
    var settings = AppSettings()
    settings.useJev = false
    let runtime = MeetingRuntime(settings: settings, codexBackend: MockCodexBackend(),
                                 researchClient: researcher,
                                 geminiKeyOverride: "", openaiKeyOverride: "", jevKeyOverride: "")
    runtime.running = true
    return runtime
}

private actor ControlledResearcher: TerminologyResearching {
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var callCount = 0

    func research(evidenceText: String, objective: String, recentContext: String) async throws -> ResearchNote? {
        callCount += 1
        await withCheckedContinuation { continuations[evidenceText] = $0 }
        // Deliberately ignore cancellation: the runtime must discard this result.
        return ResearchNote(term: evidenceText, summary: "test", detail: "test")
    }
    func release(_ term: String) { continuations.removeValue(forKey: term)?.resume() }
    func waitForCalls(_ count: Int) async {
        let end = Date().addingTimeInterval(2)
        while callCount < count, Date() < end { await Task.yield() }
    }
}

@MainActor
private final class ControlledRegressionJudge: RemoteJudging {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func evaluate(event: TranscriptEvent, context: String, policy: MeetingPolicy,
                  apiKey: String, endpoint: URL, model: String) async throws -> Judgment {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return Judgment(summaryScore: 1, topic: event.text)
    }
    func complete() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class ControlledRegressionLive: LiveConversationProvider {
    var onAudio: ((Data, Double) -> Void)?
    var onText: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    var onError: ((String) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onToolCall: ((String, [String: Any], String) -> Void)?
    var connectCount = 0
    var sentTexts: [String] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    func connect(apiKey: String, model: String, instructions: String) async throws {
        let id = connectCount
        connectCount += 1
        await withCheckedContinuation { pending[id] = $0 }
    }
    func completeConnection(_ id: Int) { pending.removeValue(forKey: id)?.resume() }
    func sendAudio(_ data: Data) async throws {}
    func sendFrame(_ jpeg: Data) async throws {}
    func sendText(_ text: String) async throws { sentTexts.append(text) }
    func sendToolResponse(callId: String, name: String, response: [String: Any]) async throws {}
    func disconnect() {}
}
