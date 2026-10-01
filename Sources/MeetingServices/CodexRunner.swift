import Foundation

@MainActor
public protocol CodexRunning: AnyObject {
    var onOutput: ((String) -> Void)? { get set }
    var onComplete: ((Int32) -> Void)? { get set }
    var isRunning: Bool { get }
    func run(prompt: String, directory: URL, executable: URL, timeoutSeconds: Int) throws
    func cancel()
}

@MainActor
public final class CodexRunner: CodexRunning {
    public var onOutput: ((String) -> Void)?
    public var onComplete: ((Int32) -> Void)?
    public private(set) var isRunning = false
    private var process: Process?
    private var outputPipe: Pipe?
    private var timeoutTask: Task<Void, Never>?
    private var generation = UUID()
    public init() {}

    public func run(prompt: String, directory: URL, executable: URL, timeoutSeconds: Int = 300) throws {
        guard !isRunning else { throw NSError(domain: "Codex", code: 1, userInfo: [NSLocalizedDescriptionKey: "制作が実行中です。"] ) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let p = Process(), input = Pipe(), output = Pipe(), token = UUID()
        p.executableURL = executable
        p.arguments = ["exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "--json", "--color", "never", "-c", "approval_policy=\"never\"", "-C", directory.path, "-"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY", "TYPESAFE_API_KEY", "OPENAI_API_KEY"] { environment.removeValue(forKey: key) }
        let usual = ["/usr/local/bin", "/opt/homebrew/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin").path]
        environment["PATH"] = usual.joined(separator: ":") + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        p.environment = environment; p.currentDirectoryURL = directory
        p.standardInput = input; p.standardOutput = output; p.standardError = output
        generation = token
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in guard self?.generation == token else { return }; self?.onOutput?(text) }
        }
        p.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.timeoutTask?.cancel(); self.timeoutTask = nil
                self.isRunning = false; self.process = nil; self.outputPipe = nil
                self.onComplete?(process.terminationStatus)
            }
        }
        do { try p.run() } catch { output.fileHandleForReading.readabilityHandler = nil; throw error }
        process = p; outputPipe = output; isRunning = true
        input.fileHandleForWriting.write(Data(prompt.utf8)); try? input.fileHandleForWriting.close()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(10, timeoutSeconds)) * 1_000_000_000)
            guard !Task.isCancelled, self?.generation == token else { return }
            self?.onOutput?("\n制作時間の上限に達したため停止します。\n"); self?.cancel()
        }
    }

    public func cancel() {
        timeoutTask?.cancel(); timeoutTask = nil
        guard let process, process.isRunning else { return }
        process.interrupt()
        let token = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.generation == token, let p = self.process, p.isRunning else { return }
            p.terminate()
        }
    }
}
