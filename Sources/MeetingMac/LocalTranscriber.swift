import AVFoundation
import Speech
import MeetingCore
import MeetingServices

@MainActor
final class LocalTranscriber {
    var onTranscript: ((TranscriptEvent) -> Void)?
    var onError: ((String) -> Void)?
    var onDiagnostics: ((String) -> Void)?
    var contextualStringsProvider: (@MainActor () -> [String])?
    private var recognizers: [AudioSource: SFSpeechRecognizer] = [:]
    private var requests: [AudioSource: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var tasks: [AudioSource: SFSpeechRecognitionTask] = [:]
    private var ids: [AudioSource: String] = [:]
    private var texts: [AudioSource: String] = [:]
    private var rawTexts: [AudioSource: String] = [:]
    private var lastSpeech: [AudioSource: Date] = [:]
    private var lastText: [AudioSource: Date] = [:]
    private var opened: [AudioSource: Date] = [:]
    private var failures: [AudioSource: Int] = [:]
    private var retryAfter: [AudioSource: Date] = [:]
    private var suspended: Set<AudioSource> = []
    private var preRoll: [AudioSource: [Data]] = [:]
    private var timer: Task<Void, Never>?
    private var running = false
    private var generation = UUID()
    private var customLanguageModelConfig: SFSpeechLanguageModel.Configuration?

    public init() {
        if #available(macOS 14.0, *) {
            _ = CustomLanguageModelPrewarmer.shared.startPrewarm()
        }
    }

    public func prewarmCLM() {
        if #available(macOS 14.0, *) {
            _ = CustomLanguageModelPrewarmer.shared.startPrewarm()
        }
    }

    @discardableResult
    public func waitForCLMPreparation(timeoutSeconds: TimeInterval = 1.5) async -> SFSpeechLanguageModel.Configuration? {
        let token = generation
        guard !Task.isCancelled else { return nil }
        if #available(macOS 14.0, *) {
            if let existing = customLanguageModelConfig,
               CustomLanguageModelHelper.hasCompiledArtifacts(existing) { return existing }
            let config = await CustomLanguageModelPrewarmer.shared.waitForConfiguration(timeoutSeconds: timeoutSeconds)
            guard generation == token, !Task.isCancelled else { return nil }
            customLanguageModelConfig = config
            if config == nil {
                onDiagnostics?("CLM prewarm未完了/タイムアウト: contextualStringsで音声認識を開始します（次回開始時に再試行可能）")
            } else {
                onDiagnostics?("CLM準備完了: 次の音声認識に専門語の補助モデルを適用します（認識精度は未検証）")
            }
            return config
        }
        return nil
    }

    public var currentCLMConfig: SFSpeechLanguageModel.Configuration? {
        customLanguageModelConfig
    }

    public func setCLMConfigForTesting(_ config: SFSpeechLanguageModel.Configuration?) {
        customLanguageModelConfig = config
    }

    func prepareCustomLanguageModelIfNeeded() {
        prewarmCLM()
    }

    func makeRecognitionRequest(hints: [String] = []) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        let resolvedHints = !hints.isEmpty ? hints : (contextualStringsProvider?() ?? SpeechContextVocabulary.defaultBaseVocabulary)
        if #available(macOS 14.0, *) {
            // A model that finished after the bounded start wait becomes available
            // on the next utterance, without restarting an active recognition task.
            if let ready = CustomLanguageModelPrewarmer.shared.availableConfiguration() {
                customLanguageModelConfig = ready
            } else if let existing = customLanguageModelConfig,
                      !CustomLanguageModelHelper.hasCompiledArtifacts(existing) {
                customLanguageModelConfig = nil
            }
            CustomLanguageModelPrewarmer.configureRecognitionRequest(
                request: request,
                clmConfig: customLanguageModelConfig,
                contextualStrings: resolvedHints
            )
        } else {
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if !resolvedHints.isEmpty {
                request.contextualStrings = Array(resolvedHints.prefix(100))
            }
        }
        return request
    }

    func start() async throws {
        stop()
        let token = UUID()
        generation = token
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard authorization == .authorized else {
            throw NSError(domain: "Speech", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "音声認識の許可が必要です。システム設定の「プライバシーとセキュリティ > 音声認識」で『会議の相棒』を許可してください。"
            ])
        }
        var prepared: [AudioSource: SFSpeechRecognizer] = [:]
        for source in [AudioSource.microphone, .meeting] {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")),
                  recognizer.supportsOnDeviceRecognition else {
                throw NSError(domain: "Speech", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "このMacでは日本語の端末内文字起こしを利用できません。日本語の音声認識モデルが利用可能か、macOSの設定を確認してください。音声をAppleのサーバーへ送る方式には切り替えません。"
                ])
            }
            prepared[source] = recognizer
        }
        // CLM準備中であれば最大1.5秒だけ完了を待機（会議開始を長時間ブロックしない）
        if #available(macOS 14.0, *) {
            await waitForCLMPreparation(timeoutSeconds: 1.5)
        }

        // stop() or a newer start() may have run during the bounded preparation wait.
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        recognizers = prepared
        running = true

        // 定期タイマーで無音判定を行い、文の区切りで確定イベントを発行
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.running, !Task.isCancelled else { return }
                for source in [AudioSource.microphone, .meeting] {
                    let now = Date()
                    if let text = self.texts[source], !text.isEmpty,
                       now.timeIntervalSince(self.lastSpeech[source] ?? .distantPast) > 0.9,
                       now.timeIntervalSince(self.lastText[source] ?? now) > 0.9 {
                        self.finish(source, restartImmediately: false)
                    } else if let openDate = self.opened[source], now.timeIntervalSince(openDate) > 45 {
                        // 長時間開きっぱなしのセッションを安全にリセット
                        self.finish(source, restartImmediately: false)
                    }
                }
            }
        }
    }

    private func begin(_ source: AudioSource) {
        guard running, !suspended.contains(source),
              Date() >= (retryAfter[source] ?? .distantPast),
              let recognizer = recognizers[source] else { return }
        guard recognizer.supportsOnDeviceRecognition else {
            suspended.insert(source)
            onError?("\(source == .microphone ? "マイク" : "会議音声")の端末内文字起こしが利用できなくなったため停止しました。音声をサーバーへは送りません。設定を確認して、入力を開始し直してください。")
            return
        }
        // 既存のタスクを安全に片付け
        cleanup(source)

        let request = makeRecognitionRequest()

        let id = UUID().uuidString
        ids[source] = id
        texts[source] = ""
        opened[source] = Date()
        requests[source] = request
        recognizers[source] = recognizer

        tasks[source] = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.running, self.ids[source] == id else { return }
                if let result {
                    let best = result.bestTranscription.formattedString
                    let alternatives = result.transcriptions.map { $0.formattedString }
                    let domainVocab = self.contextualStringsProvider?() ?? SpeechContextVocabulary.defaultBaseVocabulary
                    let selection = SpeechTranscriptionSelector.selectCandidate(
                        best: best,
                        alternatives: alternatives,
                        domainVocabulary: domainVocab
                    )
                    let text = selection.normalizedTranscript
                    let raw = selection.rawTranscript
                    if self.texts[source] != text { self.lastText[source] = Date() }
                    self.texts[source] = text
                    self.rawTexts[source] = raw
                    if !text.isEmpty { self.failures[source] = 0 }
                    self.onTranscript?(TranscriptEvent(id: id, text: text, rawTranscript: raw, source: source, isFinal: false))
                    if result.isFinal {
                        self.finish(source, restartImmediately: false)
                    }
                } else if let error = error as NSError? {
                    // Apple Speechの正常な会話区切り（無音タイムアウトまたは明示的キャンセル）
                    let isSpeechError = error.domain == "kAFAssistantErrorDomain" || error.domain == "kLSRErrorDomain"
                    let isNormalPause = isSpeechError && [203, 216, 1110].contains(error.code)

                    if isNormalPause {
                        // 発話の自然な切れ目として安全に終了し、次回発話に備える
                        self.finish(source, restartImmediately: false)
                        self.retryAfter[source] = Date().addingTimeInterval(1)
                        return
                    }

                    // 復旧しないエラーや権限・エンジン異常を明示的に通知
                    let errorDetails = "[\(source == .microphone ? "マイク" : "会議音声")] \(error.localizedDescription) (code: \(error.code), domain: \(error.domain))"
                    self.finish(source, restartImmediately: false)
                    let count = (self.failures[source] ?? 0) + 1
                    self.failures[source] = count
                    if count >= 3 {
                        self.suspended.insert(source)
                        self.onError?("端末内文字起こしが3回続けて失敗したため、この入力の文字起こしを停止しました。音声モデルと権限を確認して、入力を開始し直してください。サーバー方式には切り替えません。\n\(errorDetails)")
                    } else {
                        let delay = count == 1 ? 2.0 : 5.0
                        self.retryAfter[source] = Date().addingTimeInterval(delay)
                        self.onError?("端末内文字起こしエラー。\(Int(delay))秒以上あけて、次の発話時に再試行します（\(count)/3）。\n\(errorDetails)")
                    }
                }
            }
        }
    }

    func append(_ data: Data, source: AudioSource) {
        guard running, source == .microphone || source == .meeting,
              !suspended.contains(source), !data.isEmpty, data.count.isMultiple(of: 2),
              data.count <= 64_000 else { return }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let output = buffer.int16ChannelData?.pointee else { return }

        buffer.frameLength = buffer.frameCapacity
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: output, count: Int(buffer.frameLength) * 2))

        var energy = 0.0
        for i in 0..<Int(buffer.frameLength) {
            let v = Double(output[i]) / 32768
            energy += v * v
        }
        let containsSpeech = sqrt(energy / Double(max(1, buffer.frameLength))) > 0.012
        if containsSpeech {
            lastSpeech[source] = Date()
        }
        if requests[source] == nil {
            // Keep up to three capture chunks so the first syllable is retained,
            // but silence alone never repeatedly spins up the recognition engine.
            var buffered = preRoll[source] ?? []
            buffered.append(data)
            if buffered.count > 3 { buffered.removeFirst(buffered.count - 3) }
            preRoll[source] = buffered
            guard containsSpeech, Date() >= (retryAfter[source] ?? .distantPast) else { return }
            begin(source)
            guard let request = requests[source] else { return }
            for chunk in preRoll.removeValue(forKey: source) ?? [] {
                guard let leading = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count / 2)),
                      let samples = leading.int16ChannelData?.pointee else { continue }
                leading.frameLength = leading.frameCapacity
                chunk.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: chunk.count))
                request.append(leading)
            }
        } else {
            requests[source]?.append(buffer)
        }
    }

    private func finish(_ source: AudioSource, restartImmediately: Bool) {
        guard let id = ids.removeValue(forKey: source) else { return }
        let text = texts.removeValue(forKey: source) ?? ""
        let raw = rawTexts.removeValue(forKey: source) ?? text
        cleanup(source)

        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onTranscript?(TranscriptEvent(id: id, text: text, rawTranscript: raw, source: source, isFinal: true))
        }

        if restartImmediately && running {
            begin(source)
        }
    }

    private func cleanup(_ source: AudioSource) {
        requests.removeValue(forKey: source)?.endAudio()
        tasks.removeValue(forKey: source)?.cancel()
        opened.removeValue(forKey: source)
        lastText.removeValue(forKey: source)
    }

    func stop() {
        running = false
        generation = UUID()
        timer?.cancel()
        timer = nil
        ids.removeAll()
        texts.removeAll()
        rawTexts.removeAll()
        for task in tasks.values { task.cancel() }
        for request in requests.values { request.endAudio() }
        tasks.removeAll()
        requests.removeAll()
        recognizers.removeAll()
        opened.removeAll()
        lastText.removeAll()
        lastSpeech.removeAll()
        retryAfter.removeAll()
        failures.removeAll()
        suspended.removeAll()
        preRoll.removeAll()
    }
}
