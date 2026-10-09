import Foundation
import AVFoundation
import Speech
import MeetingCore

public struct LocalSpeechResult {
    public let text: String
    public let alternatives: [String]
    public let isFinal: Bool
    public init(text: String, alternatives: [String] = [], isFinal: Bool) {
        self.text = text; self.alternatives = alternatives; self.isFinal = isFinal
    }
}

/// Keeps the native recognizer replaceable for lifecycle checks, without replacing acoustic evaluation.
@MainActor
public protocol LocalSpeechTask: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
    func cancel()
}

@MainActor
public protocol LocalSpeechBackend: AnyObject {
    func prepare() async throws
    func recognize(source: AudioSource, request: SFSpeechAudioBufferRecognitionRequest,
                   handler: @escaping (LocalSpeechResult?, NSError?) -> Void) throws -> LocalSpeechTask
}

@MainActor
public final class AppleLocalSpeechBackend: LocalSpeechBackend {
    private var recognizers: [AudioSource: SFSpeechRecognizer] = [:]
    public init() {}

    public func prepare() async throws {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
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
                    NSLocalizedDescriptionKey: "このMacでは日本語の端末内文字起こしを利用できません。日本語の音声認識モデルとmacOSの設定を確認してください。"
                ])
            }
            prepared[source] = recognizer
        }
        recognizers = prepared
    }

    public func recognize(source: AudioSource, request: SFSpeechAudioBufferRecognitionRequest,
                          handler: @escaping (LocalSpeechResult?, NSError?) -> Void) throws -> LocalSpeechTask {
        guard let recognizer = recognizers[source], recognizer.supportsOnDeviceRecognition else {
            throw NSError(domain: "Speech", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "日本語の端末内文字起こしが利用できなくなりました。音声モデルと権限を確認してください。"
            ])
        }
        let task = recognizer.recognitionTask(with: request) { result, error in
            let update = result.map {
                LocalSpeechResult(text: $0.bestTranscription.formattedString,
                                  alternatives: $0.transcriptions.map(\.formattedString), isFinal: $0.isFinal)
            }
            Task { @MainActor in handler(update, error as NSError?) }
        }
        return AppleLocalSpeechTask(request: request, task: task)
    }
}

@MainActor
private final class AppleLocalSpeechTask: LocalSpeechTask {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask
    private var ended = false
    init(request: SFSpeechAudioBufferRecognitionRequest, task: SFSpeechRecognitionTask) {
        self.request = request; self.task = task
    }
    func append(_ buffer: AVAudioPCMBuffer) { if !ended { request.append(buffer) } }
    func endAudio() {
        guard !ended else { return }
        ended = true
        request.endAudio()
    }
    func cancel() { endAudio(); task.cancel() }
}
