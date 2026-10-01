import Foundation
import MeetingCore

public enum OpenAIRealtimeError: LocalizedError, Equatable {
    case missingKey, invalidModel, notConnected, setupTimedOut, disconnected
    case invalidAudio, tooMuchPendingAudio, invalidResponse
    case serverRejected(String), sessionEnded, connectionFailed

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "OpenAI APIキーを設定してください。"
        case .invalidModel: return "OpenAI Realtimeのモデル名を確認してください。"
        case .notConnected: return "OpenAI Realtimeは接続されていません。"
        case .setupTimedOut: return "OpenAI Realtimeの接続がタイムアウトしました。"
        case .disconnected: return "OpenAI Realtimeを切断しました。"
        case .invalidAudio: return "音声入力は16kHz/24kHz PCM16で送信してください。"
        case .tooMuchPendingAudio: return "音声の送信が追いつかないため接続を停止しました。"
        case .invalidResponse: return "OpenAI Realtimeからの応答を読み取れませんでした。"
        case .serverRejected(let message): return "OpenAI Realtimeエラー: \(message)"
        case .sessionEnded: return "OpenAI Realtimeセッションが終了しました。"
        case .connectionFailed: return "OpenAI Realtimeとの通信が切れました。"
        }
    }
}

/// 16kHz PCM16から24kHz PCM16へのストリーミング線形補間リサンプラー（3:2 アップサンプリング）
/// チャンク境界を跨いでも波形が途切れないよう内部状態を保持
public final class PCM16StreamingResampler {
    private var leftoverByte: UInt8?
    private var lastEvenSample: Int16?
    private var heldOddSample: Int16?
    private var isEvenPhase: Bool = true

    public init() {}

    /// チャンクを連続投入してリサンプリングされた 24kHz PCM16 を返す
    public func process(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        var rawBytes = [UInt8]()
        rawBytes.reserveCapacity(data.count + 1)
        if let leftover = leftoverByte {
            rawBytes.append(leftover)
            leftoverByte = nil
        }
        data.withUnsafeBytes { rawBytes.append(contentsOf: $0) }

        if rawBytes.count % 2 != 0 {
            leftoverByte = rawBytes.removeLast()
        }

        let sampleCount = rawBytes.count / 2
        guard sampleCount > 0 else { return Data() }

        var samples = [Int16](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { rawBytes.copyBytes(to: $0) }

        var output = [Int16]()
        output.reserveCapacity((sampleCount * 3) / 2 + 4)

        for s in samples {
            if isEvenPhase {
                // x_{2k} が到着した
                if let odd = heldOddSample {
                    // 直前の保留された奇数サンプル odd (x_{2k-1}) と現在の s (x_{2k}) から補間
                    // y = (2 * x_{2k-1} + x_{2k}) / 3
                    let yPrev = Int16(clamping: (2 * Int32(odd) + Int32(s)) / 3)
                    output.append(yPrev)
                    heldOddSample = nil
                }
                // y_{3k} = x_{2k}
                output.append(s)
                lastEvenSample = s
                isEvenPhase = false
            } else {
                // x_{2k+1} が到着した
                let even = lastEvenSample ?? s
                // y_{3k+1} = (x_{2k} + 2 * x_{2k+1}) / 3
                let y1 = Int16(clamping: (Int32(even) + 2 * Int32(s)) / 3)
                output.append(y1)
                // y_{3k+2} の計算には次の x_{2k+2} が必要なので保留
                heldOddSample = s
                lastEvenSample = nil
                isEvenPhase = true
            }
        }

        var result = Data(capacity: output.count * 2)
        output.withUnsafeBytes { result.append(contentsOf: $0) }
        return result
    }

    /// ストリーム終了時に保留中のサンプルをクランプ出力してフラッシュ
    public func finish() -> Data {
        var output = [Int16]()
        if let odd = heldOddSample {
            // 次のサンプルが存在しないため、最終サンプルで補間してフラッシュ
            // y = (2 * odd + odd) / 3 = odd
            output.append(odd)
            heldOddSample = nil
        }
        reset()
        guard !output.isEmpty else { return Data() }
        var result = Data(capacity: output.count * 2)
        output.withUnsafeBytes { result.append(contentsOf: $0) }
        return result
    }

    /// 内部状態をリセット
    public func reset() {
        leftoverByte = nil
        lastEvenSample = nil
        heldOddSample = nil
        isEvenPhase = true
    }
}

enum OpenAIRealtimeWire {
    static func request(apiKey: String, model: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw OpenAIRealtimeError.missingKey }
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty else { throw OpenAIRealtimeError.invalidModel }
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(cleanModel)") else {
            throw OpenAIRealtimeError.invalidModel
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        return request
    }

    static func sessionUpdate(instructions: String) throws -> Data {
        let prototypeTool: [String: Any] = [
            "type": "function",
            "name": "build_prototype",
            "description": "ユーザーからアプリやツールの試作作成を依頼されたときに呼び出します。会議の目的に合う具体的なアイデアを制作キューへ送ります。",
            "parameters": [
                "type": "object",
                "properties": [
                    "topic": [
                        "type": "string",
                        "description": "作成する試作品のアイデア・機能の概要"
                    ]
                ],
                "required": ["topic"]
            ]
        ]

        let session: [String: Any] = [
            "modalities": ["audio", "text"],
            "instructions": instructions,
            "voice": "alloy",
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500
            ],
            "tools": [prototypeTool],
            "tool_choice": "auto"
        ]

        return try JSONSerialization.data(withJSONObject: [
            "type": "session.update",
            "session": session
        ], options: [.sortedKeys])
    }

    /// 16kHz PCM16から24kHz PCM16への線形補間リサンプラー（一括変換ヘルパー）
    public static func resample16kTo24k(_ data: Data) -> Data {
        let resampler = PCM16StreamingResampler()
        var out = resampler.process(data)
        out.append(resampler.finish())
        return out
    }

    static func audioAppend(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count % 2 == 0 else { throw OpenAIRealtimeError.invalidAudio }
        return try JSONSerialization.data(withJSONObject: [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ])
    }

    static func textMessage(_ text: String) throws -> [Data] {
        let item: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
                    ]
                ]
            ]
        ]
        let createResponse: [String: Any] = ["type": "response.create"]
        return [
            try JSONSerialization.data(withJSONObject: item),
            try JSONSerialization.data(withJSONObject: createResponse)
        ]
    }

    static func toolResponse(callId: String, response: [String: Any]) throws -> [Data] {
        let responseJson = (try? String(data: JSONSerialization.data(withJSONObject: response), encoding: .utf8)) ?? "{}"
        let item: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": responseJson
            ]
        ]
        let createResponse: [String: Any] = ["type": "response.create"]
        return [
            try JSONSerialization.data(withJSONObject: item),
            try JSONSerialization.data(withJSONObject: createResponse)
        ]
    }

    struct Event {
        var sessionReady = false
        var interrupted = false
        var turnComplete = false
        var audio: [(Data, Double)] = []
        var text: [String] = []
        var toolCalls: [(name: String, args: [String: Any], callId: String)] = []
        var error: OpenAIRealtimeError?
    }

    static func parse(_ data: Data) throws -> Event {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw OpenAIRealtimeError.invalidResponse
        }
        var event = Event()

        switch type {
        case "session.created", "session.updated":
            event.sessionReady = true

        case "input_audio_buffer.speech_started":
            event.interrupted = true

        case "response.audio.delta":
            if let delta = object["delta"] as? String,
               let pcm = Data(base64Encoded: delta), !pcm.isEmpty {
                event.audio.append((pcm, 24_000))
            }

        case "response.audio_transcript.delta":
            if let delta = object["delta"] as? String, !delta.isEmpty {
                event.text.append(delta)
            }

        case "response.text.delta":
            if let delta = object["delta"] as? String, !delta.isEmpty {
                event.text.append(delta)
            }

        case "response.function_call_arguments.done":
            if let name = object["name"] as? String,
               let callId = object["call_id"] as? String ?? object["id"] as? String {
                var args: [String: Any] = [:]
                if let argString = object["arguments"] as? String,
                   let argData = argString.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: argData) as? [String: Any] {
                    args = parsed
                }
                event.toolCalls.append((name, args, callId))
            }

        case "response.done":
            event.turnComplete = true

        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "不明なエラー"
            event.error = .serverRejected(message)

        default:
            break
        }

        return event
    }
}

@MainActor
public final class OpenAIRealtimeClient: LiveConversationProvider {
    public static let defaultModel = "gpt-4o-realtime-preview"
    public var onAudio: ((Data, Double) -> Void)?
    public var onText: ((String) -> Void)?
    public var onInterrupted: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var onTurnComplete: (() -> Void)?
    public var onToolCall: ((String, [String: Any], String) -> Void)?
    public private(set) var isConnected = false

    private let socketFactory: (URLRequest) -> LiveSocket
    private let setupTimeout: UInt64
    private var socket: LiveSocket?
    private var receiveTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var setupWaiter: CheckedContinuation<Void, Error>?
    private var connectionID = UUID()
    private var pendingSends = 0
    private let resampler = PCM16StreamingResampler()

    public init() {
        socketFactory = { URLSessionLiveSocket(request: $0) }
        setupTimeout = 15_000_000_000
    }

    init(setupTimeout: UInt64 = 15_000_000_000, socketFactory: @escaping (URLRequest) -> LiveSocket) {
        self.setupTimeout = setupTimeout
        self.socketFactory = socketFactory
    }

    public func connect(apiKey: String, model: String, instructions: String) async throws {
        disconnect()
        let request = try OpenAIRealtimeWire.request(apiKey: apiKey, model: model)
        let sessionUpdate = try OpenAIRealtimeWire.sessionUpdate(instructions: instructions)
        let id = UUID()
        connectionID = id
        let newSocket = socketFactory(request)
        socket = newSocket

        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let data = try await newSocket.receive()
                    guard let self, self.connectionID == id else { return }
                    self.consume(try OpenAIRealtimeWire.parse(data))
                }
            } catch {
                guard let self, self.connectionID == id else { return }
                self.fail(error as? OpenAIRealtimeError ?? .connectionFailed)
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                    setupWaiter = waiter
                    timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: self?.setupTimeout ?? 0) } catch { return }
                        guard let self, self.connectionID == id else { return }
                        self.fail(.setupTimedOut)
                    }
                    Task { [weak self] in
                        do {
                            // After socket is connected, send session.update
                            try await newSocket.send(sessionUpdate)
                        } catch {
                            guard let self, self.connectionID == id else { return }
                            self.fail(.connectionFailed)
                        }
                    }
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.connectionID == id else { return }
                    self?.disconnect()
                }
            }
        } catch {
            if connectionID == id { disconnect() }
            throw error
        }
    }

    public func sendAudio(_ data: Data) async throws {
        // マイク入力（16kHz PCM16）を OpenAI Realtime の要求仕様（24kHz PCM16）にストリーミング補間
        let resampled = resampler.process(data)
        guard !resampled.isEmpty else { return }
        try await send(OpenAIRealtimeWire.audioAppend(resampled))
    }

    public func sendFrame(_ jpeg: Data) async throws {
        // OpenAI Realtime audio protocol does not currently accept live continuous video frames.
        // Silently ignore to maintain provider compatibility without interrupting the session.
    }

    public func sendText(_ text: String) async throws {
        let messages = try OpenAIRealtimeWire.textMessage(text)
        for msg in messages {
            try await send(msg)
        }
    }

    public func sendToolResponse(callId: String, name: String, response: [String: Any]) async throws {
        let messages = try OpenAIRealtimeWire.toolResponse(callId: callId, response: response)
        for msg in messages {
            try await send(msg)
        }
    }

    public func disconnect() {
        connectionID = UUID()
        isConnected = false
        resampler.reset()
        timeoutTask?.cancel(); timeoutTask = nil
        receiveTask?.cancel(); receiveTask = nil
        socket?.cancel(); socket = nil
        setupWaiter?.resume(throwing: OpenAIRealtimeError.disconnected); setupWaiter = nil
        pendingSends = 0
    }

    private func send(_ data: Data) async throws {
        guard isConnected || setupWaiter != nil, let socket else { throw OpenAIRealtimeError.notConnected }
        guard pendingSends < 16 else { fail(.tooMuchPendingAudio); throw OpenAIRealtimeError.tooMuchPendingAudio }
        let id = connectionID
        pendingSends += 1
        defer { if connectionID == id { pendingSends -= 1 } }
        do {
            try await socket.send(data)
            guard connectionID == id else { throw OpenAIRealtimeError.disconnected }
        } catch {
            if connectionID == id { fail(.connectionFailed) }
            throw error as? OpenAIRealtimeError ?? OpenAIRealtimeError.connectionFailed
        }
    }

    private func consume(_ event: OpenAIRealtimeWire.Event) {
        if let error = event.error { fail(error); return }
        if event.sessionReady {
            isConnected = true
            timeoutTask?.cancel(); timeoutTask = nil
            setupWaiter?.resume(); setupWaiter = nil
        }
        guard isConnected else { return }
        if event.interrupted { onInterrupted?() }
        for (data, rate) in event.audio { onAudio?(data, rate) }
        for text in event.text { onText?(text) }
        for (name, args, callId) in event.toolCalls { onToolCall?(name, args, callId) }
        if event.turnComplete { onTurnComplete?() }
    }

    private func fail(_ error: OpenAIRealtimeError) {
        setupWaiter?.resume(throwing: error); setupWaiter = nil
        disconnect()
        onInterrupted?()
        onError?(error.localizedDescription)
    }
}
