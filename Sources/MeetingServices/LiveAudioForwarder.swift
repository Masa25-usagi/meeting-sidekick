import Foundation
import MeetingCore

/// Sends one selected, ordered PCM stream. Never concatenate mic and meeting
/// chunks: that changes time and pitch instead of mixing the two audio sources.
@MainActor
public final class LiveAudioForwarder {
    public var onError: ((String) -> Void)?
    public var onDroppedAudio: ((Int) -> Void)?
    private var provider: LiveConversationProvider?
    private var source: AudioSource = .microphone
    private var generation = UUID()
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private let sendTimeout: TimeInterval

    public init(sendTimeout: TimeInterval = 10) {
        self.sendTimeout = sendTimeout.isFinite ? max(0.01, sendTimeout) : 10
    }

    public func configure(provider: LiveConversationProvider?, source: AudioSource) {
        guard self.provider !== provider || self.source != source else { return }
        stop()
        self.provider = provider
        self.source = source
    }

    public func append(_ data: Data, source: AudioSource) {
        guard let provider, source == self.source, !data.isEmpty else { return }
        // At 16 kHz mono PCM16 this bounds backlog to two seconds.
        guard data.count % 2 == 0 else {
            stop(); onError?("音声データの形式を読み取れませんでした。")
            return
        }
        // Capture callbacks can arrive in bursts after a busy main run loop.
        // Bound latency by dropping stale queued audio, not by disconnecting a
        // healthy voice session. Always retain complete PCM16 samples.
        let newest = data.count > 64_000 ? Data(data.suffix(64_000)) : data
        var dropped = data.count - newest.count
        while pendingBytes + newest.count > 64_000, !pending.isEmpty {
            let stale = pending.removeFirst()
            pendingBytes -= stale.count; dropped += stale.count
        }
        pending.append(newest); pendingBytes += newest.count
        if dropped > 0 { onDroppedAudio?(dropped) }
        guard task == nil else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.task = nil } }
            while self.generation == token, !Task.isCancelled, !self.pending.isEmpty {
                let chunk = self.pending.removeFirst(); self.pendingBytes -= chunk.count
                let timeout = self.sendTimeout
                let watchdog = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) }
                    catch { return }
                    guard let self, self.generation == token else { return }
                    self.stop()
                    self.onError?("音声AIへの送信が止まっています。ネット接続を確認してから呼びかけてください。")
                }
                self.watchdog = watchdog
                defer { watchdog.cancel() }
                do { try await provider.sendAudio(chunk) }
                catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.stop()
                    self.onError?("音声を届けられませんでした。もう一度呼びかけてください。")
                    return
                }
            }
        }
    }

    public func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        pending.removeAll(); pendingBytes = 0; provider = nil
    }
}
