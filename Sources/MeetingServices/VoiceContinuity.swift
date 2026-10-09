import Foundation
import MeetingCore

/// The configured connection budget is a soft deadline: finish the current
/// response and its queued playback first. A dead response still expires.
struct VoiceSessionActivity {
    enum Expiry { case waiting, idle, stalledResponse }
    private var startedAt: TimeInterval = 0
    private(set) var lastActivity: TimeInterval = 0
    private(set) var replyPending = false
    private(set) var playbackActive = false

    mutating func begin(at now: TimeInterval) {
        self = VoiceSessionActivity()
        startedAt = now; lastActivity = now
    }

    mutating func request(at now: TimeInterval) {
        lastActivity = now; replyPending = true
    }
    mutating func response(at now: TimeInterval) {
        lastActivity = now; replyPending = true
    }
    mutating func turnEnded(at now: TimeInterval) {
        lastActivity = now; replyPending = false
    }
    mutating func humanSpeech(at now: TimeInterval) {
        lastActivity = now; replyPending = true
    }
    mutating func playback(_ active: Bool, at now: TimeInterval) {
        playbackActive = active; lastActivity = now
    }
    func expiry(at now: TimeInterval, sessionSeconds: TimeInterval) -> Expiry {
        guard !playbackActive else { return .waiting }
        let quiet = max(0, now - lastActivity)
        if replyPending {
            // A missing turnComplete must not keep a dead connection forever.
            return quiet >= max(60, sessionSeconds) ? .stalledResponse : .waiting
        }
        return now - startedAt >= sessionSeconds ? .idle : .waiting
    }
}

/// ScreenCaptureKit's microphone input has no echo cancellation. While local
/// playback runs, mask it with silence rather than feeding the AI its own voice.
/// Remote meeting input remains available for genuine barge-in.
public struct PlaybackInputGate {
    private var active = false
    private var resumeAt: TimeInterval = -.infinity
    private let tailSeconds: TimeInterval
    public init(tailSeconds: TimeInterval = 0.35) { self.tailSeconds = max(0, tailSeconds) }
    public mutating func playbackChanged(_ active: Bool, at now: TimeInterval) {
        self.active = active
        if !active { resumeAt = now + tailSeconds }
    }
    public func suppresses(_ source: AudioSource, at now: TimeInterval) -> Bool {
        source == .microphone && (active || now < resumeAt)
    }
}

/// Gemini can deliver audio faster than real-time. Buffer a whole ordinary
/// response; exceeding the memory bound never stops the already queued speech.
public struct PCMPlaybackQueue {
    public private(set) var seconds: TimeInterval = 0
    public private(set) var overflowed = false
    private let limit: TimeInterval
    public init(limitSeconds: TimeInterval = 180) { limit = max(1, limitSeconds) }
    public mutating func reserve(_ duration: TimeInterval) -> Bool {
        guard !overflowed, duration.isFinite, duration > 0 else { return false }
        guard seconds + duration <= limit else { overflowed = true; return false }
        seconds += duration
        return true
    }
    public mutating func played(_ duration: TimeInterval) { seconds = max(0, seconds - duration) }
    public mutating func reset() { seconds = 0; overflowed = false }
}
