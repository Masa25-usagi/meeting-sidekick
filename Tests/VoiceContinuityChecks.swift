import Foundation
import MeetingCore
@testable import MeetingServices

@MainActor
private final class ContinuityLive: LiveConversationProvider {
    var onAudio: ((Data, Double) -> Void)?
    var onText: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    var onError: ((String) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onToolCall: ((String, [String: Any], String) -> Void)?
    var texts: [String] = []
    var disconnects = 0
    func connect(apiKey: String, model: String, instructions: String) async throws {}
    func sendAudio(_ data: Data) async throws {}
    func sendFrame(_ jpeg: Data) async throws {}
    func sendText(_ text: String) async throws { texts.append(text) }
    func sendToolResponse(callId: String, name: String, response: [String: Any]) async throws {}
    func disconnect() { disconnects += 1 }
}

@MainActor
private final class OfflineContinuityJudge: RemoteJudging {
    func evaluate(event: TranscriptEvent, context: String, policy: MeetingPolicy, apiKey: String, endpoint: URL, model: String) async throws -> Judgment {
        throw LiveClientError.connectionFailed
    }
}

@MainActor
func runVoiceContinuityChecks() async throws {
    // A response crossing the old connection deadline must finish, even after
    // the server reports turnComplete and client playback is still draining.
    var activity = VoiceSessionActivity()
    activity.request(at: 0)
    activity.response(at: 55)
    activity.playback(true, at: 55)
    activity.turnEnded(at: 56)
    expectEqual(activity.expiry(at: 150, sessionSeconds: 60), .waiting)
    activity.playback(false, at: 150)
    expectEqual(activity.expiry(at: 150, sessionSeconds: 60), .idle)
    expectEqual(activity.expiry(at: 210, sessionSeconds: 60), .idle)
    activity.begin(at: 220)
    activity.request(at: 220)
    activity.response(at: 275)
    expectEqual(activity.expiry(at: 300, sessionSeconds: 60), .waiting)
    expectEqual(activity.expiry(at: 335, sessionSeconds: 60), .stalledResponse)
    activity.turnEnded(at: 336)
    activity.humanSpeech(at: 390)
    expectEqual(activity.expiry(at: 440, sessionSeconds: 60), .waiting)

    // No hardware or audible playback: simulate audio arriving six times
    // faster than it plays. The former 20-second cutoff loses this response.
    var queue = PCMPlaybackQueue()
    for _ in 0..<240 { expectTrue(queue.reserve(0.5)) }
    expectEqual(queue.seconds, 120)
    expectFalse(queue.overflowed)
    for _ in 0..<240 { queue.played(0.5) }
    expectEqual(queue.seconds, 0)
    expectTrue(queue.reserve(180))
    expectFalse(queue.reserve(0.5))
    expectEqual(queue.seconds, 180) // Does not flush speech already queued.
    queue.played(180)
    expectFalse(queue.reserve(0.5)) // No automatic restart from trailing chunks.
    queue.reset()
    expectTrue(queue.reserve(0.5))

    // Local speaker echo cannot trigger another server interruption. A real
    // remote participant can still speak while the assistant is talking.
    var gate = PlaybackInputGate()
    expectFalse(gate.suppresses(.microphone, at: 0))
    gate.playbackChanged(true, at: 1)
    expectTrue(gate.suppresses(.microphone, at: 100))
    expectFalse(gate.suppresses(.meeting, at: 100))
    gate.playbackChanged(false, at: 101)
    expectTrue(gate.suppresses(.microphone, at: 101.3))
    expectFalse(gate.suppresses(.microphone, at: 101.4))

    var settings = AppSettings()
    settings.policy.nickname = "ジェミニ"
    settings.liveSeconds = 60
    let live = ContinuityLive()
    let runtime = MeetingRuntime(settings: settings, geminiLive: live,
        judge: OfflineContinuityJudge(), geminiKeyOverride: "test",
        openaiKeyOverride: "", jevKeyOverride: "")
    var stops = 0
    runtime.onVoiceInterrupted = { stops += 1 }
    await runtime.wakeVoice(prompt: "こんにちは")
    let baselineStops = stops
    live.onAudio?(Data([0, 0]), 24_000)
    runtime.setVoicePlaybackActive(true)
    live.onTurnComplete?()
    runtime.checkVoiceIdle(at: ProcessInfo.processInfo.systemUptime + 300)
    expectTrue(runtime.liveActive)
    expectEqual(stops, baselineStops)
    runtime.setVoicePlaybackActive(false)
    runtime.checkVoiceIdle(at: ProcessInfo.processInfo.systemUptime + 59)
    expectTrue(runtime.liveActive)
    runtime.checkVoiceIdle(at: ProcessInfo.processInfo.systemUptime + 61)
    expectFalse(runtime.liveActive)
    expectEqual(stops, baselineStops + 1)

    await runtime.wakeVoice(prompt: "二つ目の質問")
    // A delayed wake transcript must not resend a question already received
    // over Live audio when the judge fails or the judge budget is exhausted.
    let before = live.texts.count
    await runtime.judgeAndRoute(TranscriptEvent(text: "ジェミニこんにちは", source: .microphone), token: runtime.sessionID)
    expectEqual(live.texts.count, before)
    runtime.settings.maxJudgeCalls = 0
    await runtime.judgeAndRoute(TranscriptEvent(text: "ジェミニもう一度", source: .microphone), token: runtime.sessionID)
    expectEqual(live.texts.count, before)
    runtime.checkVoiceIdle(at: ProcessInfo.processInfo.systemUptime + 61)
    expectFalse(runtime.liveActive)
    expectNotNil(runtime.errorMessage) // A genuinely stalled response expires.

    await runtime.wakeVoice(prompt: "最後の質問")
    runtime.setVoicePlaybackActive(true)
    runtime.closeVoice() // Explicit stop remains immediate.
    expectFalse(runtime.liveActive)
    print("Voice continuity: long response, playback drain, echo gate, duplicate wake, idle and explicit stop checked")
}
