import Foundation
import MeetingCore
import MeetingServices

@MainActor
private final class AudioSink: LiveConversationProvider {
    var onAudio: ((Data, Double) -> Void)?
    var onText: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    var onError: ((String) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onToolCall: ((String, [String: Any], String) -> Void)?
    var received: [Data] = []
    var hold = false
    var shouldThrow = false
    var continuation: CheckedContinuation<Void, Never>?
    func connect(apiKey: String, model: String, instructions: String) async throws {}
    func sendAudio(_ data: Data) async throws {
        received.append(data)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if shouldThrow { throw LiveClientError.disconnected }
    }
    func release() { hold = false; continuation?.resume(); continuation = nil }
    func sendFrame(_ jpeg: Data) async throws {}
    func sendText(_ text: String) async throws {}
    func sendToolResponse(callId: String, name: String, response: [String: Any]) async throws {}
    func disconnect() {}
}

@MainActor
func runLiveAudioChecks() async throws {
    let forwarder = LiveAudioForwarder()
    let old = AudioSink(), new = AudioSink()
    let mic = Data([1, 0]), meeting = Data([2, 0]), next = Data([3, 0])
    forwarder.configure(provider: old, source: .meeting)
    forwarder.append(mic, source: .microphone)
    forwarder.append(meeting, source: .meeting)
    forwarder.append(next, source: .meeting)
    try await Task.sleep(for: .milliseconds(30))
    expectEqual(old.received, [meeting, next])

    // A blocked send from an old session cannot deliver queued audio or close
    // the new session when its late failure arrives.
    old.hold = true; old.shouldThrow = true
    forwarder.append(meeting, source: .meeting)
    try await Task.sleep(for: .milliseconds(30))
    forwarder.append(next, source: .meeting)
    forwarder.configure(provider: new, source: .microphone)
    var errors = 0
    forwarder.onError = { _ in errors += 1 }
    forwarder.append(mic, source: .microphone)
    old.release()
    try await Task.sleep(for: .milliseconds(30))
    expectEqual(old.received, [meeting, next, meeting])
    expectEqual(new.received, [mic]); expectEqual(errors, 0)
    forwarder.stop()
    forwarder.append(mic, source: .microphone)
    try await Task.sleep(for: .milliseconds(20))
    expectEqual(new.received, [mic])

    let stalled = AudioSink(); stalled.hold = true
    forwarder.configure(provider: stalled, source: .meeting)
    forwarder.append(meeting, source: .meeting)
    try await Task.sleep(for: .milliseconds(20))
    forwarder.append(Data(repeating: 0, count: 64_000), source: .meeting)
    forwarder.append(next, source: .meeting)
    expectEqual(errors, 0)
    stalled.release()
    try await Task.sleep(for: .milliseconds(20))
    expectEqual(stalled.received, [meeting, next])

    // A single capture burst larger than the limit retains the newest samples.
    let burst = AudioSink()
    forwarder.configure(provider: burst, source: .meeting)
    var droppedBytes = 0
    forwarder.onDroppedAudio = { droppedBytes += $0 }
    let large = Data(repeating: 1, count: 64_000) + Data(repeating: 2, count: 32_000)
    forwarder.append(large, source: .meeting)
    try await Task.sleep(for: .milliseconds(20))
    expectEqual(burst.received, [Data(large.suffix(64_000))])
    expectEqual(droppedBytes, 32_000)
    expectEqual(errors, 0)
    forwarder.stop()

    // Truly blocked transports still close after a bounded send timeout.
    let timed = LiveAudioForwarder(sendTimeout: 0.03)
    let blocked = AudioSink(); blocked.hold = true
    var timeouts = 0
    timed.onError = { _ in timeouts += 1 }
    timed.configure(provider: blocked, source: .meeting)
    timed.append(meeting, source: .meeting)
    try await Task.sleep(for: .milliseconds(100))
    expectEqual(timeouts, 1)
    blocked.release()
    try await Task.sleep(for: .milliseconds(20))
    timed.append(next, source: .meeting)
    expectEqual(blocked.received, [meeting])
}
