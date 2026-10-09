import AppKit
import Combine
import MeetingCore
import MeetingServices

@MainActor
final class AppModel: ObservableObject {
    let runtime: MeetingRuntime
    let capture = CaptureService()
    let player = PCMPlayer()
    let micPlayer = PCMPlayer()
    private let transcriber = LocalTranscriber()
    private let ingestor = ContextIngestor()
    private let audioForwarder = LiveAudioForwarder()
    private var captureStopTask: Task<Void, Never>?
    private var captureStopping = false
    private var ruleRequestID = UUID()
    private var credentialLoadAttempted = false
    private var contextScanTask: Task<Void, Never>?
    private var droppedVoiceBytes = 0
    private var lastVoiceDropReport = Date.distantPast
    private var playbackInputGate = PlaybackInputGate()
    @Published private(set) var credentialsLoading = false

    @Published var selectedApplicationID: Int32 = 0
    @Published var starting: Bool = false
    @Published var manualText: String = ""
    @Published var scannedContext: IngestedContext = IngestedContext()
    @Published var synthesizedRules: SynthesizedRules?
    @Published var isPlanning: Bool = false
    @Published var receivedVoiceAudio: Bool = false

    private var sessionTimer: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var rulesTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    convenience init() {
        self.init(runtime: MeetingRuntime(geminiKeyOverride: "", openaiKeyOverride: "", jevKeyOverride: ""))
        if !CommandLine.arguments.contains("--demo") { loadCredentialsIfNeeded() }
    }

    private func loadCredentialsIfNeeded() {
        guard !credentialLoadAttempted else { return }
        credentialLoadAttempted = true; credentialsLoading = true
        Task { [weak self] in
            let keys = await CredentialLoader.load()
            guard let self else { return }
            self.credentialsLoading = false
            guard let keys else {
                self.errorMessage = "保存済みの接続情報を読み込めませんでした。設定からAPIキーを確認してください。"
                return
            }
            // A key entered while the background read was pending takes precedence.
            if self.runtime.geminiKey.isEmpty { self.runtime.geminiKey = keys["gemini"] ?? "" }
            if self.runtime.openaiKey.isEmpty { self.runtime.openaiKey = keys["openai"] ?? "" }
            if self.runtime.jevKey.isEmpty { self.runtime.jevKey = keys["jev"] ?? "" }
            self.runtime.geminiConfigured = !self.runtime.geminiKey.isEmpty
            self.runtime.openaiConfigured = !self.runtime.openaiKey.isEmpty
            self.runtime.jevConfigured = !self.runtime.jevKey.isEmpty
        }
    }

    init(runtime: MeetingRuntime) {
        self.runtime = runtime
        runtime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        capture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        player.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)

        runtime.onVoiceAudio = { [weak self] data, rate in
            self?.receivedVoiceAudio = true
            self?.player.enqueue(data: data, sampleRate: rate)
        }
        runtime.onVoiceInterrupted = { [weak self] in
            self?.player.stop()
        }
        player.onPlaybackStateChanged = { [weak self] active in
            guard let self else { return }
            self.playbackInputGate.playbackChanged(active, at: ProcessInfo.processInfo.systemUptime)
            self.runtime.setVoicePlaybackActive(active)
        }
        runtime.$liveActive.removeDuplicates().sink { [weak self] active in
            if !active { self?.audioForwarder.stop() }
        }.store(in: &subscriptions)
        runtime.onStopRequested = { [weak self] in self?.stopCapture() }
        runtime.onObjectiveChanged = { [weak self] in
            guard let self, !self.demoMode, !self.listenOnly else { return }
            self.rulesTask?.cancel()
            self.ruleRequestID = UUID(); self.isPlanning = false
            self.rulesTask = Task { [weak self] in await self?.prepareRules() }
        }
        audioForwarder.onError = { [weak self] message in
            self?.runtime.errorMessage = message
            self?.runtime.closeVoice()
        }
        audioForwarder.onDroppedAudio = { [weak self] bytes in
            guard let self else { return }
            self.droppedVoiceBytes += bytes
            guard Date().timeIntervalSince(self.lastVoiceDropReport) >= 10 else { return }
            let seconds = Double(self.droppedVoiceBytes) / 32_000
            self.droppedVoiceBytes = 0; self.lastVoiceDropReport = Date()
            self.addActivity("音声送信", String(format: "遅延した音声 %.1f 秒分を省略し、会話の接続を維持しました。", seconds))
        }

        capture.onAudio = { [weak self] data, source in self?.acceptAudio(data, source: source) }
        capture.onFrame = { [weak self] frame in self?.acceptFrame(frame) }
        capture.onSpeechActivity = { [weak self] source in
            guard let self else { return }
            guard !self.playbackInputGate.suppresses(source, at: ProcessInfo.processInfo.systemUptime) else { return }
            self.runtime.noteHumanSpeech(source: source)
        }

        transcriber.onTranscript = { [weak self] event in self?.receive(event) }
        transcriber.onError = { [weak self] message in
            self?.runtime.addActivity("音声認識", message)
            self?.runtime.errorMessage = message
        }
        transcriber.onDiagnostics = { [weak self] message in
            self?.runtime.addActivity("音声認識", message)
        }
        transcriber.contextualStringsProvider = { [weak self] in
            guard let self else { return SpeechContextVocabulary.defaultBaseVocabulary }
            return self.buildContextualStrings()
        }

        if !CommandLine.arguments.contains("--demo") { scanProjectContext() }
        Task { await capture.refreshApplications() }
    }

    var settings: AppSettings {
        get { runtime.settings }
        set { runtime.settings = newValue }
    }
    var events: [TranscriptEvent] {
        get { runtime.events }
        set { runtime.events = newValue }
    }
    var activities: [ActivityRow] {
        get { runtime.activities }
        set { runtime.activities = newValue }
    }
    var jobs: [BuildJob] {
        get { runtime.jobs }
        set { runtime.jobs = newValue }
    }
    var thinkingNotes: [ThinkingNote] {
        get { runtime.thinkingNotes }
        set { runtime.thinkingNotes = newValue }
    }
    var researchNotes: [ResearchNote] {
        get { runtime.researchNotes }
        set { runtime.researchNotes = newValue }
    }
    var running: Bool {
        get { runtime.running }
        set { runtime.running = newValue }
    }
    var demoMode: Bool {
        get { runtime.demoMode }
        set { runtime.demoMode = newValue }
    }
    var liveActive: Bool { runtime.liveActive }
    var connecting: Bool { runtime.connecting }
    var isThinking: Bool { runtime.isThinking }
    var listenOnly: Bool {
        get { runtime.listenOnly }
        set { runtime.listenOnly = newValue }
    }
    var status: String {
        get { runtime.status }
        set { runtime.status = newValue }
    }
    var acknowledgement: String {
        get { runtime.acknowledgement }
        set { runtime.acknowledgement = newValue }
    }
    var reply: String {
        get { runtime.reply }
        set { runtime.reply = newValue }
    }
    var errorMessage: String? {
        get { runtime.errorMessage }
        set { runtime.errorMessage = newValue }
    }
    var judgeCalls: Int { runtime.judgeCalls }
    var sentFrames: Int { runtime.sentFrames }
    var liveStarts: Int { runtime.liveStarts }
    var sessionSeconds: Int {
        get { runtime.sessionSeconds }
        set { runtime.sessionSeconds = newValue }
    }
    var externalNotes: String {
        get { runtime.externalNotes }
        set { runtime.externalNotes = newValue }
    }
    var mobileReceiver: MobileLogReceiver { runtime.mobileReceiver }
    var geminiConfigured: Bool { runtime.geminiConfigured }
    var openaiConfigured: Bool { runtime.openaiConfigured }
    var jevConfigured: Bool { runtime.jevConfigured }

    var activeTaskDescription: String { runtime.activeTaskDescription }
    var handoff: String { runtime.handoff }

    var presenceTitle: String {
        if starting { return "声につないでいます" }
        if !running { return demoMode ? "デモを見ています" : "停止" }
        if listenOnly { return "今は、聞くだけ" }
        if player.isPlaying { return "話しています" }
        if isThinking { return "考えています" }
        if runtime.activeJobID != nil || jobs.contains(where: { $0.status == "制作中" }) { return "試作しています" }
        if connecting { return "呼びかけに応えています" }
        return "聞いています"
    }

    public var presenceIcon: String {
        switch presenceTitle {
        case "話しています": return "waveform.badge.mic"
        case "考えています", "少し考えています": return "brain"
        case "試作しています": return "hammer.fill"
        case "声につないでいます", "呼びかけに応えています": return "sparkles"
        case "今は、聞くだけ": return "ear.badge.checkmark"
        case "聞いています", "一緒に聞いています": return "ear"
        case "停止": return "stop.circle"
        default: return "waveform"
        }
    }

    func receive(_ event: TranscriptEvent) { runtime.receive(event) }
    func stopWork() { runtime.stopWork() }
    func closeVoice() { runtime.closeVoice() }
    func applyVoiceCommand(_ command: VoiceCommand) { runtime.applyVoiceCommand(command) }
    func addActivity(_ kind: String, _ message: String) { runtime.addActivity(kind, message) }

    func requestThinking(topic: String, decideBuildAfterward: Bool = false) async {
        await runtime.requestThinking(topic: topic, decideBuildAfterward: decideBuildAfterward)
    }

    @discardableResult
    func requestJob(topic: String, origin: String = "meeting_transcript", explicitUserRequest: Bool = false) -> (jobId: String?, status: String, message: String) {
        runtime.requestJob(topic: topic, origin: origin, explicitUserRequest: explicitUserRequest)
    }

    func wakeVoice(prompt: String = "これまでの会議を踏まえて、一言返してください。") async {
        await runtime.wakeVoice(prompt: prompt)
    }

    func submitText() {
        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard running || demoMode else { errorMessage = "「一緒に聞く」を押すか、詳細画面でデモを始めてください。"; return }
        manualText = ""
        receive(TranscriptEvent(text: text, source: .manual))
    }

    private func acceptAudio(_ data: Data, source: AudioSource) {
        guard running else { return }
        let suppressMic = playbackInputGate.suppresses(source, at: ProcessInfo.processInfo.systemUptime)
        if !suppressMic { transcriber.append(data, source: source) }
        if !suppressMic, settings.mixMicrophone, source == .microphone,
           let device = player.outputDevices.first(where: { $0.id == player.selectedOutputDeviceID }), device.isVirtual {
            micPlayer.selectedOutputDeviceID = device.id; micPlayer.enqueue(data: data, sampleRate: 16_000)
        }
        audioForwarder.configure(
            provider: liveActive ? runtime.activeLiveProvider : nil,
            source: settings.liveInputSource == "meeting" ? .meeting : .microphone
        )
        // Maintain PCM timing and server VAD silence without leaking speaker
        // output back into the conversation. Remote Meet audio is unaffected.
        audioForwarder.append(suppressMic ? Data(repeating: 0, count: data.count) : data, source: source)
    }

    private func acceptFrame(_ frame: Data) {
        runtime.lastFrame = frame; runtime.lastFrameTime = Date()
        guard settings.sendScreen, liveActive else { return }
        Task { [weak self] in
            guard let self, let active = self.runtime.activeLiveProvider else { return }
            do { try await active.sendFrame(frame); self.runtime.sentFrames += 1 } catch { self.closeVoice() }
        }
    }

    func saveSettings() {
        do { try AppPaths.save(settings) } catch { errorMessage = error.localizedDescription }
    }

    func saveKey(_ value: String, provider: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try KeyStore.save(value, account: provider)
            if provider == "gemini" { runtime.geminiKey = value.trimmingCharacters(in: .whitespacesAndNewlines); runtime.geminiConfigured = true }
            else if provider == "openai" { runtime.openaiKey = value.trimmingCharacters(in: .whitespacesAndNewlines); runtime.openaiConfigured = true }
            else { runtime.jevKey = value.trimmingCharacters(in: .whitespacesAndNewlines); runtime.jevConfigured = true }
            let name = provider == "gemini" ? "Gemini" : (provider == "openai" ? "OpenAI" : "Jev")
            addActivity("設定", "\(name)のキーをキーチェーンに保存しました。")
        } catch { errorMessage = "キーを保存できません: \(error.localizedDescription)" }
    }

    func startMeeting() async {
        loadCredentialsIfNeeded()
        guard !credentialsLoading else {
            errorMessage = "接続情報を読み込んでいます。少し待ってからもう一度開始してください。"
            return
        }
        guard !starting, !running, !captureStopping else { return }
        guard settings.liveInputSource != "meeting" || selectedApplicationID != 0 else {
            errorMessage = "iPhoneの声を聞くには、Meetを開いているアプリを「声の接続」で選んでください。"; return
        }
        guard settings.liveInputSource != "microphone" || settings.includeMicrophone else {
            errorMessage = "Macから話すには「自分のマイクも聞く」を有効にするか、「声の接続」で話す場所を選び直してください。"; return
        }
        starting = true; errorMessage = nil
        runtime.resetSession(demo: false)
        let token = runtime.sessionID
        defer { if token == runtime.sessionID { starting = false } }
        receivedVoiceAudio = false
        do {
            try await transcriber.start()
            guard token == runtime.sessionID else { return }
            try await capture.start(applicationID: selectedApplicationID == 0 ? nil : selectedApplicationID, includeMicrophone: settings.includeMicrophone, includeScreen: settings.sendScreen)
            guard token == runtime.sessionID else { return }
            running = true; status = "一緒に聞いています"; saveSettings()
            addActivity("開始", "端末内で文字起こしを開始しました。\(settings.useJev ? "確定発言をJevで判断します。" : "限定ルールで判定します。")")
            sessionTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, self.running, !Task.isCancelled, self.runtime.sessionID == token else { return }
                    self.sessionSeconds += 1
                    if self.sessionSeconds >= max(1, self.settings.meetingMinutes) * 60 {
                        self.addActivity("上限", "会議時間の上限で停止しました。")
                        await self.stopMeeting(); return
                    }
                    if !self.capture.isRunning { self.errorMessage = self.capture.errorMessage ?? "音声取得が停止しました。"; await self.stopMeeting(); return }
                }
            }
        } catch {
            guard token == runtime.sessionID else { return }
            transcriber.stop(); await capture.stop(); errorMessage = error.localizedDescription; status = "声の接続を確認してください"
        }
    }

    func stopMeeting() async {
        stopCapture()
        await runtime.stopMeeting()
        await captureStopTask?.value
    }

    /// Shared by voice "今日は終わり", UI stop and app termination.
    private func stopCapture() {
        guard !captureStopping else { return }
        captureStopping = true
        sessionTimer?.cancel(); sessionTimer = nil
        demoTask?.cancel(); demoTask = nil
        rulesTask?.cancel(); rulesTask = nil
        ruleRequestID = UUID(); isPlanning = false
        starting = false
        audioForwarder.stop(); transcriber.stop(); player.stop(); micPlayer.stop()
        captureStopTask = Task { [weak self] in
            guard let self else { return }
            await self.capture.stop()
            self.captureStopping = false
            self.captureStopTask = nil
        }
    }

    func runDemo() {
        guard !running, !starting, !runtime.worker.isRunning else { return }
        runtime.resetSession(demo: true); status = "デモ · 録音もAPI接続も行いません"
        let nickname = settings.policy.nickname
        let script = ["会議のアイデアを整理できるメモアプリがあったら便利だね。", "\(nickname)、今の話をどう思う？", "色を青に変更して。", "作って……いや、作らなくていい。", "\(nickname)、制作を止めて。"]
        demoTask = Task { [weak self] in
            for text in script {
                guard let self, !Task.isCancelled else { return }
                self.receive(TranscriptEvent(text: text, source: .manual))
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    func scanProjectContext(directory: URL? = nil) {
        guard contextScanTask == nil else { return }
        let targetDir = directory ?? AppPaths.project
        let scanner = ingestor
        contextScanTask = Task { [weak self] in
            let result = await BoundedBackgroundRead.run { expired in
                scanner.scanDirectoryContext(at: targetDir, shouldStop: expired)
            }
            guard let self else { return }
            self.contextScanTask = nil
            guard let result else {
                self.addActivity("スキャン", "作業資料の読み込みが時間内に終わりませんでした。現在の会話と保存済みの基準で続けます。")
                return
            }
            self.scannedContext = result
            if !result.projectSummary.isEmpty || !result.prototypeHistory.isEmpty {
                self.addActivity("スキャン", "Codex作業環境のドキュメントと過去試作を読み込みました。")
            }
        }
    }

    func prepareRules() async {
        guard !isPlanning else { return }
        let engine = settings.ruleSynthesisEngine.lowercased()
        if engine == "gemini" && !geminiConfigured {
            errorMessage = "Gemini APIキーを設定するか、Codex / Antigravity / Grok CLIエンジンを選択してください（既存契約枠を利用）。"
            return
        }
        isPlanning = true
        let requestID = UUID(); ruleRequestID = requestID
        let session = runtime.sessionID, epoch = runtime.workEpoch
        let objective = settings.policy.objective
        defer { if requestID == ruleRequestID { isPlanning = false } }
        do {
            var combined = scannedContext
            combined.externalNotes = externalNotes

            let execPath: String
            if engine == "codex" { execPath = settings.codexPath }
            else if engine == "agy" { execPath = settings.agyPath }
            else if engine == "grok" { execPath = settings.grokPath }
            else { execPath = "" }

            let rules = try await ingestor.synthesizeRules(
                objective: settings.policy.objective,
                nickname: settings.policy.nickname,
                context: combined,
                engine: engine,
                executablePath: execPath,
                apiKey: runtime.geminiKey,
                model: settings.textModel,
                codexModel: settings.thinkingModel,
                codexEffort: settings.thinkingEffort,
                codexBackend: runtime.codexBackend
            )
            guard !Task.isCancelled, requestID == ruleRequestID,
                  session == runtime.sessionID, epoch == runtime.workEpoch,
                  objective == settings.policy.objective else { return }
            synthesizedRules = rules
            settings.policy.persona = rules.persona
            settings.policy.speakCriteria = rules.speakCriteria
            settings.policy.buildCriteria = rules.buildCriteria
            settings.policy.doNotBuildCriteria = rules.doNotBuildCriteria
            settings.policy.projectContext = rules.projectSummary
            settings.rules = rules.formattedMarkdown
            saveSettings()

            let engineName: String
            switch engine {
            case "codex": engineName = "Codex CLI (既存契約枠を利用)"
            case "agy": engineName = "Antigravity CLI (ローカル環境を利用)"
            case "grok": engineName = "Grok CLI (ローカル環境を利用)"
            default: engineName = "Gemini API"
            }
            addActivity("判断基準合成", "[\(engineName)] 4大判断基準（ツッコミ・試作・禁止事項・ペルソナ）を策定しました。Jevと音声AIに適用完了。")
        } catch {
            guard !Task.isCancelled, requestID == ruleRequestID, session == runtime.sessionID else { return }
            addActivity("判断基準", CLIOutputDiagnostics.sanitize(error.localizedDescription))
            errorMessage = "判断基準を更新できませんでした。今までの基準を使います。"
        }
    }

    func shutdown() async {
        mobileReceiver.stop()
        await stopMeeting()
    }

    func openPrototype(_ job: BuildJob) {
        let html = job.directory.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: html.path) {
            NSWorkspace.shared.open(html)
        } else {
            NSWorkspace.shared.open(job.directory)
        }
    }

    func buildContextualStrings() -> [String] {
        SpeechContextVocabulary.buildContextualStrings(
            baseVocabulary: SpeechContextVocabulary.defaultBaseVocabulary,
            objective: settings.policy.objective,
            projectContext: settings.policy.projectContext,
            recentTerms: runtime.researchNotes.map(\.term) + Array(runtime.researchedTerms),
            limit: 100
        )
    }
}
