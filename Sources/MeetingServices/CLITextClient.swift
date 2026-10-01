import Foundation
import Darwin
import MeetingCore

public struct CLIFailureDiagnostics: Equatable, Sendable {
    public let exitCode: Int32
    public let executablePath: String
    public let arguments: [String]
    public let model: String?
    public let enableSearch: Bool?
    public let sanitizedStderrTail: String
    public let summary: String

    public init(
        exitCode: Int32,
        executablePath: String,
        arguments: [String] = [],
        model: String? = nil,
        enableSearch: Bool? = nil,
        sanitizedStderrTail: String,
        summary: String
    ) {
        self.exitCode = exitCode
        self.executablePath = executablePath
        self.arguments = arguments
        self.model = model
        self.enableSearch = enableSearch
        self.sanitizedStderrTail = sanitizedStderrTail
        self.summary = summary
    }

    public var formattedDescription: String {
        var lines: [String] = []
        lines.append(summary)
        var meta: [String] = []
        meta.append("exit: \(exitCode)")
        meta.append("path: \(executablePath)")
        if let model, !model.isEmpty { meta.append("model: \(model)") }
        if let enableSearch { meta.append("search: \(enableSearch)") }
        lines.append("[\(meta.joined(separator: ", "))]")
        if !sanitizedStderrTail.isEmpty {
            lines.append("stderr: \(sanitizedStderrTail)")
        }
        return lines.joined(separator: "\n")
    }
}

public enum CLIError: LocalizedError, Equatable {
    case commandNotFound(String)
    case executionFailed(Int32, String, CLIFailureDiagnostics?)
    case emptyOutput
    case timeout
    case outputTooLarge

    public static func executionFailed(_ code: Int32, _ msg: String) -> CLIError {
        .executionFailed(code, msg, nil)
    }

    public var errorDescription: String? {
        switch self {
        case .commandNotFound(let path):
            return "CLIコマンドが見つかりません: \(path)。パスを確認してください。"
        case .executionFailed(let code, let msg, let diagnostics):
            if let diagnostics {
                return "CLIの実行に失敗しました (終了コード \(code)): \(diagnostics.formattedDescription)"
            }
            return "CLIの実行に失敗しました (終了コード \(code)): \(msg)"
        case .emptyOutput:
            return "CLIからの応答が空でした。"
        case .timeout:
            return "CLIの実行がタイムアウトしました。"
        case .outputTooLarge:
            return "CLIの応答が大きすぎるため処理を停止しました。"
        }
    }

    public var diagnostics: CLIFailureDiagnostics? {
        if case .executionFailed(_, _, let diag) = self {
            return diag
        }
        return nil
    }
}

public final class CLITextClient: Sendable {
    public let defaultTimeoutSeconds: TimeInterval

    public init(defaultTimeoutSeconds: TimeInterval = 60) {
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
    }

    /// Codex CLI (`codex exec -s read-only --ephemeral -o <tmp> <prompt>`) を使って推論
    public func runCodex(
        prompt: String,
        executablePath: String,
        model: String? = nil,
        reasoningEffort: String? = nil,
        enableSearch: Bool = false,
        timeoutSeconds: TimeInterval? = nil,
        workingDirectory: String? = nil,
        skipGitRepoCheck: Bool = false
    ) async throws -> String {
        let path = executablePath.isEmpty ? resolveExecutable("codex") : executablePath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CLIError.commandNotFound(path)
        }

        let tmpOut = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: tmpOut) }

        let arguments = CLITextClient.buildCodexArguments(
            prompt: prompt,
            outputFilePath: tmpOut.path,
            model: model,
            reasoningEffort: reasoningEffort,
            enableSearch: enableSearch,
            workingDirectory: workingDirectory,
            skipGitRepoCheck: skipGitRepoCheck
        )

        let result = try await runProcess(
            executablePath: path,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds ?? defaultTimeoutSeconds,
            workingDirectory: workingDirectory
        )

        guard result.exitCode == 0 else {
            throw failure(
                for: result,
                executablePath: path,
                arguments: arguments,
                model: model,
                enableSearch: enableSearch
            )
        }
        guard let handle = try? FileHandle(forReadingFrom: tmpOut) else { throw CLIError.emptyOutput }
        defer { try? handle.close() }
        let limit = 4 * 1024 * 1024
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw CLIError.outputTooLarge }
        return try validatedOutput(String(decoding: bytes, as: UTF8.self))
    }

    /// Codex CLI実行引数の組み立て（ユニットテストおよびセキュリティ検証用）
    public static func buildCodexArguments(
        prompt: String,
        outputFilePath: String,
        model: String? = nil,
        reasoningEffort: String? = nil,
        enableSearch: Bool = false,
        workingDirectory: String? = nil,
        skipGitRepoCheck: Bool = false
    ) -> [String] {
        var arguments: [String] = []
        if enableSearch {
            arguments.append("--search")
        } else {
            arguments.append(contentsOf: ["-c", "web_search=\"disabled\""])
        }
        arguments.append(contentsOf: ["exec", "-s", "read-only", "--ephemeral"])
        if skipGitRepoCheck {
            arguments.append("--skip-git-repo-check")
        }
        if let workDir = workingDirectory, !workDir.isEmpty {
            arguments.append(contentsOf: ["-C", workDir])
        }
        if let model = model, !model.isEmpty {
            arguments.append(contentsOf: ["-m", model])
        }
        if let reasoningEffort = reasoningEffort, !reasoningEffort.isEmpty {
            arguments.append(contentsOf: ["-c", "model_reasoning_effort=\"\(reasoningEffort)\""])
        }
        arguments.append(contentsOf: ["-o", outputFilePath, prompt])
        return arguments
    }

    /// Antigravity CLI (`agy -p <prompt>`) を使って推論
    public func runAgy(prompt: String, executablePath: String, timeoutSeconds: TimeInterval? = nil) async throws -> String {
        let path = executablePath.isEmpty ? resolveExecutable("agy") : executablePath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CLIError.commandNotFound(path)
        }

        return try await runCLIStdout(
            executablePath: path,
            arguments: ["-p", prompt],
            timeoutSeconds: timeoutSeconds ?? defaultTimeoutSeconds
        )
    }

    /// Grok CLI (`grok -p <prompt>`) を使って推論
    public func runGrok(prompt: String, executablePath: String, timeoutSeconds: TimeInterval? = nil) async throws -> String {
        let path = executablePath.isEmpty ? resolveExecutable("grok") : executablePath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CLIError.commandNotFound(path)
        }

        return try await runCLIStdout(
            executablePath: path,
            arguments: ["-p", prompt],
            timeoutSeconds: timeoutSeconds ?? defaultTimeoutSeconds
        )
    }

    private func runCLIStdout(executablePath: String, arguments: [String], timeoutSeconds: TimeInterval) async throws -> String {
        let result = try await runProcess(
            executablePath: executablePath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        )

        guard result.exitCode == 0 else {
            throw failure(for: result, executablePath: executablePath, arguments: arguments)
        }
        return try validatedOutput(result.stdout)
    }

    private func validatedOutput(_ value: String) throws -> String {
        let output = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw CLIError.emptyOutput }
        guard !CLIOutputDiagnostics.isAuthenticationFailure(output) else {
            throw CLIError.executionFailed(0, "認証またはログイン状態を確認してください。")
        }
        return output
    }

    private func failure(
        for result: (stdout: String, stderr: String, exitCode: Int32),
        executablePath: String,
        arguments: [String] = [],
        model: String? = nil,
        enableSearch: Bool? = nil
    ) -> CLIError {
        // Child output may contain credentials or private prompt content; never copy it to an alert.
        let authentication = CLIOutputDiagnostics.isAuthenticationFailure(result.stderr)
            || CLIOutputDiagnostics.isAuthenticationFailure(result.stdout)
        let summary = authentication
            ? "認証またはログイン状態を確認してください。"
            : "CLIの設定と実行権限を確認してください。"
        let rawStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = rawStderr.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : rawStderr
        let sanitizedTail = CLIOutputDiagnostics.sanitize(fallback, maxBytes: 3072)
        let diagnostics = CLIFailureDiagnostics(
            exitCode: result.exitCode,
            executablePath: executablePath,
            arguments: arguments,
            model: model,
            enableSearch: enableSearch,
            sanitizedStderrTail: sanitizedTail,
            summary: summary
        )
        return .executionFailed(result.exitCode, summary, diagnostics)
    }

    /// Both pipes are drained incrementally. Stderr is bounded; oversized stdout fails rather
    /// than returning a truncated answer. Timeout and cancellation also cover inherited pipes.
    public func runProcess(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        maxOutputBytes: Int = 4 * 1024 * 1024,
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try Task.checkCancellation()
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { throw CLIError.timeout }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw CLIError.commandNotFound(executablePath)
        }
        let execution = CLIProcessExecution(executablePath: executablePath, arguments: arguments,
                                            timeout: timeoutSeconds, byteLimit: max(0, maxOutputBytes),
                                            environment: environment, workingDirectory: workingDirectory)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    public func resolveExecutable(_ name: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [String]
        switch name {
        case "codex":
            candidates = [
                "\(home)/.npm-global/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]
        case "agy":
            candidates = [
                "\(home)/.local/bin/agy",
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy"
            ]
        case "grok":
            candidates = [
                "\(home)/.grok/bin/grok",
                "/opt/homebrew/bin/grok",
                "/usr/local/bin/grok"
            ]
        default:
            candidates = ["/usr/local/bin/\(name)"]
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/\(name)"
    }
}

/// CLIプロセスの環境変数管理ユーティリティ（GUI環境等でのPATH不足防止）
public enum CLIEnvironment: Sendable {
    public static let minimumRequiredPaths: [String] = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    /// ユーザーの既存PATHを順序通り維持しつつ、不足している標準binおよびユーザーbinを重複なしで追加
    public static func augmentedPath(currentPath: String?, homeDirectory: String? = nil) -> String {
        let raw = currentPath ?? ""
        let existing = raw.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        var result: [String] = []

        // 1. ユーザー既存のPATHを最優先で維持（重複排除）
        for path in existing {
            if seen.insert(path).inserted {
                result.append(path)
            }
        }

        // 2. ユーザーbinディレクトリ候補（存在しうるもの）
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if !home.isEmpty {
            candidates.append("\(home)/.npm-global/bin")
            candidates.append("\(home)/.local/bin")
            candidates.append("\(home)/.grok/bin")
        }

        // 3. システム最低限必須パス
        candidates.append(contentsOf: minimumRequiredPaths)

        for path in candidates {
            if seen.insert(path).inserted {
                result.append(path)
            }
        }

        return result.joined(separator: ":")
    }

    /// 子プロセス用の実行環境変数マップを構築
    public static func makeProcessEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["PATH"] = augmentedPath(currentPath: base["PATH"])
        env["PAGER"] = "cat"
        return env
    }
}

/// Every mutable property is confined to `queue`, including cancellation before launch.
private final class CLIProcessExecution: @unchecked Sendable {
    typealias Output = (stdout: String, stderr: String, exitCode: Int32)
    private let queue = DispatchQueue(label: "MeetingSidekick.CLIProcess", qos: .userInitiated)
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let timeout: TimeInterval
    private let byteLimit: Int
    private var continuation: CheckedContinuation<Output, Error>?
    private var readers: [DispatchSourceRead] = []
    private var timer: DispatchSourceTimer?
    private var bytes = [Data(), Data()]
    private var ended = [false, false]
    private var exitCode: Int32?
    private var terminalError: Error?
    private var cancelled = false
    private var completed = false
    private var ownProcessGroup: pid_t?

    init(executablePath: String, arguments: [String], timeout: TimeInterval, byteLimit: Int, environment: [String: String]? = nil, workingDirectory: String? = nil) {
        self.timeout = timeout
        self.byteLimit = byteLimit
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = CLIEnvironment.makeProcessEnvironment(base: environment ?? ProcessInfo.processInfo.environment)
        if let workDir = workingDirectory, !workDir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }
    }

    func start(_ continuation: CheckedContinuation<Output, Error>) {
        queue.async {
            self.continuation = continuation
            guard !self.cancelled else { self.finish(error: CancellationError()); return }
            self.installReader(self.outputPipe.fileHandleForReading, index: 0)
            self.installReader(self.errorPipe.fileHandleForReading, index: 1)
            self.process.terminationHandler = { [weak self] process in
                let code = process.terminationStatus
                self?.queue.async { [weak self] in
                    guard let self, !self.completed else { return }
                    self.exitCode = code
                    self.finishIfReady()
                }
            }
            do {
                try self.process.run()
                let pid = self.process.processIdentifier
                // Never signal the application's process group. Foundation may create one
                // for this child; only that isolated group is eligible for group termination.
                if getpgid(pid) == pid { self.ownProcessGroup = pid }
                try? self.outputPipe.fileHandleForWriting.close()
                try? self.errorPipe.fileHandleForWriting.close()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + min(self.timeout, 86_400))
                timer.setEventHandler { [weak self] in self?.abort(CLIError.timeout) }
                self.timer = timer
                timer.resume()
            } catch {
                self.finish(error: CLIError.executionFailed(-1, "CLIを起動できません。実行ファイルと権限を確認してください。"))
            }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            guard self.continuation != nil else { return }
            self.abort(CancellationError())
        }
    }

    private func installReader(_ handle: FileHandle, index: Int) {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(descriptor, index: index) }
        source.setCancelHandler { try? handle.close() }
        readers.append(source)
        source.resume()
    }

    private func drain(_ descriptor: Int32, index: Int) {
        guard !completed, !ended[index] else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Yield regularly so a continuous producer cannot starve timeout/cancellation.
        for _ in 0..<64 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let remaining = max(0, byteLimit - bytes[index].count)
                bytes[index].append(contentsOf: buffer.prefix(min(remaining, count)))
                if index == 0, count > remaining { abort(CLIError.outputTooLarge) }
            } else if count == 0 {
                ended[index] = true
                readers[index].cancel()
                finishIfReady()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                abort(CLIError.executionFailed(-1, "CLIの出力を読み取れませんでした。"))
                return
            }
        }
    }

    private func abort(_ error: Error) {
        guard !completed, terminalError == nil else { return }
        terminalError = error
        signalChild(SIGTERM)
        queue.asyncAfter(deadline: .now() + 0.3) {
            guard !self.completed else { return }
            self.signalChild(SIGKILL)
            // An inherited pipe must never make cancellation wait indefinitely.
            self.queue.asyncAfter(deadline: .now() + 0.1) {
                guard !self.completed else { return }
                self.finish(error: self.terminalError)
            }
        }
        finishIfReady()
    }

    private func signalChild(_ signal: Int32) {
        if let group = ownProcessGroup { _ = Darwin.kill(-group, signal) }
        else if process.isRunning { _ = Darwin.kill(process.processIdentifier, signal) }
    }

    private func finishIfReady() {
        guard exitCode != nil, ended.allSatisfy({ $0 }) else { return }
        finish(error: terminalError)
    }

    private func finish(error: Error?) {
        guard !completed, let continuation else { return }
        completed = true
        self.continuation = nil
        timer?.cancel()
        timer = nil
        readers.forEach { $0.cancel() }
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        if readers.isEmpty {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
        }
        process.terminationHandler = nil
        if let error { continuation.resume(throwing: error) }
        else {
            continuation.resume(returning: (String(decoding: bytes[0], as: UTF8.self),
                                             String(decoding: bytes[1], as: UTF8.self), exitCode ?? -1))
        }
    }
}

public enum CLIOutputDiagnostics {
    public static func isAuthenticationFailure(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = clean.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Content mentioning authentication inside a valid answer is not a login failure.
            return object["error"] != nil || object["status"] as? String == "error"
        }
        let lines = clean.lowercased().components(separatedBy: .newlines).prefix(5)
        return lines.contains { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["authentication required", "authentication failed", "please login", "please log in", "login required", "not logged in", "not authenticated", "unauthorized", "permission denied", "認証エラー", "認証に失敗", "ログインしてください"].contains(where: value.hasPrefix)
                || (value.hasPrefix("error") && ["auth", "login", "log in", "api key", "401", "403"].contains(where: value.contains))
        }
    }

    /// APIキー、トークン、秘密情報をマスクし、stderr末尾 (2〜4KB) を安全に抽出
    public static func sanitize(_ text: String, maxBytes: Int = 3072) -> String {
        guard !text.isEmpty else { return "" }

        var sanitized = text

        // 1. APIキー・トークン・クレデンシャルパターンのマスキング
        let tokenRegexes: [(String, String)] = [
            (#"(sk-[A-Za-z0-9_\-]{6})[A-Za-z0-9_\-]+"#, "$1...[REDACTED]"),
            (#"(AIza[A-Za-z0-9_\-]{6})[A-Za-z0-9_\-]+"#, "$1...[REDACTED]"),
            (#"(ts-[A-Za-z0-9_\-]{6})[A-Za-z0-9_\-]+"#, "$1...[REDACTED]"),
            (#"(gh[pousr]-[A-Za-z0-9_]{6})[A-Za-z0-9_]+"#, "$1...[REDACTED]"),
            (#"(Bearer\s+)[A-Za-z0-9_\-\.\~]{8,}"#, "$1[REDACTED]"),
            (#"((?:api[_-]?key|token|secret|password|auth|authorization)\s*[:=]\s*["']?)[A-Za-z0-9_\-\.\~]{8,}["']?"#, "$1[REDACTED]"),
            (#"(--(?:api-key|token|secret)\s+)[^\s]+"#, "$1[REDACTED]")
        ]

        for (pattern, template) in tokenRegexes {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: (sanitized as NSString).length)
                sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: template)
            }
        }

        // 2. 末尾 2〜4KB (maxBytes) を安全に抽出
        let utf8 = sanitized.utf8
        if utf8.count > maxBytes {
            let excess = utf8.count - maxBytes
            let index = sanitized.utf8.index(sanitized.utf8.startIndex, offsetBy: excess)
            let tail = String(sanitized.utf8[index...]) ?? String(sanitized.suffix(maxBytes))
            return "... (先頭省略)\n" + tail.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
