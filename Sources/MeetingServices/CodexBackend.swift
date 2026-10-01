import Foundation
import Darwin
import MeetingCore

/// Codex へのリクエストパラメータ
public struct CodexRequest: Sendable {
    public var prompt: String
    public var model: String?
    public var reasoningEffort: String?
    public var enableSearch: Bool
    public var timeoutSeconds: TimeInterval?
    public var workingDirectory: String?
    public var skipGitRepoCheck: Bool

    public init(
        prompt: String,
        model: String? = nil,
        reasoningEffort: String? = nil,
        enableSearch: Bool = false,
        timeoutSeconds: TimeInterval? = nil,
        workingDirectory: String? = nil,
        skipGitRepoCheck: Bool = false
    ) {
        self.prompt = prompt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.enableSearch = enableSearch
        self.timeoutSeconds = timeoutSeconds
        self.workingDirectory = workingDirectory
        self.skipGitRepoCheck = skipGitRepoCheck
    }
}

/// Codex 実行結果
public struct CodexGenerationResult: Sendable, Equatable {
    public var text: String
    public var backend: String // "app-server" | "exec"
    public var requestedModel: String
    public var resolvedModel: String
    public var reasoningEffort: String
    public var webSearchMode: String // "live" | "disabled"
    public var webSearchRequested: Bool
    public var webSearchUsed: Bool?
    public var webSearchSources: [String]

    public init(
        text: String,
        backend: String,
        requestedModel: String,
        resolvedModel: String,
        reasoningEffort: String,
        webSearchMode: String,
        webSearchRequested: Bool = false,
        webSearchUsed: Bool? = nil,
        webSearchSources: [String] = []
    ) {
        self.text = text
        self.backend = backend
        self.requestedModel = requestedModel
        self.resolvedModel = resolvedModel
        self.reasoningEffort = reasoningEffort
        self.webSearchMode = webSearchMode
        self.webSearchRequested = webSearchRequested
        self.webSearchUsed = webSearchUsed
        self.webSearchSources = webSearchSources
    }
}

/// Codex 推論を実行するバックエンドの共通プロトコル
public protocol CodexBackend: Sendable {
    func generate(_ request: CodexRequest) async throws -> CodexGenerationResult
    func terminate() async
    func terminate(targetGeneration: Int?) async
}

public extension CodexBackend {
    func terminate() async {}
    func terminate(targetGeneration: Int?) async {
        await terminate()
    }
}

/// Codex CLI (`codex exec -s read-only --ephemeral ...`) による1回限りのプロセス実行バックエンド
public final class CodexExecBackend: CodexBackend, Sendable {
    public let client: CLITextClient
    public let executablePath: String

    public init(client: CLITextClient = CLITextClient(), executablePath: String = "") {
        self.client = client
        self.executablePath = executablePath
    }

    public func generate(_ request: CodexRequest) async throws -> CodexGenerationResult {
        let requested = request.model ?? "gpt-6-sol"
        let effort = request.reasoningEffort ?? "low"
        let text = try await client.runCodex(
            prompt: request.prompt,
            executablePath: executablePath,
            model: requested,
            reasoningEffort: effort,
            enableSearch: request.enableSearch,
            timeoutSeconds: request.timeoutSeconds,
            workingDirectory: request.workingDirectory,
            skipGitRepoCheck: request.skipGitRepoCheck
        )
        let searchMode = request.enableSearch ? "live" : "disabled"
        return CodexGenerationResult(
            text: text,
            backend: "exec",
            requestedModel: requested,
            resolvedModel: requested,
            reasoningEffort: effort,
            webSearchMode: searchMode,
            webSearchRequested: request.enableSearch,
            webSearchUsed: nil, // Exec fallbackでは実使用イベントを観測できないため unknown (nil)
            webSearchSources: []
        )
    }

    public func terminate() async {}
    public func terminate(targetGeneration: Int?) async {}
}

public enum CodexAppServerError: LocalizedError, Equatable {
    case processNotRunning
    case launchFailed(String)
    case streamClosed
    case timeout
    case rpcError(Int, String)
    case turnFailed(String)
    case emptyOutput
    case modelUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "Codex App Serverプロセスが実行されていません。"
        case .launchFailed(let msg):
            return "Codex App Serverの起動に失敗しました: \(msg)"
        case .streamClosed:
            return "Codex App Serverとの通信ストリームが切断されました。"
        case .timeout:
            return "Codex App Serverの応答がタイムアウトしました。"
        case .rpcError(let code, let msg):
            return "Codex App Server JSON-RPCエラー (\(code)): \(msg)"
        case .turnFailed(let msg):
            return "Codex App Serverの思考ターンが失敗しました: \(msg)"
        case .emptyOutput:
            return "Codex App Serverの出力が空でした。"
        case .modelUnavailable(let model):
            return "指定されたモデル '\(model)' は利用できません。Sol系モデルが見つかりませんでした。"
        }
    }
}

/// The queue deadline is part of the caller's budget, not a fresh budget per turn.
public actor AsyncLock {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let timer: Task<Void, Never>?
    }
    private var isLocked = false
    private var waiters: [Waiter] = []
    public init() {}

    public func lock(timeoutSeconds: TimeInterval? = nil) async throws {
        try Task.checkCancellation()
        if let timeoutSeconds, !timeoutSeconds.isFinite || timeoutSeconds <= 0 { throw CodexAppServerError.timeout }
        if !isLocked { isLocked = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let timer = timeoutSeconds.map { seconds in
                    Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: UInt64(min(86_400, max(0, seconds)) * 1_000_000_000)) }
                        catch { return }
                        await self?.removeWaiter(id: id, error: CodexAppServerError.timeout)
                    }
                }
                waiters.append(Waiter(id: id, continuation: continuation, timer: timer))
            }
        } onCancel: {
            Task { await self.removeWaiter(id: id, error: CancellationError()) }
        }
    }
    private func removeWaiter(id: UUID, error: Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timer?.cancel()
        waiter.continuation.resume(throwing: error)
    }
    public func unlock() {
        if waiters.isEmpty { isLocked = false; return }
        let waiter = waiters.removeFirst()
        waiter.timer?.cancel()
        waiter.continuation.resume()
    }
}

/// FileHandle.AsyncBytes can remain blocked after task cancellation. A pipe callback
/// feeds this bounded inbox so timeout/cancel resumes the caller without awaiting a read.
private final class CodexLineInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var bufferedBytes = 0
    private var failure: Error?
    private var waiter: (UUID, CheckedContinuation<String, Error>)?
    private let limit = 4 * 1024 * 1024

    func feed(_ data: Data) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        if data.isEmpty {
            failure = CodexAppServerError.streamClosed
        } else if bufferedBytes + buffer.count + data.count > limit {
            failure = CodexAppServerError.rpcError(-1, "App Server output exceeds 4 MB")
        } else {
            buffer.append(data)
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeSubrange(...end)
                lines.append(line)
                bufferedBytes += line.utf8.count
            }
        }
        let pending = waiter
        let result: Result<String, Error>?
        if pending != nil, !lines.isEmpty {
            let line = lines.removeFirst(); bufferedBytes -= line.utf8.count
            result = .success(line); waiter = nil
        } else if pending != nil, let failure {
            result = .failure(failure); waiter = nil
        } else { result = nil }
        lock.unlock()
        if let pending, let result { pending.1.resume(with: result) }
    }
    func close(_ error: Error = CodexAppServerError.streamClosed) {
        lock.lock()
        failure = error; lines.removeAll(); buffer.removeAll(); bufferedBytes = 0
        let pending = waiter; waiter = nil
        lock.unlock()
        pending?.1.resume(throwing: error)
    }
    private func failWaiter(id: UUID, error: Error) {
        lock.lock()
        let pending = waiter?.0 == id ? waiter : nil
        if pending != nil { waiter = nil }
        lock.unlock()
        pending?.1.resume(throwing: error)
    }
    func next(timeout: TimeInterval) async throws -> String {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { throw CodexAppServerError.timeout }
        let id = UUID()
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(86_400, timeout) * 1_000_000_000)) }
            catch { return }
            self?.failWaiter(id: id, error: CodexAppServerError.timeout)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                let result: Result<String, Error>?
                if Task.isCancelled { result = .failure(CancellationError()) }
                else if Date() >= deadline { result = .failure(CodexAppServerError.timeout) }
                else if !lines.isEmpty {
                    let line = lines.removeFirst(); bufferedBytes -= line.utf8.count
                    result = .success(line)
                } else if let failure { result = .failure(failure) }
                else { waiter = (id, continuation); result = nil }
                lock.unlock()
                if let result { continuation.resume(with: result) }
            }
        } onCancel: { self.failWaiter(id: id, error: CancellationError()) }
    }
}

public actor CodexAppServerProcess {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var errPipe: Pipe?
    private var inbox: CodexLineInbox?
    private var reqId = 0
    private var processEpoch = UUID()
    public private(set) var availableModels: [String] = []
    public private(set) var isRunning = false
    private let turnGate = AsyncLock()
    private var stderrBuffer = Data()
    private let maxStderrBytes = 32 * 1024
    public init() {}

    public func start(executablePath: String) async throws {
        try await start(executablePath: executablePath, deadline: Date().addingTimeInterval(30))
    }
    private func start(executablePath: String, deadline: Date) async throws {
        if isRunning && process?.isRunning == true { return }
        stopProcess()
        let resolved = executablePath.isEmpty ? CLITextClient().resolveExecutable("codex") : executablePath
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            throw CodexAppServerError.launchFailed("実行可能ファイルが見つかりません: \(resolved)")
        }
        let proc = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let newInbox = CodexLineInbox()
        proc.executableURL = URL(fileURLWithPath: resolved)
        proc.arguments = ["app-server", "--stdio"]
        proc.environment = CLIEnvironment.makeProcessEnvironment(base: ProcessInfo.processInfo.environment)
        proc.standardInput = input; proc.standardOutput = output; proc.standardError = errors
        let inputFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        let inputFlags = fcntl(inputFD, F_GETFL)
        guard inputFlags >= 0, fcntl(inputFD, F_SETFL, inputFlags | O_NONBLOCK) == 0 else {
            throw CodexAppServerError.launchFailed("Unable to configure the App Server input pipe")
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            newInbox.feed(bytes)
        }
        let epoch = UUID(); processEpoch = epoch
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            Task { await self?.appendStderr(bytes, epoch: epoch) }
        }
        do { try proc.run() }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
        process = proc; stdinPipe = input; stdoutPipe = output; errPipe = errors
        inbox = newInbox; isRunning = true; reqId = 0; availableModels = []; stderrBuffer = Data()
        do {
            _ = try await sendRequest(method: "initialize", params: [
                "clientInfo": ["name": "MeetingSidekick", "version": "0.1.0"]
            ], deadline: deadline)
            try await sendNotification(method: "initialized", deadline: deadline)
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                var params: [String: Any] = ["limit": 100]
                if let cursor { params["cursor"] = cursor }
                let response = try await sendRequest(method: "model/list", params: params, deadline: deadline)
                if let data = response["data"] as? [[String: Any]] {
                    availableModels += data.compactMap { ($0["model"] as? String) ?? ($0["id"] as? String) }
                }
                cursor = response["nextCursor"] as? String
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw CodexAppServerError.rpcError(-1, "Repeated model/list cursor")
                }
            } while cursor != nil
        } catch {
            if processEpoch == epoch { stopProcess() }
            throw error
        }
    }

    public func stop() async { stopProcess() }
    /// Evaluate the generation guard on this actor immediately before stopping.
    /// A new generation cannot start on this actor between validation and teardown.
    public func stop(if shouldStop: @Sendable () -> Bool) async {
        guard shouldStop() else { return }
        stopProcess()
    }
    private func stopProcess() {
        processEpoch = UUID()
        inbox?.close(); inbox = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        if let proc = process, proc.isRunning {
            proc.terminate()
            // Restrict escalation to this exact owned Process; never use name-based pkill.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if proc.isRunning { _ = kill(proc.processIdentifier, SIGKILL) }
            }
        }
        process = nil; stdinPipe = nil; stdoutPipe = nil; errPipe = nil
        isRunning = false; availableModels = []
    }
    public func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
        if stderrBuffer.count > maxStderrBytes { stderrBuffer.removeFirst(stderrBuffer.count - maxStderrBytes) }
    }
    private func appendStderr(_ data: Data, epoch: UUID) {
        guard processEpoch == epoch else { return }
        appendStderr(data)
    }
    public var currentStderrTail: String { String(decoding: stderrBuffer, as: UTF8.self) }

    public func executeTurn(request: CodexRequest, executablePath: String, defaultWorkingDirectory: String) async throws -> CodexGenerationResult {
        let deadline = Date().addingTimeInterval(request.timeoutSeconds ?? 60)
        try await turnGate.lock(timeoutSeconds: deadline.timeIntervalSinceNow)
        // Only the owner of the gate may tear down a failed/cancelled turn.
        do {
            try Task.checkCancellation()
            let result = try await performTurn(request: request, executablePath: executablePath,
                                               defaultWorkingDirectory: defaultWorkingDirectory, deadline: deadline)
            await turnGate.unlock()
            return result
        } catch {
            stopProcess()
            await turnGate.unlock()
            throw error
        }
    }
    private func performTurn(request: CodexRequest, executablePath: String, defaultWorkingDirectory: String, deadline: Date) async throws -> CodexGenerationResult {
        if !isRunning || process?.isRunning != true { try await start(executablePath: executablePath, deadline: deadline) }
        let epoch = processEpoch
        let requested = request.model ?? "gpt-6-sol"
        let model = try resolveModel(requested: request.model)
        let effort = request.reasoningEffort ?? "low"
        let search = request.enableSearch ? "live" : "disabled"
        let response = try await sendRequest(method: "thread/start", params: [
            "cwd": request.workingDirectory ?? defaultWorkingDirectory,
            "model": model, "sandbox": "read-only", "ephemeral": true, "approvalPolicy": "never",
            "config": ["model_reasoning_effort": effort, "web_search": search]
        ], deadline: deadline)
        guard let thread = response["thread"] as? [String: Any], let threadID = thread["id"] as? String else {
            throw CodexAppServerError.rpcError(-1, "thread/start did not return threadId")
        }
        try Task.checkCancellation()
        guard processEpoch == epoch else { throw CancellationError() }
        let turnRequest = try await sendOnly(method: "turn/start", params: [
            "threadId": threadID, "input": [["type": "text", "text": request.prompt]], "model": model, "effort": effort
        ], deadline: deadline)
        let output = try await waitForTurnCompletion(turnReqId: turnRequest, threadId: threadID, deadline: deadline)
        try Task.checkCancellation()
        guard processEpoch == epoch else { throw CancellationError() }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CodexAppServerError.emptyOutput }
        return CodexGenerationResult(text: text, backend: "app-server", requestedModel: requested,
            resolvedModel: model, reasoningEffort: effort, webSearchMode: search,
            webSearchRequested: request.enableSearch, webSearchUsed: output.webSearchUsed, webSearchSources: output.webSearchSources)
    }
    public func resolveModel(requested: String?) throws -> String {
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requested = trimmed.isEmpty ? "gpt-6-sol" : trimmed
        if availableModels.isEmpty || availableModels.contains(requested) { return requested }
        if requested == "gpt-6-sol" || requested == "gpt-5.6-sol" {
            for model in ["gpt-5.6-sol", "gpt-6-sol"] where availableModels.contains(model) { return model }
        }
        throw CodexAppServerError.modelUnavailable(requested)
    }
    public func setAvailableModelsForTesting(_ models: [String]) { availableModels = models }
    private func write(_ payload: [String: Any], deadline: Date) async throws {
        try Task.checkCancellation()
        guard process?.isRunning == true, let handle = stdinPipe?.fileHandleForWriting else {
            throw CodexAppServerError.processNotRunning
        }
        let epoch = processEpoch, descriptor = handle.fileDescriptor
        var data = try JSONSerialization.data(withJSONObject: payload); data.append(0x0A)
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard processEpoch == epoch else { throw CancellationError() }
            guard deadline.timeIntervalSinceNow > 0 else { throw CodexAppServerError.timeout }
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 { offset += written; continue }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                // Yield the actor so stop/cancel can close a child that stopped reading.
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            throw CodexAppServerError.streamClosed
        }
    }
    private func sendNotification(method: String, deadline: Date) async throws {
        try await write(["jsonrpc": "2.0", "method": method], deadline: deadline)
    }
    private func sendOnly(method: String, params: [String: Any], deadline: Date) async throws -> Int {
        reqId += 1
        let id = reqId
        try await write(["jsonrpc": "2.0", "id": id, "method": method, "params": params], deadline: deadline)
        return id
    }
    private func nextJSON(deadline: Date) async throws -> [String: Any] {
        while true {
            try Task.checkCancellation()
            guard let inbox else { throw CodexAppServerError.processNotRunning }
            let line = try await inbox.next(timeout: deadline.timeIntervalSinceNow)
            if let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { return json }
        }
    }
    private func sendRequest(method: String, params: [String: Any], deadline: Date) async throws -> [String: Any] {
        guard deadline.timeIntervalSinceNow > 0 else { throw CodexAppServerError.timeout }
        let id = try await sendOnly(method: method, params: params, deadline: deadline)
        while true {
            let json = try await nextJSON(deadline: deadline)
            if json["id"] as? Int == id {
                try checkRPCError(json)
                return json["result"] as? [String: Any] ?? [:]
            }
        }
    }
    private func checkRPCError(_ json: [String: Any]) throws {
        if let error = json["error"] as? [String: Any] {
            throw CodexAppServerError.rpcError(error["code"] as? Int ?? -1, error["message"] as? String ?? "不明なエラー")
        }
    }
    private struct TurnCompletionOutput {
        let text: String
        let webSearchUsed: Bool?
        let webSearchSources: [String]
    }
    private func collectSearchURLs(_ value: Any?, into urls: inout [String], depth: Int = 0) {
        guard depth < 8, urls.count < 100 else { return }
        if let object = value as? [String: Any] {
            if let url = object["url"] as? String, ResearchSource.isValidWebURL(url), !urls.contains(url) { urls.append(url) }
            for nested in object.values { collectSearchURLs(nested, into: &urls, depth: depth + 1) }
        } else if let array = value as? [Any] {
            for nested in array { collectSearchURLs(nested, into: &urls, depth: depth + 1) }
        }
    }
    private func waitForTurnCompletion(turnReqId: Int, threadId: String, deadline: Date) async throws -> TurnCompletionOutput {
        var turnID: String?
        var observedItems: [(turnID: String?, item: [String: Any])] = []
        while true {
            let json = try await nextJSON(deadline: deadline)
            if json["id"] as? Int == turnReqId {
                try checkRPCError(json)
                turnID = ((json["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String
                continue
            }
            guard let method = json["method"] as? String, let params = json["params"] as? [String: Any],
                  params["threadId"] as? String == threadId else { continue }
            if method == "item/started" || method == "item/completed" {
                // Older hosts omit turnId; each request owns a new ephemeral thread.
                if let eventTurn = params["turnId"] as? String, let turnID, eventTurn != turnID { continue }
                if let item = params["item"] as? [String: Any],
                   method == "item/completed" || item["type"] as? String == "webSearch" {
                    observedItems.append((params["turnId"] as? String, item))
                }
                continue
            }
            guard method == "turn/completed", let turn = params["turn"] as? [String: Any] else { continue }
            if let turnID, turn["id"] as? String != turnID { continue }
            let status = turn["status"] as? String ?? ""
            if status == "interrupted" { throw CancellationError() }
            guard status == "completed" else {
                let error = turn["error"] as? [String: Any]
                throw CodexAppServerError.turnFailed(error?["message"] as? String ?? status)
            }
            let finalItems = turn["items"] as? [[String: Any]]
            let matchingItems = observedItems.filter { $0.turnID == nil || $0.turnID == turn["id"] as? String }.map(\.item)
            let allItems = matchingItems + (finalItems ?? [])
            let searched = allItems.contains { $0["type"] as? String == "webSearch" }
            var urls: [String] = []
            for item in allItems where item["type"] as? String == "webSearch" {
                // URLs are taken only from structured host tool results, never from model prose.
                collectSearchURLs(item["results"], into: &urls)
            }
            let completedMessages = finalItems?.filter { $0["type"] as? String == "agentMessage" } ?? []
            let messages = (completedMessages.isEmpty ? matchingItems : completedMessages).filter {
                $0["type"] as? String == "agentMessage" && ($0["phase"] as? String != "commentary")
            }.compactMap { $0["text"] as? String }
            var uniqueMessages: [String] = []
            for text in messages where !uniqueMessages.contains(text) { uniqueMessages.append(text) }
            return TurnCompletionOutput(text: uniqueMessages.joined(separator: "\n"),
                webSearchUsed: searched ? true : (finalItems != nil ? false : nil), webSearchSources: urls)
        }
    }
}

/// Serializes retries as well as turns, so one failed caller never kills another's turn.
public final class CodexAppServerBackend: CodexBackend, @unchecked Sendable {
    public let executablePath: String
    public let defaultWorkingDirectory: String
    public let fallbackBackend: (any CodexBackend)?
    private let appProcess = CodexAppServerProcess()
    private let gate = AsyncLock()
    private let stateLock = NSLock()
    private var generation = 0
    private var invalidatedThrough = 0
    private var activeTicket: Int?
    private var usedBackend = "app-server"
    public var lastUsedBackend: String { stateLock.withLock { usedBackend } }
    public var currentGeneration: Int { stateLock.withLock { generation } }
    public var availableModels: [String] { get async { await appProcess.availableModels } }
    public init(executablePath: String = "", defaultWorkingDirectory: String = AppPaths.project.path, fallbackBackend: (any CodexBackend)? = nil) {
        self.executablePath = executablePath; self.defaultWorkingDirectory = defaultWorkingDirectory; self.fallbackBackend = fallbackBackend
    }
    private func checkActive(_ ticket: Int) throws {
        try Task.checkCancellation()
        guard stateLock.withLock({ ticket > invalidatedThrough }) else { throw CancellationError() }
    }
    public func generate(_ request: CodexRequest) async throws -> CodexGenerationResult {
        let ticket = stateLock.withLock { generation += 1; return generation }
        let deadline = Date().addingTimeInterval(request.timeoutSeconds ?? 60)
        try await gate.lock(timeoutSeconds: deadline.timeIntervalSinceNow)
        stateLock.withLock { activeTicket = ticket }
        do {
            let result = try await generateLocked(request, ticket: ticket, deadline: deadline)
            stateLock.withLock { activeTicket = nil }
            await gate.unlock()
            return result
        } catch {
            stateLock.withLock { activeTicket = nil }
            await gate.unlock()
            throw error
        }
    }
    private func generateLocked(_ request: CodexRequest, ticket: Int, deadline: Date) async throws -> CodexGenerationResult {
        var lastError: Error = CodexAppServerError.processNotRunning
        for attempt in 0..<2 {
            try checkActive(ticket)
            var bounded = request; bounded.timeoutSeconds = deadline.timeIntervalSinceNow
            guard bounded.timeoutSeconds! > 0 else { throw CodexAppServerError.timeout }
            do {
                let result = try await appProcess.executeTurn(request: bounded, executablePath: executablePath, defaultWorkingDirectory: defaultWorkingDirectory)
                try checkActive(ticket)
                stateLock.withLock { usedBackend = "app-server" }
                return result
            } catch {
                try checkActive(ticket)
                if error is CancellationError { throw error }
                lastError = error
                // Semantic failures, policy errors, and exhausted budgets must not silently
                // launch a second paid run or escape model selection via exec.
                guard let serverError = error as? CodexAppServerError else { throw error }
                switch serverError {
                case .launchFailed, .processNotRunning, .streamClosed:
                    if attempt == 0 { continue }
                default: throw error
                }
            }
        }
        guard let fallbackBackend else { throw lastError }
        try checkActive(ticket)
        var bounded = request; bounded.timeoutSeconds = deadline.timeIntervalSinceNow
        guard bounded.timeoutSeconds! > 0 else { throw CodexAppServerError.timeout }
        let result = try await fallbackBackend.generate(bounded)
        try checkActive(ticket)
        stateLock.withLock { usedBackend = "exec" }
        return result
    }
    public func terminate() async { await terminate(targetGeneration: currentGeneration) }
    public func terminate(targetGeneration: Int?) async {
        let target = targetGeneration ?? currentGeneration
        stateLock.withLock { invalidatedThrough = max(invalidatedThrough, target) }
        await appProcess.stop { [self] in
            stateLock.withLock { (activeTicket ?? generation) <= target }
        }
        // Do not forward a stale termination to a newly executing fallback either.
        if stateLock.withLock({ (activeTicket ?? generation) <= target }), let fallbackBackend {
            await fallbackBackend.terminate(targetGeneration: target)
        }
    }
}
