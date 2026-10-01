import Foundation

@MainActor
public protocol LiveConversationProvider: AnyObject {
    var onAudio: ((Data, Double) -> Void)? { get set }
    /// The assistant's output transcript; never microphone input.
    var onText: ((String) -> Void)? { get set }
    var onInterrupted: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onTurnComplete: (() -> Void)? { get set }
    var onToolCall: ((String, [String: Any], String) -> Void)? { get set }
    func connect(apiKey: String, model: String, instructions: String) async throws
    func sendAudio(_ data: Data) async throws
    func sendFrame(_ jpeg: Data) async throws
    func sendText(_ text: String) async throws
    func sendToolResponse(callId: String, name: String, response: [String: Any]) async throws
    func disconnect()
}

public enum LiveClientError: LocalizedError, Equatable {
    case missingKey, invalidModel, notConnected, setupTimedOut, disconnected
    case invalidAudio, invalidFrame, tooMuchPendingAudio, invalidResponse
    case serverRejected(Int), sessionEnded, connectionFailed

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Gemini APIキーを設定してください。"
        case .invalidModel: return "Gemini Liveのモデル名を確認してください。"
        case .notConnected: return "音声AIは接続されていません。"
        case .setupTimedOut: return "Gemini Liveの接続がタイムアウトしました。"
        case .disconnected: return "音声AIを切断しました。"
        case .invalidAudio: return "音声入力は16kHz・16bit・モノラルPCMで送信してください。"
        case .invalidFrame: return "画面画像が大きすぎるか、JPEGではありません。"
        case .tooMuchPendingAudio: return "音声の送信が追いつかないため接続を停止しました。"
        case .invalidResponse: return "Gemini Liveからの応答を読み取れませんでした。"
        case .serverRejected(let code): return "Gemini Liveが接続を拒否しました（コード \(code)）。キー・モデル・利用枠を確認してください。"
        case .sessionEnded: return "音声AIのセッション期限に達しました。再度呼び出してください。"
        case .connectionFailed: return "Gemini Liveとの通信が切れました。再度呼び出してください。"
        }
    }
}

/// Wire shapes follow https://ai.google.dev/api/live. No API key is placed in a URL.
enum GeminiLiveWire {
    static func request(apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw LiveClientError.missingKey }
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    static func setup(model: String, instructions: String) throws -> Data {
        let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        guard !name.isEmpty, name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }) else {
            throw LiveClientError.invalidModel
        }
        let prototypeTool: [String: Any] = [
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
        return try json(["setup": [
            "model": "models/\(name)",
            "generationConfig": ["responseModalities": ["AUDIO"]],
            "systemInstruction": ["parts": [["text": instructions]]],
            "tools": [["functionDeclarations": [prototypeTool]]],
            "outputAudioTranscription": [:],
            "realtimeInputConfig": ["turnCoverage": "TURN_INCLUDES_ALL_INPUT"],
            "contextWindowCompression": ["slidingWindow": [:]]
        ]])
    }

    static func toolResponse(callId: String, name: String, response: [String: Any]) throws -> Data {
        try json([
            "toolResponse": [
                "functionResponses": [
                    [
                        "response": ["output": response],
                        "id": callId
                    ]
                ]
            ]
        ])
    }

    static func audio(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count % 2 == 0, data.count <= 64_000 else { throw LiveClientError.invalidAudio }
        return try json(["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": data.base64EncodedString()]]])
    }

    static func frame(_ data: Data) throws -> Data {
        guard data.count >= 3, data.count <= 2_000_000, data.starts(with: [0xff, 0xd8, 0xff]) else { throw LiveClientError.invalidFrame }
        return try json(["realtimeInput": ["video": ["mimeType": "image/jpeg", "data": data.base64EncodedString()]]])
    }

    static func text(_ text: String) throws -> Data {
        try json(["realtimeInput": ["text": text]])
    }

    static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    struct Event {
        var setupComplete = false
        var interrupted = false
        var turnComplete = false
        var audio: [(Data, Double)] = []
        var text: [String] = []
        var toolCalls: [(name: String, args: [String: Any], callId: String)] = []
        var error: LiveClientError?
    }

    static func parse(_ data: Data) throws -> Event {
        guard data.count <= 4_194_304,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LiveClientError.invalidResponse }
        var event = Event()
        if let error = object["error"] as? [String: Any] {
            event.error = .serverRejected(error["code"] as? Int ?? 0)
            return event
        }
        if object["goAway"] != nil { event.error = .sessionEnded; return event }
        event.setupComplete = object["setupComplete"] is [String: Any]

        // Handle root-level toolCall
        if let toolCall = object["toolCall"] as? [String: Any],
           let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
            for call in functionCalls {
                if let name = call["name"] as? String, let callId = call["id"] as? String {
                    let args = call["args"] as? [String: Any] ?? [:]
                    event.toolCalls.append((name, args, callId))
                }
            }
        }

        guard let content = object["serverContent"] as? [String: Any] else { return event }
        event.interrupted = content["interrupted"] as? Bool ?? false
        // Extended Thinking can report turnComplete while still working.
        event.turnComplete = (content["turnComplete"] as? Bool ?? false) && (content["interactionStatus"] as? String != "IN_PROGRESS")
        guard !event.interrupted else { return event }
        let transcript = (content["outputTranscription"] as? [String: Any])?["text"] as? String
        if let transcript, !transcript.isEmpty { event.text.append(transcript) }
        let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        for part in parts {
            if part["thought"] as? Bool == true { continue }
            if let functionCall = part["functionCall"] as? [String: Any],
               let name = functionCall["name"] as? String {
                let callId = functionCall["id"] as? String ?? UUID().uuidString
                let args = functionCall["args"] as? [String: Any] ?? [:]
                event.toolCalls.append((name, args, callId))
            }
            if transcript == nil, let text = part["text"] as? String, !text.isEmpty { event.text.append(text) }
            guard let inline = part["inlineData"] as? [String: Any],
                  let mime = inline["mimeType"] as? String, mime.hasPrefix("audio/pcm"),
                  let encoded = inline["data"] as? String,
                  let pcm = Data(base64Encoded: encoded), !pcm.isEmpty, pcm.count % 2 == 0 else { continue }
            let rate = mime.split(separator: ";").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("rate=") })
                .flatMap { Double($0.trimmingCharacters(in: .whitespaces).dropFirst(5)) } ?? 24_000
            guard rate.isFinite, (8_000...96_000).contains(rate) else { throw LiveClientError.invalidResponse }
            event.audio.append((pcm, rate))
        }
        return event
    }
}

@MainActor
protocol LiveSocket: AnyObject {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func cancel()
}

@MainActor
final class URLSessionLiveSocket: LiveSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4_194_304
        task.resume()
    }

    func send(_ data: Data) async throws {
        guard let string = String(data: data, encoding: .utf8) else { throw LiveClientError.invalidResponse }
        try await task.send(.string(string))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw LiveClientError.invalidResponse
        }
    }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

@MainActor
public final class GeminiLiveClient: LiveConversationProvider {
    public static let defaultModel = "gemini-3.8-live"
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
    private var lastFrameAt: TimeInterval = -.infinity

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
        let request = try GeminiLiveWire.request(apiKey: apiKey)
        let setup = try GeminiLiveWire.setup(model: model, instructions: instructions)
        let id = UUID()
        connectionID = id
        let newSocket = socketFactory(request)
        socket = newSocket
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let data = try await newSocket.receive()
                    guard let self, self.connectionID == id else { return }
                    self.consume(try GeminiLiveWire.parse(data))
                }
            } catch {
                guard let self, self.connectionID == id else { return }
                self.fail(error as? LiveClientError ?? .connectionFailed)
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
                        do { try await newSocket.send(setup) }
                        catch {
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

    public func sendAudio(_ data: Data) async throws { try await send(GeminiLiveWire.audio(data)) }

    public func sendFrame(_ jpeg: Data) async throws {
        guard isConnected else { throw LiveClientError.notConnected }
        // Latest live frame only: never queue or replay old screenshots.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrameAt >= 1 else { return }
        let message = try GeminiLiveWire.frame(jpeg)
        lastFrameAt = now
        try await send(message)
    }

    public func sendText(_ text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try await send(GeminiLiveWire.text(text))
    }

    public func sendToolResponse(callId: String, name: String, response: [String: Any]) async throws {
        try await send(GeminiLiveWire.toolResponse(callId: callId, name: name, response: response))
    }

    public func disconnect() {
        connectionID = UUID()
        isConnected = false
        timeoutTask?.cancel(); timeoutTask = nil
        receiveTask?.cancel(); receiveTask = nil
        socket?.cancel(); socket = nil
        setupWaiter?.resume(throwing: LiveClientError.disconnected); setupWaiter = nil
        pendingSends = 0
        lastFrameAt = -.infinity
    }

    private func send(_ data: Data) async throws {
        guard isConnected, let socket else { throw LiveClientError.notConnected }
        guard pendingSends < 8 else { fail(.tooMuchPendingAudio); throw LiveClientError.tooMuchPendingAudio }
        let id = connectionID
        pendingSends += 1
        defer { if connectionID == id { pendingSends -= 1 } }
        do {
            try await socket.send(data)
            guard connectionID == id else { throw LiveClientError.disconnected }
        } catch {
            if connectionID == id { fail(.connectionFailed) }
            throw error as? LiveClientError ?? LiveClientError.connectionFailed
        }
    }

    private func consume(_ event: GeminiLiveWire.Event) {
        if let error = event.error { fail(error); return }
        if event.setupComplete {
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

    private func fail(_ error: LiveClientError) {
        setupWaiter?.resume(throwing: error); setupWaiter = nil
        disconnect()
        onInterrupted?()
        onError?(error.localizedDescription)
    }
}
