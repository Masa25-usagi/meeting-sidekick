import Foundation
import AVFoundation
import Speech
import MeetingCore
import MeetingServices

@MainActor
private final class SpeechTaskFixture: LocalSpeechTask {
    let source: AudioSource
    let request: SFSpeechAudioBufferRecognitionRequest
    let handler: (LocalSpeechResult?, NSError?) -> Void
    var audio = Data()
    var ends = 0
    var cancels = 0
    init(source: AudioSource, request: SFSpeechAudioBufferRecognitionRequest,
         handler: @escaping (LocalSpeechResult?, NSError?) -> Void) {
        self.source = source; self.request = request; self.handler = handler
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        expectEqual(buffer.format.sampleRate, 16_000)
        expectEqual(buffer.format.channelCount, 1)
        if let samples = buffer.int16ChannelData?.pointee {
            audio.append(Data(bytes: samples, count: Int(buffer.frameLength) * 2))
        }
    }
    func endAudio() { ends += 1 }
    func cancel() { cancels += 1 }
    func emit(_ text: String, final: Bool = false, error: NSError? = nil, alternatives: [String] = []) {
        handler(LocalSpeechResult(text: text, alternatives: alternatives, isFinal: final), error)
    }
}

@MainActor
private final class SpeechBackendFixture: LocalSpeechBackend {
    var tasks: [SpeechTaskFixture] = []
    func prepare() async throws {}
    func recognize(source: AudioSource, request: SFSpeechAudioBufferRecognitionRequest,
                   handler: @escaping (LocalSpeechResult?, NSError?) -> Void) throws -> LocalSpeechTask {
        let task = SpeechTaskFixture(source: source, request: request, handler: handler)
        tasks.append(task)
        return task
    }
}

private func speechTone(seconds: Double = 0.1, amplitude: Double = 0.04) -> Data {
    var samples = (0..<Int(seconds * 16_000)).map { index in
        Int16((amplitude * sin(2 * .pi * 440 * Double(index) / 16_000) * 32767).rounded()).littleEndian
    }
    return samples.withUnsafeMutableBytes { Data($0) }
}

@MainActor
func runASRRegressionChecks() async throws {
    // Custom-language-model preparation must never delay meeting capture. On this Mac,
    // ja-JP model compilation currently fails while contextualStrings remain available.
    if #available(macOS 14.0, *) {
        let slowCLM = Task<SFSpeechLanguageModel.Configuration?, Never> {
            try? await Task.sleep(for: .milliseconds(500))
            return nil
        }
        CustomLanguageModelPrewarmer.shared.setPrewarmTaskForTesting(slowCLM)
        var startupConfig = LocalTranscriber.Configuration()
        startupConfig.clmWaitSeconds = 1
        let startupBackend = SpeechBackendFixture()
        let startupTranscriber = LocalTranscriber(backend: startupBackend, configuration: startupConfig)
        startupTranscriber.contextualStringsProvider = { ["OCuLink", "eGPU"] }
        let startedAt = Date()
        try await startupTranscriber.start()
        expectTrue(Date().timeIntervalSince(startedAt) < 0.2)
        startupTranscriber.append(speechTone(amplitude: 0.03), source: .microphone)
        expectEqual(startupBackend.tasks.count, 1)
        expectTrue(startupBackend.tasks[0].request.customizedLanguageModel == nil)
        expectTrue(startupBackend.tasks[0].request.contextualStrings.contains("OCuLink"))
        startupTranscriber.stop()
        CustomLanguageModelPrewarmer.shared.setReadyConfigForTesting(nil)
    }
    var config = LocalTranscriber.Configuration()
    config.clmWaitSeconds = 0
    let backend = SpeechBackendFixture()
    let transcriber = LocalTranscriber(backend: backend, configuration: config)
    var events: [TranscriptEvent] = []
    var errors: [String] = []
    var finalizations: [LocalSpeechFinalization] = []
    transcriber.onTranscript = { events.append($0) }
    transcriber.onError = { errors.append($0) }
    transcriber.onFinalization = { _, reason in finalizations.append(reason) }
    try await transcriber.start()

    // Silence never opens recognition; quieter voiced frames still retain their onset.
    transcriber.append(Data(repeating: 0, count: 3_200), source: .microphone)
    expectTrue(backend.tasks.isEmpty)
    let quiet = speechTone(amplitude: 0.012)
    expectTrue(SpeechPCM16.containsSpeech(quiet))
    expectFalse(SpeechPCM16.containsSpeech(speechTone(amplitude: 0.003)))
    transcriber.append(quiet, source: .microphone)
    let first = backend.tasks[0]
    expectEqual(first.audio.count, 6_400)
    expectTrue(first.request.requiresOnDeviceRecognition)
    expectTrue(first.request.shouldReportPartialResults)
    expectEqual(first.request.taskHint, .dictation)
    first.emit("次回の会議は金")
    transcriber.endAudio(source: .microphone)
    expectEqual(first.ends, 1)
    expectEqual(first.cancels, 0)
    expectTrue(events.filter(\.isFinal).isEmpty)

    // A later native final corrects the partial, is committed once, and keeps the raw result.
    first.emit("次回の会議は金曜日です", final: true)
    first.emit("重複通知", final: true)
    expectEqual(events.filter(\.isFinal).map(\.text), ["次回の会議は金曜日です"])
    expectEqual(events.last?.rawTranscript, "次回の会議は金曜日です")
    expectEqual(finalizations, [.recognized])
    expectEqual(first.cancels, 0)

    // The following utterance starts with all audio queued during final decoding, in order.
    let previousAudio = speechTone(amplitude: 0.03)
    transcriber.append(previousAudio, source: .microphone)
    let second = backend.tasks[1]
    second.emit("第一の発話")
    transcriber.endAudio(source: .microphone)
    let followingA = speechTone(amplitude: 0.04), followingB = speechTone(amplitude: 0.05)
    transcriber.append(followingA, source: .microphone)
    transcriber.append(followingB, source: .microphone)
    expectEqual(backend.tasks.count, 2)
    expectEqual(second.audio, previousAudio)
    second.emit("第一の発話です", final: true)
    let third = backend.tasks[2]
    expectEqual(third.audio, followingA + followingB)
    second.emit("古い発話", final: true)
    third.emit("第二の発話です", final: true)
    expectEqual(events.filter(\.isFinal).suffix(2).map(\.text), ["第一の発話です", "第二の発話です"])

    // Microphone and meeting state are independent. Old callbacks cannot change a restarted session.
    transcriber.append(previousAudio, source: .microphone)
    transcriber.append(previousAudio, source: .meeting)
    let mic = backend.tasks[3], meeting = backend.tasks[4]
    mic.emit("マイク"); meeting.emit("会議")
    mic.emit("マイク確定", final: true)
    expectEqual(meeting.cancels, 0)
    transcriber.stop()
    let countAfterStop = events.count
    meeting.emit("停止後の結果", final: true)
    expectEqual(events.count, countAfterStop)
    try await transcriber.start()
    transcriber.append(previousAudio, source: .meeting)
    let restarted = backend.tasks[5]
    meeting.emit("前の会議", final: true)
    restarted.emit("新しい会議", final: true)
    expectEqual(events.last?.text, "新しい会議")
    expectEqual(events.last?.source, .meeting)

    // Speech sometimes returns both a last partial and a normal end error. Preserve it once.
    transcriber.append(previousAudio, source: .microphone)
    let normalEnd = backend.tasks.last!
    normalEnd.emit("最後の途中結果", error: NSError(domain: "kAFAssistantErrorDomain", code: 1110))
    expectEqual(events.last?.text, "最後の途中結果")
    expectTrue(events.last?.isFinal ?? false)
    expectEqual(finalizations.last, .error)
    expectTrue(errors.isEmpty)
    transcriber.append(previousAudio, source: .microphone)
    expectFalse(backend.tasks.last === normalEnd) // No unnecessary one-second dead zone.
    transcriber.stop()

    // Buffer duration is independent of capture chunk sizes and remains sample aligned.
    var roll = PCM16Window(seconds: 0.5)
    _ = roll.append(Data(repeating: 0, count: 25_600))
    expectEqual(roll.data.count, 16_000)
    let onset = speechTone(seconds: 0.02, amplitude: 0.02)
    let diluted = Data(repeating: 0, count: 2_560) + onset
    expectTrue(SpeechPCM16.containsSpeech(diluted))
    expectFalse(SpeechPCM16.containsSpeech(Data([1])))
    var pending = PCM16Window(seconds: 3)
    _ = pending.append(Data(repeating: 0, count: 120_000))
    expectEqual(pending.data.count, 96_000)

    // Silence ends even an empty task. Timeout is bounded and a late final cannot commit again.
    var short = config
    short.silenceSeconds = 0.05; short.stableTextSeconds = 0.01; short.finalResultWaitSeconds = 1
    let silenceBackend = SpeechBackendFixture()
    let silenceTranscriber = LocalTranscriber(backend: silenceBackend, configuration: short)
    try await silenceTranscriber.start()
    silenceTranscriber.append(previousAudio, source: .microphone)
    try await Task.sleep(for: .milliseconds(220))
    expectEqual(silenceBackend.tasks[0].ends, 1)
    expectEqual(silenceBackend.tasks[0].cancels, 0)
    silenceBackend.tasks[0].emit("", final: true)
    silenceTranscriber.stop()

    short.finalResultWaitSeconds = 0.05
    let timeoutBackend = SpeechBackendFixture()
    let timeoutTranscriber = LocalTranscriber(backend: timeoutBackend, configuration: short)
    var timeoutEvents: [TranscriptEvent] = []
    var timeoutReasons: [LocalSpeechFinalization] = []
    timeoutTranscriber.onTranscript = { timeoutEvents.append($0) }
    timeoutTranscriber.onFinalization = { _, reason in timeoutReasons.append(reason) }
    try await timeoutTranscriber.start()
    timeoutTranscriber.append(previousAudio, source: .microphone)
    timeoutBackend.tasks[0].emit("待機の上限")
    timeoutTranscriber.endAudio(source: .microphone)
    try await Task.sleep(for: .milliseconds(220))
    expectEqual(timeoutReasons, [.timeout])
    expectEqual(timeoutEvents.filter(\.isFinal).count, 1)
    expectEqual(timeoutBackend.tasks[0].cancels, 1)
    timeoutBackend.tasks[0].emit("遅すぎる確定", final: true)
    expectEqual(timeoutEvents.filter(\.isFinal).count, 1)
    timeoutTranscriber.stop()

    // Domain substitutions occur only on final hypotheses; raw hypotheses are never overwritten.
    try await transcriber.start()
    transcriber.contextualStringsProvider = { ["OCuLink", "eGPU"] }
    transcriber.append(previousAudio, source: .microphone)
    let domain = backend.tasks.last!
    domain.emit("eGPUならオキュリンクかな", alternatives: ["eGPUならOCuLinkかな"])
    expectEqual(events.last?.text, "eGPUならオキュリンクかな")
    domain.emit("eGPUならオキュリンクかな", final: true, alternatives: ["eGPUならOCuLinkかな"])
    expectEqual(events.last?.text, "eGPUならOCuLinkかな")
    expectEqual(events.last?.rawTranscript, "eGPUならオキュリンクかな")
    transcriber.stop()

    try await runSpeechRolloverChecks()
    runCapturePCMChecks()
    print("ASR lifecycle: native final wait, next utterance buffering, source isolation, stale/duplicate callbacks, quiet onset and bounded fallback checked")
}

@MainActor
private func waitForSpeechFixture(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    expectTrue(condition())
}

/// Verify delivery across the production duration rollover, including the
/// race where the native final arrives before the next capture buffer.
@MainActor
private func runSpeechRolloverChecks() async throws {
    let loud = speechTone(amplitude: 0.04)
    let quiet = speechTone(amplitude: 0.007)
    expectFalse(SpeechPCM16.containsSpeech(quiet))
    expectTrue(SpeechPCM16.containsSpeech(quiet, continuing: true))
    var config = LocalTranscriber.Configuration()
    config.clmWaitSeconds = 0
    config.maximumUtteranceSeconds = 0.05
    config.silenceSeconds = 10

    for source in [AudioSource.microphone, .meeting] {
        for bufferBeforeFinal in [false, true] {
            let backend = SpeechBackendFixture()
            let transcriber = LocalTranscriber(backend: backend, configuration: config)
            var events: [TranscriptEvent] = []
            transcriber.onTranscript = { events.append($0) }
            try await transcriber.start()
            transcriber.append(loud, source: source)
            let first = backend.tasks[0]
            first.emit("前半")
            try await waitForSpeechFixture { first.ends == 1 }
            expectEqual(first.cancels, 0)
            if bufferBeforeFinal { transcriber.append(quiet, source: source) }
            first.emit("前半の発話", final: true)
            expectEqual(backend.tasks.count, 2)
            guard backend.tasks.count == 2 else { transcriber.stop(); continue }
            let next = backend.tasks[1]
            expectEqual(next.audio, bufferBeforeFinal ? quiet : Data())
            transcriber.append(quiet, source: source)
            expectEqual(next.audio, bufferBeforeFinal ? quiet + quiet : quiet)
            expectEqual(first.audio, loud) // No preceding speech is replayed.
            first.emit("古い通知", final: true)
            next.emit("後半の発話", final: true)
            expectEqual(events.filter(\.isFinal).map(\.text), ["前半の発話", "後半の発話"])
            expectEqual(Set(events.filter(\.isFinal).map(\.id)).count, 2)
            transcriber.stop()
        }
    }

    // A bounded final timeout and Speech's normal end error must also retain
    // speech queued after a duration rollover.
    for useTimeout in [false, true] {
        var fallbackConfig = config
        fallbackConfig.finalResultWaitSeconds = useTimeout ? 0.08 : 2
        let backend = SpeechBackendFixture()
        let transcriber = LocalTranscriber(backend: backend, configuration: fallbackConfig)
        var reasons: [LocalSpeechFinalization] = []
        transcriber.onFinalization = { _, reason in reasons.append(reason) }
        try await transcriber.start()
        transcriber.append(loud, source: .microphone)
        let first = backend.tasks[0]
        first.emit("前半")
        try await waitForSpeechFixture { first.ends == 1 }
        transcriber.append(quiet, source: .microphone)
        if useTimeout {
            try await waitForSpeechFixture { backend.tasks.count == 2 }
            expectEqual(reasons.first, .timeout)
        } else {
            first.emit("前半", error: NSError(domain: "kAFAssistantErrorDomain", code: 1110))
            expectEqual(reasons.first, .error)
        }
        expectEqual(backend.tasks.count, 2)
        if backend.tasks.count == 2 { expectEqual(backend.tasks[1].audio, quiet) }
        transcriber.stop()
    }

    // Real recognition failures keep their retry backoff, even at the duration limit.
    let errorBackend = SpeechBackendFixture()
    let errorTranscriber = LocalTranscriber(backend: errorBackend, configuration: config)
    try await errorTranscriber.start()
    errorTranscriber.append(loud, source: .microphone)
    try await waitForSpeechFixture { errorBackend.tasks[0].ends == 1 }
    errorTranscriber.append(quiet, source: .microphone)
    errorBackend.tasks[0].emit("前半", error: NSError(domain: "SpeechFixtureFailure", code: 99))
    errorTranscriber.append(loud, source: .microphone)
    expectEqual(errorBackend.tasks.count, 1)
    errorTranscriber.stop()

    // An explicit end and a rollover that coincides with silence do not inherit
    // continuation sensitivity or open a new recognizer for quiet background input.
    for explicitEnd in [false, true] {
        var pausedConfig = config
        pausedConfig.silenceSeconds = 0.05
        pausedConfig.stableTextSeconds = 0
        let backend = SpeechBackendFixture()
        let transcriber = LocalTranscriber(backend: backend, configuration: pausedConfig)
        try await transcriber.start()
        transcriber.append(loud, source: .microphone)
        let first = backend.tasks[0]
        if explicitEnd { transcriber.endAudio(source: .microphone) }
        else { try await waitForSpeechFixture { first.ends == 1 } }
        transcriber.append(quiet, source: .microphone)
        first.emit("発話の終わり", final: true)
        transcriber.append(quiet, source: .microphone)
        expectEqual(backend.tasks.count, 1)
        transcriber.stop()
    }

    // A continuation opened just before capture falls silent may finish empty.
    // It must not repeatedly roll over and churn through empty recognition tasks.
    let emptyBackend = SpeechBackendFixture()
    let emptyTranscriber = LocalTranscriber(backend: emptyBackend, configuration: config)
    try await emptyTranscriber.start()
    emptyTranscriber.append(loud, source: .microphone)
    try await waitForSpeechFixture { emptyBackend.tasks[0].ends == 1 }
    emptyBackend.tasks[0].emit("前半", final: true)
    expectEqual(emptyBackend.tasks.count, 2)
    if emptyBackend.tasks.count == 2 {
        let empty = emptyBackend.tasks[1]
        try await waitForSpeechFixture { empty.ends == 1 }
        empty.emit("", final: true)
        expectEqual(emptyBackend.tasks.count, 2)
    }
    emptyTranscriber.stop()
    print("ASR rollover: quiet continuation on both inputs, early final, bounded fallback, error backoff and silence checked")
}

private func runCapturePCMChecks() {
    for rate in [16_000.0, 44_100.0, 48_000.0] {
        for channels in [1, 2] {
            for activeChannel in 0..<channels {
                let converter = PCM16Converter()
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
                let chunkFrames = Int(rate / 10)
                var output = Data()
                for chunk in 0..<10 {
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames))!
                    buffer.frameLength = buffer.frameCapacity
                    for channel in 0..<channels {
                        for index in 0..<chunkFrames {
                            buffer.floatChannelData![channel][index] = channel == activeChannel
                                ? Float(0.2 * sin(2 * .pi * 440 * Double(chunk * chunkFrames + index) / rate)) : 0
                        }
                    }
                    output.append(converter.convert(buffer) ?? Data())
                }
                expectTrue(abs(output.count / 2 - 16_000) < 400) // Streaming converter filter latency.
                expectTrue(SpeechPCM16.containsSpeech(output))
                let rms = output.withUnsafeBytes { raw in
                    let values = raw.bindMemory(to: Int16.self)
                    return sqrt(values.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(values.count))
                }
                expectTrue(rms > (channels == 1 ? 0.12 : 0.06))
                expectTrue(rms < (channels == 1 ? 0.16 : 0.09))
            }
        }
    }
    // An interleaved PCM16 right channel must survive conversion too.
    let stereo = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
    let input = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4_800)!
    input.frameLength = 4_800
    for index in 0..<4_800 {
        input.int16ChannelData![0][index * 2] = 0
        input.int16ChannelData![0][index * 2 + 1] = Int16(6_000 * sin(2 * .pi * 440 * Double(index) / 48_000))
    }
    let converter = PCM16Converter()
    expectTrue(SpeechPCM16.containsSpeech(converter.convert(input) ?? Data()))
    // Switching the input format must recreate the converter instead of interpreting the old rate/channels.
    let mono = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let next = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4_410)!
    next.frameLength = 4_410
    for index in 0..<4_410 { next.floatChannelData![0][index] = Float(0.2 * sin(2 * .pi * 440 * Double(index) / 44_100)) }
    expectTrue(SpeechPCM16.containsSpeech(converter.convert(next) ?? Data()))
}
