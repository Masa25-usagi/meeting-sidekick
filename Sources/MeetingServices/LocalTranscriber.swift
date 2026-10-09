import Foundation
import AVFoundation
import Speech
import MeetingCore

public enum LocalSpeechFinalization: String, Codable {
    case recognized, timeout, error
}

@MainActor
public final class LocalTranscriber {
    public struct Configuration {
        public var silenceSeconds: TimeInterval = 1.2
        public var stableTextSeconds: TimeInterval = 0.3
        public var maximumUtteranceSeconds: TimeInterval = 45
        public var finalResultWaitSeconds: TimeInterval = 2
        public var clmWaitSeconds: TimeInterval = 1.5
        public init() {}
    }
    public var onTranscript: ((TranscriptEvent) -> Void)?
    public var onError: ((String) -> Void)?
    public var onDiagnostics: ((String) -> Void)?
    /// Distinguishes a native final result from a bounded fallback to the last partial.
    public var onFinalization: ((String, LocalSpeechFinalization) -> Void)?
    public var contextualStringsProvider: (@MainActor () -> [String])?
    private struct Utterance {
        let id = UUID().uuidString
        let started: TimeInterval
        let hints: [String]
        var text = ""
        var raw = ""
        var lastSpeech: TimeInterval
        var lastText: TimeInterval
        var hasSpeech = false
        var endedAt: TimeInterval?
        var continuesAfterEnd = false
        var task: LocalSpeechTask?
    }
    private let backend: LocalSpeechBackend
    private let configuration: Configuration
    private var utterances: [AudioSource: Utterance] = [:]
    private var preRoll: [AudioSource: PCM16Window] = [:]
    private var pending: [AudioSource: PCM16Window] = [:]
    private var failures: [AudioSource: Int] = [:]
    private var retryAfter: [AudioSource: TimeInterval] = [:]
    private var suspended: Set<AudioSource> = []
    private var timer: Task<Void, Never>?
    private var clmPreparationTask: Task<Void, Never>?
    private var running = false
    private var generation = UUID()
    private var customLanguageModelConfig: SFSpeechLanguageModel.Configuration?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public init(backend: LocalSpeechBackend? = nil, configuration: Configuration = Configuration()) {
        self.backend = backend ?? AppleLocalSpeechBackend()
        self.configuration = configuration
    }

    public func prewarmCLM() { _ = CustomLanguageModelPrewarmer.shared.startPrewarm() }
    public func prepareCustomLanguageModelIfNeeded() { prewarmCLM() }
    public var currentCLMConfig: SFSpeechLanguageModel.Configuration? { customLanguageModelConfig }
    public func setCLMConfigForTesting(_ config: SFSpeechLanguageModel.Configuration?) { customLanguageModelConfig = config }

    @discardableResult
    public func waitForCLMPreparation(timeoutSeconds: TimeInterval = 1.5) async -> SFSpeechLanguageModel.Configuration? {
        let token = generation
        guard !Task.isCancelled else { return nil }
        if let existing = customLanguageModelConfig, CustomLanguageModelHelper.hasCompiledArtifacts(existing) { return existing }
        let config = await CustomLanguageModelPrewarmer.shared.waitForConfiguration(timeoutSeconds: timeoutSeconds)
        guard generation == token, !Task.isCancelled else { return nil }
        customLanguageModelConfig = config
        onDiagnostics?(config == nil
            ? "専門語の補助モデルはまだ利用できません。語彙ヒントで認識を続けます。"
            : "専門語の補助モデルを準備しました。認識精度は音声評価で確認します。")
        return config
    }

    public func makeRecognitionRequest(hints: [String] = []) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        let resolved = hints.isEmpty ? (contextualStringsProvider?() ?? SpeechContextVocabulary.defaultBaseVocabulary) : hints
        if let ready = CustomLanguageModelPrewarmer.shared.availableConfiguration() { customLanguageModelConfig = ready }
        else if let existing = customLanguageModelConfig, !CustomLanguageModelHelper.hasCompiledArtifacts(existing) {
            customLanguageModelConfig = nil
        }
        CustomLanguageModelPrewarmer.configureRecognitionRequest(request: request, clmConfig: customLanguageModelConfig,
                                                                 contextualStrings: resolved)
        request.taskHint = .dictation
        return request
    }

    public func start() async throws {
        stop()
        let token = generation
        try await backend.prepare()
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        running = true
        if configuration.clmWaitSeconds > 0 {
            clmPreparationTask = Task { [weak self] in
                guard let self else { return }
                _ = await self.waitForCLMPreparation(timeoutSeconds: self.configuration.clmWaitSeconds)
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.running, self.generation == token else { return }
                self.poll()
            }
        }
    }

    private func poll() {
        let time = now
        for source in [AudioSource.microphone, .meeting] {
            guard let utterance = utterances[source] else { continue }
            if let ended = utterance.endedAt {
                if time - ended >= configuration.finalResultWaitSeconds {
                    onDiagnostics?("確定結果の待機が上限に達したため、最後の途中結果を保存しました。")
                    complete(source, reason: .timeout)
                }
            } else if time - utterance.started >= configuration.maximumUtteranceSeconds {
                endAudio(source: source, continuesSpeech: utterance.hasSpeech &&
                         time - utterance.lastSpeech < configuration.silenceSeconds)
            } else if time - utterance.lastSpeech >= configuration.silenceSeconds &&
                      time - utterance.lastText >= configuration.stableTextSeconds {
                endAudio(source: source)
            }
        }
    }

    private func begin(_ source: AudioSource) -> Bool {
        guard running, utterances[source] == nil, !suspended.contains(source),
              now >= (retryAfter[source] ?? 0) else { return false }
        let hints = contextualStringsProvider?() ?? SpeechContextVocabulary.defaultBaseVocabulary
        let time = now
        let utterance = Utterance(started: time, hints: hints, lastSpeech: time, lastText: time)
        let token = generation, id = utterance.id
        utterances[source] = utterance
        do {
            let task = try backend.recognize(source: source, request: makeRecognitionRequest(hints: hints)) { [weak self] result, error in
                guard let self, self.running, self.generation == token, self.utterances[source]?.id == id else { return }
                self.receive(result, error: error, source: source)
            }
            guard utterances[source]?.id == id else { task.cancel(); return false }
            utterances[source]?.task = task
            return true
        } catch {
            handleError(error as NSError, source: source)
            return false
        }
    }

    private func receive(_ result: LocalSpeechResult?, error: NSError?, source: AudioSource) {
        let token = generation
        if let result, var utterance = utterances[source] {
            // Domain candidate substitution waits for the recognizer's final hypotheses.
            let selected = result.isFinal
                ? SpeechTranscriptionSelector.selectCandidate(best: result.text, alternatives: result.alternatives,
                                                              domainVocabulary: utterance.hints).normalizedTranscript
                : result.text
            let changed = utterance.text != selected || utterance.raw != result.text
            if changed { utterance.lastText = now }
            utterance.text = selected; utterance.raw = result.text
            utterances[source] = utterance
            if result.isFinal {
                failures[source] = 0; retryAfter[source] = nil
                complete(source, reason: .recognized)
                return
            }
            if changed, !selected.isEmpty {
                onTranscript?(TranscriptEvent(id: utterance.id, text: selected, rawTranscript: result.text,
                                              source: source, isFinal: false))
            }
        }
        // Speech can return a last partial and an error in the same callback.
        if let error, running, generation == token, utterances[source] != nil { handleError(error, source: source) }
    }

    private func handleError(_ error: NSError, source: AudioSource) {
        let normalPause = ["kAFAssistantErrorDomain", "kLSRErrorDomain"].contains(error.domain) &&
                          [203, 216, 1110].contains(error.code)
        if !normalPause {
            let count = (failures[source] ?? 0) + 1
            failures[source] = count
            if count >= 3 { suspended.insert(source) }
            else { retryAfter[source] = now + (count == 1 ? 2 : 5) }
            let input = source == .microphone ? "マイク" : "会議音声"
            onError?("\(input)の端末内文字起こしが失敗しました（\(count)/3）。\(count >= 3 ? "この入力を停止しました。入力を開始し直してください。" : "少し間をあけ、次の発話で再試行します。") [\(error.domain):\(error.code)] \(error.localizedDescription)")
        }
        if !(utterances[source]?.text.isEmpty ?? true) {
            onDiagnostics?("認識が終了したため、最後の途中結果を保存しました。Appleの確定結果とは区別して記録します。")
        }
        complete(source, reason: .error)
    }

    public func append(_ data: Data, source: AudioSource) {
        guard running, source == .microphone || source == .meeting, !suspended.contains(source),
              !data.isEmpty, data.count.isMultiple(of: 2), data.count <= 64_000 else { return }
        let speech = SpeechPCM16.containsSpeech(data, continuing: utterances[source]?.endedAt == nil && utterances[source] != nil)
        if utterances[source]?.endedAt != nil {
            var window = pending[source] ?? PCM16Window(seconds: 3)
            let dropped = window.append(data)
            pending[source] = window
            if dropped > 0 { onDiagnostics?("認識待機中の入力が3秒を超えたため、古い音声を省略しました。") }
            return
        }
        if utterances[source] == nil {
            guard speech, begin(source) else {
                var window = preRoll[source] ?? PCM16Window(seconds: 0.5)
                _ = window.append(data); preRoll[source] = window
                return
            }
            if let leading = preRoll.removeValue(forKey: source)?.data, let buffer = SpeechPCM16.buffer(leading) {
                utterances[source]?.task?.append(buffer)
            }
        }
        if speech {
            utterances[source]?.lastSpeech = now
            utterances[source]?.hasSpeech = true
        }
        if let buffer = SpeechPCM16.buffer(data) { utterances[source]?.task?.append(buffer) }
    }

    /// Ends input without cancelling decoding. Subsequent audio waits for this final result.
    public func endAudio(source: AudioSource) {
        endAudio(source: source, continuesSpeech: false)
    }

    private func endAudio(source: AudioSource, continuesSpeech: Bool) {
        guard var utterance = utterances[source], utterance.endedAt == nil else { return }
        utterance.endedAt = now
        utterance.continuesAfterEnd = continuesSpeech
        utterances[source] = utterance
        utterance.task?.endAudio()
    }

    private func complete(_ source: AudioSource, reason: LocalSpeechFinalization) {
        guard let utterance = utterances.removeValue(forKey: source) else { return }
        let token = generation
        let buffered = pending.removeValue(forKey: source)?.data
        // Remove the ID before cancellation or client callbacks can re-enter.
        if reason != .recognized { utterance.task?.cancel() }
        onFinalization?(utterance.id, reason)
        if !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onTranscript?(TranscriptEvent(id: utterance.id, text: utterance.text, rawTranscript: utterance.raw,
                                          source: source, isFinal: true))
        }
        guard running, generation == token, !suspended.contains(source) else { return }
        // A duration limit splits an ongoing utterance, rather than requiring a
        // new loud onset. Open its continuation even if decoding finishes before
        // the next capture chunk. Silence and error backoff retain their usual gates.
        if utterance.continuesAfterEnd { _ = begin(source) }
        guard let buffered else { return }
        // Preserve order and the beginning of the next utterance; never replay the preceding utterance.
        for offset in stride(from: 0, to: buffered.count, by: 3_200) {
            append(buffered.subdata(in: offset..<min(offset + 3_200, buffered.count)), source: source)
        }
    }

    public func stop() {
        running = false; generation = UUID()
        timer?.cancel(); timer = nil
        clmPreparationTask?.cancel(); clmPreparationTask = nil
        let previous = utterances.values.compactMap(\.task)
        utterances.removeAll()
        for task in previous { task.cancel() }
        preRoll.removeAll(); pending.removeAll(); failures.removeAll()
        retryAfter.removeAll(); suspended.removeAll()
    }
}
