import SwiftUI
import AppKit
import MeetingCore
import MeetingServices

@main
struct MeetingSidekickApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var handledLaunch = false
    var body: some Scene {
        WindowGroup("会議の相棒", id: "main") {
            MainView(model: model)
                .frame(minWidth: 460, minHeight: 490)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    delegate.model = model
                    guard !handledLaunch else { return }
                    handledLaunch = true
                    if CommandLine.arguments.contains("--demo") { model.runDemo() }
                    if CommandLine.arguments.contains("--snapshot") {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            var captured = false
                            if let view = NSApp.windows.first(where: { $0.title == "会議の相棒" })?.contentView,
                               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                                view.cacheDisplay(in: view.bounds, to: bitmap)
                                if let image = bitmap.representation(using: .png, properties: [:]) {
                                    do {
                                        try image.write(to: AppPaths.project.appendingPathComponent("preview.png"))
                                        captured = true
                                    } catch { /* The report below records an unsuccessful snapshot. */ }
                                }
                            }
                            let report: [String: Any] = ["demo": model.demoMode, "eventCount": model.events.count, "jobCount": model.jobs.count, "liveStarts": model.liveStarts, "judgeCalls": model.judgeCalls, "recording": model.running, "snapshotCaptured": captured, "windows": NSApp.windows.map { ["title": $0.title, "visible": $0.isVisible, "width": $0.frame.width, "height": $0.frame.height] as [String: Any] }]
                            try? FileManager.default.createDirectory(at: AppPaths.data, withIntermediateDirectories: true)
                            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: AppPaths.data.appendingPathComponent("demo-check.json")) }
                        }
                    }
                }
        }.defaultSize(width: 480, height: 560)
            .defaultLaunchBehavior(.presented)
        .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra("会議の相棒", systemImage: model.running ? "waveform.circle.fill" : "waveform.circle") {
            CompanionMenu(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct CompanionMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.presenceTitle)
        Button("相棒を表示") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if model.running {
            Button(model.listenOnly ? "会話に戻る" : "今は聞くだけ") {
                model.applyVoiceCommand(model.listenOnly ? .resumeConversation : .listenOnly)
            }
            Button("今日は終わり") { Task { await model.stopMeeting() } }
        }
        Divider()
        Button("アプリを終了") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var settingsVisible = false
    @State private var contextStudioVisible = false
    @State private var diagnosticsVisible = false
    @State private var audioConnectionVisible = false
    @State private var showTranscript = false
    @State private var showComposer = false
    @State private var selectedJob: BuildJob?
    @State private var selectedNote: ThinkingNote?
    @State private var selectedResearchNote: ResearchNote?
    private let accent = Color(red: 0.17, green: 0.43, blue: 0.36)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            VStack(spacing: 12) {
                if let error = model.errorMessage {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(error).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                presenceHeader
                activeArtefactsBar

                if showTranscript {
                    conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 16) {
                        Spacer(minLength: 8)
                        Image(systemName: model.presenceIcon)
                            .font(.system(size: 56, weight: .ultraLight)).foregroundStyle(accent)
                            .accessibilityHidden(true)
                        Text(model.acknowledgement.isEmpty ? "いつもの会話に、そっと。" : model.acknowledgement)
                            .font(.title3.weight(.medium)).multilineTextAlignment(.center)
                        Text("「\(model.settings.policy.nickname)、今のどう思う？」")
                            .font(.callout).foregroundStyle(.secondary)
                        if model.demoMode { Text("デモです。録音・API接続はしていません。").font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 8)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if showComposer {
                    composer
                }

                bottomBar
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .sheet(isPresented: $settingsVisible) { SettingsView(model: model) }
        .sheet(isPresented: $contextStudioVisible) { ContextStudioView(model: model) }
        .sheet(isPresented: $diagnosticsVisible) { DiagnosticsView(model: model) }
        .sheet(isPresented: $audioConnectionVisible) { AudioConnectionView(model: model) }
        .sheet(item: $selectedJob) { job in
            VStack(alignment: .leading, spacing: 14) {
                Text(job.title).font(.title2.bold()); Text(job.status).foregroundStyle(.secondary)
                ScrollView { Text(job.log.isEmpty ? job.prompt : job.log).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("ブラウザで試作品を開く") { model.openPrototype(job) }
                        .buttonStyle(.borderedProminent)
                    Button("成果物フォルダを開く") { NSWorkspace.shared.open(job.directory) }
                    Spacer()
                    Button("閉じる") { selectedJob = nil }
                }
            }.padding(24).frame(width: 760, height: 550)
        }
        .sheet(item: $selectedNote) { note in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("思考・計画メモ", systemImage: "brain").font(.title2.bold())
                    Spacer()
                    Text(note.timestamp, style: .time).foregroundStyle(.secondary)
                }
                Text("検討課題: " + note.topic).font(.headline).foregroundStyle(accent)
                ScrollView {
                    Text(note.content).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("閉じる") { selectedNote = nil }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 680, height: 500)
        }
        .sheet(item: $selectedResearchNote) { note in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("用語調査メモ", systemImage: "book.closed.fill").font(.title2.bold())
                    Spacer()
                    Text(note.timestamp, style: .time).foregroundStyle(.secondary)
                }
                Text("用語: " + note.term).font(.headline).foregroundStyle(accent)
                if !note.summary.isEmpty {
                    Text(note.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !note.detail.isEmpty {
                            Text(note.detail).font(.body).textSelection(.enabled)
                        }
                        let validSources = note.sources.filter { ResearchSource.isValidWebURL($0.url) }
                        if !validSources.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("参考:").font(.caption.bold()).foregroundStyle(.secondary)
                                ForEach(Array(validSources.prefix(3)), id: \.self) { source in
                                    if let url = URL(string: source.url) {
                                        Link(destination: url) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "link")
                                                Text(source.title.isEmpty ? source.url : source.title)
                                            }
                                            .font(.caption)
                                        }
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }
                        if !note.evidenceText.isEmpty {
                            Text("発話コンテキスト:").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(note.evidenceText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("閉じる") { selectedResearchNote = nil }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 620, height: 460)
        }
    }

    private var topBar: some View {
        HStack {
            Image(systemName: "waveform.badge.mic").font(.headline).foregroundStyle(accent)
            Text("会議の相棒").font(.headline)
            Text(model.settings.policy.nickname).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.12), in: Capsule())

            Spacer()

            Button { audioConnectionVisible = true } label: { Label("声の接続", systemImage: "headphones") }
                .buttonStyle(.borderless).font(.caption)
            Menu {
                Button("設定") { settingsVisible = true }
                Button("話題と判断基準") { contextStudioVisible = true }
                Button("診断とログ") { diagnosticsVisible = true }
                Divider()
                Button("デモで試す") { model.runDemo() }.disabled(model.running || model.starting)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("その他の操作")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var presenceHeader: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(model.running ? 0.15 : 0.08))
                        .frame(width: 44, height: 44)
                    Image(systemName: model.presenceIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(model.presenceTitle)
                            .font(.system(size: 16, weight: .bold))
                        if model.running {
                            HStack(spacing: 3) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                ProgressView(value: Double(model.capture.level))
                                    .frame(width: 40)
                            }
                        }
                    }
                    Text(model.reply.isEmpty ? model.status : model.reply)
                        .font(.subheadline)
                        .foregroundStyle(model.reply.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                }

                Spacer()

                if model.running || model.starting {
                    Button(role: .destructive) {
                        Task { await model.stopMeeting() }
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .controlSize(.regular)
                } else {
                    HStack(spacing: 6) {
                        Button {
                            if !model.settings.audioSetupSeen { audioConnectionVisible = true }
                            else { Task { await model.startMeeting() } }
                        } label: {
                            Label("一緒に聞く", systemImage: "mic.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }
            }

            if model.running {
                HStack {
                    if model.liveActive {
                        Button {
                            model.closeVoice()
                        } label: {
                            Label("通話を終了", systemImage: "phone.down.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    } else {
                        Button {
                            Task { await model.wakeVoice() }
                        } label: {
                            Label(model.connecting ? "接続中…" : "声をかける", systemImage: "sparkle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.connecting)
                    }

                    Button(model.listenOnly ? "会話に戻る" : "今は聞くだけ") {
                        model.applyVoiceCommand(model.listenOnly ? .resumeConversation : .listenOnly)
                    }.font(.caption)

                    Spacer()
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var activeArtefactsBar: some View {
        let activeJobs = model.jobs.filter { ["制作中", "待機中", "変更を反映中"].contains($0.status) }
        let latestNote = model.thinkingNotes.last
        let latestResearch = model.researchNotes.last
        if !model.jobs.isEmpty || latestNote != nil || latestResearch != nil {
            HStack(spacing: 10) {
                if let job = activeJobs.last ?? model.jobs.last {
                    Button {
                        selectedJob = job
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "hammer.fill").foregroundStyle(accent)
                            Text(job.title).font(.caption.bold()).lineLimit(1)
                            Text("[\(job.status)]").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                if let note = latestNote {
                    Button {
                        selectedNote = note
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "brain").foregroundStyle(.blue)
                            Text("思考: \(note.topic)").font(.caption).lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                if let research = latestResearch {
                    Button {
                        selectedResearchNote = research
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "book.closed.fill").foregroundStyle(.purple)
                            Text("調べたこと: \(research.term)").font(.caption.bold()).lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("会話の流れ", systemImage: "text.bubble").font(.headline)
                Spacer()
                if model.liveActive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("通話中").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.events.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "ear").font(.system(size: 36)).foregroundStyle(accent.opacity(0.7))
                                Text("必要なときに、参加します。").font(.title3.bold())
                                Text("会話を文字にして、呼びかけやアイデアを判断します。\nまず「デモ」で動きを確認できます。").foregroundStyle(.secondary).lineSpacing(5)
                            }.padding(.vertical, 40).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(model.events, id: \.id) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    let senderLabel: String = {
                                        switch event.source {
                                        case .microphone: return "あなた"
                                        case .meeting: return "会議"
                                        case .mobile: return "あなた (iPhone)"
                                        case .assistant: return "相棒"
                                        case .manual: return "入力"
                                        }
                                    }()
                                    Text(senderLabel).font(.caption.bold()).foregroundStyle(accent)
                                    Text(event.timestamp, style: .time).font(.caption2).foregroundStyle(.tertiary)
                                    if !event.isFinal { Text("認識中").font(.caption2).foregroundStyle(.secondary) }
                                }
                                Text(event.text).foregroundStyle(event.isFinal ? .primary : .secondary).textSelection(.enabled)
                            }.id(event.id).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.vertical, 8)
                }.onChange(of: model.events.count) { _, _ in if let id = model.events.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private var composer: some View {
        HStack {
            TextField("発言を入力して判断を試す（例：サイドキック、今の話をどう思う？）", text: $model.manualText).textFieldStyle(.plain).onSubmit { model.submitText() }
            Text(model.demoMode ? "デモ" : "実行モード").font(.caption2).foregroundStyle(.secondary)
            Button { model.submitText() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.plain).disabled(model.manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var bottomBar: some View {
        HStack {
            if model.mobileReceiver.isRunning {
                HStack(spacing: 4) {
                    Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(.green)
                    Text("iPhone受信中").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(model.settings.policy.nickname).font(.caption2).foregroundStyle(.tertiary)
            }

            Spacer()

            Button(showTranscript ? "会話を閉じる" : "会話を見る") { showTranscript.toggle() }
                .font(.caption).buttonStyle(.borderless)

            Button {
                withAnimation { showComposer.toggle() }
            } label: {
                Image(systemName: showComposer ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("手動テキスト入力を表示/非表示")
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let accent = Color(red: 0.17, green: 0.43, blue: 0.36)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("診断と詳細ログ (Advanced)", systemImage: "chart.bar.doc.horizontal")
                    .font(.title2.bold())
                Spacer()
                Button("閉じる") { dismiss() }
            }

            HStack(spacing: 12) {
                statCard(title: "JEV判定", value: "\(model.judgeCalls)回")
                statCard(title: "画面送信", value: "\(model.sentFrames)枚")
                statCard(title: "音声AI起動", value: "\(model.liveStarts)回")
                statCard(title: "思考メモ", value: "\(model.thinkingNotes.count)件")
                statCard(title: "用語調査", value: "\(model.researchNotes.count)件")
                statCard(title: "試作ジョブ", value: "\(model.jobs.count)件")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("内部アクティビティ履歴").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.activities.isEmpty {
                            Text("アクティビティログはありません。").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(model.activities.reversed()) { row in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(accent.opacity(0.6)).frame(width: 6, height: 6).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(row.kind).font(.caption.bold())
                                            Text(row.time, style: .time).font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        Text(row.message).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("ログをクリア") {
                    model.activities.removeAll()
                }
                .font(.caption)
            }
        }
        .padding(24)
        .frame(width: 720, height: 580)
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var gemini = ""
    @State private var openai = ""
    @State private var jev = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("接続と設定").font(.title2.bold())
            Form {
                Section("今日の会議") {
                    TextEditor(text: $model.settings.policy.objective)
                        .frame(height: 70)
                    HStack {
                        Text("呼び名").foregroundStyle(.secondary)
                        TextField("サイドキック", text: $model.settings.policy.nickname)
                    }
                }
                Section("参加のしかた") {
                    Toggle("目的に合う案を自動で試作", isOn: $model.settings.policy.autoBuild)
                    Toggle("自分から意見やツッコミ", isOn: $model.settings.policy.proactiveSpeech)
                    Toggle("呼び出し中は画面も見せる", isOn: $model.settings.sendScreen).disabled(model.running)
                }
                Section("会議アプリ") {
                    Picker("キャプチャ対象", selection: $model.selectedApplicationID) {
                        Text("マイクだけ").tag(Int32(0))
                        ForEach(model.capture.applications) { app in Text(app.name).tag(app.id) }
                    }.disabled(model.running)
                    Button("アプリ一覧を更新") { Task { await model.capture.refreshApplications() } }.font(.caption)
                }
                Section("音声AIエンジン") {
                    Picker("会話エンジン", selection: $model.settings.voiceProvider) {
                        Text("Gemini Live (双方向音声・画面共有)").tag("gemini")
                        Text("OpenAI Realtime (GPT-4o Realtime)").tag("openai")
                    }
                }
                Section("判断基準の生成エンジン（事前ルール策定）") {
                    Picker("生成エンジン", selection: $model.settings.ruleSynthesisEngine) {
                        Text("Codex CLI (既存契約枠を利用)").tag("codex")
                        Text("Antigravity CLI (agy · 既存契約枠を利用)").tag("agy")
                        Text("Grok CLI (grok · 既存契約枠を利用)").tag("grok")
                        Text("Google Gemini API (従量課金)").tag("gemini")
                    }
                    if model.settings.ruleSynthesisEngine == "codex" {
                        TextField("Codex実行パス", text: $model.settings.codexPath)
                        Text("既存のCodex契約枠を利用するため、追加のAPI従量課金を避けられる場合があります（利用枠・契約条件に依存）。").font(.caption).foregroundStyle(.secondary)
                    } else if model.settings.ruleSynthesisEngine == "agy" {
                        TextField("Antigravity実行パス", text: $model.settings.agyPath)
                        Text("ローカルのAntigravity CLIを利用するため、追加のAPI従量課金を避けられる場合があります。").font(.caption).foregroundStyle(.secondary)
                    } else if model.settings.ruleSynthesisEngine == "grok" {
                        TextField("Grok実行パス", text: $model.settings.grokPath)
                        Text("ローカルのGrok Build CLIを利用するため、追加のAPI従量課金を避けられる場合があります。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("Geminiモデル", text: $model.settings.textModel)
                        Text("Gemini APIキーを使用してクラウドで推論します。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("思考・計画エンジン (System 2 · 会議中の深い思考)") {
                    Picker("思考エンジン", selection: $model.settings.thinkingEngine) {
                        Text("Codex App Server / CLI (既存契約枠を利用)").tag("codex")
                        Text("Antigravity CLI (agy · 既存契約枠を利用)").tag("agy")
                        Text("Grok CLI (grok · 既存契約枠を利用)").tag("grok")
                        Text("Google Gemini API (従量課金)").tag("gemini")
                    }
                    if model.settings.thinkingEngine == "codex" {
                        TextField("思考モデル", text: $model.settings.thinkingModel)
                        TextField("推論エフォート (reasoning effort)", text: $model.settings.thinkingEffort)
                    }
                    Text("会議中にJEVが深い検討や設計が必要と判断した際に、思考メモを生成するエンジンです。").font(.caption).foregroundStyle(.secondary)
                }
                Section("専門用語のミニ調査 (Codex)") {
                    TextField("調査モデル", text: $model.settings.terminologyResearchModel)
                    TextField("推論エフォート (reasoning effort)", text: $model.settings.terminologyResearchEffort)
                    Toggle("Web検索を利用する (--search)", isOn: $model.settings.enableTerminologyWebSearch)
                    Text("会議中の専門用語・略語を検出した際、Codexが軽量設定でWeb調査しメモを作成します。通常UIにはモデル名は表示されません。").font(.caption).foregroundStyle(.secondary)
                }
                if model.settings.voiceProvider == "gemini" {
                    Section("Gemini Live · 音声と画面") {
                        HStack {
                            SecureField(model.geminiConfigured ? "キーは保存済み（変更するときだけ入力）" : "既存のGemini APIキー", text: $gemini)
                            Button("保存") { model.saveKey(gemini, provider: "gemini"); gemini = "" }.disabled(gemini.isEmpty)
                        }
                        TextField("Liveモデル", text: $model.settings.liveModel)
                        TextField("判断基準を考えるモデル", text: $model.settings.textModel)
                        Text("キーはmacOSキーチェーンに保存します。ツール呼び出しによる試作開始に対応しています。").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("OpenAI Realtime · 音声会話") {
                        HStack {
                            SecureField(model.openaiConfigured ? "キーは保存済み（変更するときだけ入力）" : "既存のOpenAI APIキー", text: $openai)
                            Button("保存") { model.saveKey(openai, provider: "openai"); openai = "" }.disabled(openai.isEmpty)
                        }
                        TextField("Realtimeモデル", text: $model.settings.openaiModel)
                        TextField("判断基準を考えるモデル (Gemini)", text: $model.settings.textModel)
                        Text("キーはmacOSキーチェーンに保存します。リアルタイム双方向音声とツール呼び出しに対応しています。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("常時の判断") {
                    Toggle("Jevを使用（オフは限定キーワードルール）", isOn: $model.settings.useJev)
                    HStack { SecureField(model.jevConfigured ? "Jevキーは保存済み" : "TypeSafe APIキー", text: $jev); Button("保存") { model.saveKey(jev, provider: "jev"); jev = "" }.disabled(jev.isEmpty) }
                    TextField("判断API", text: $model.settings.judgeEndpoint)
                    TextField("判断モデル", text: $model.settings.judgeModel)
                    Text("ローカルのJev互換APIにも切り替えられます。限定ルールは会議の意味を理解するAIではありません。").font(.caption).foregroundStyle(.secondary)
                }
                Section("音声の入出力") {
                    Picker("音声AIに届ける声", selection: $model.settings.liveInputSource) {
                        Text("Macのマイク").tag("microphone")
                        Text("iPhone・会議の音声").tag("meeting")
                    }.disabled(model.running || model.starting)
                    Toggle("自分のマイクも聞く", isOn: $model.settings.includeMicrophone).disabled(model.running || model.starting)
                    Picker("AI音声の出力先", selection: Binding(get: { model.player.selectedOutputDeviceID ?? 0 }, set: { model.player.selectedOutputDeviceID = $0 == 0 ? nil : $0 })) {
                        Text("Macの既定出力").tag(UInt32(0)); ForEach(model.player.outputDevices) { Text($0.name).tag($0.id) }
                    }
                    Toggle("仮想出力へ自分のマイクも混ぜる", isOn: $model.settings.mixMicrophone)
                    Text("会議全員に届ける場合はBlackHole等の仮想出力を選び、Meetのマイクも同じデバイスにします。相手の音声出力はイヤホンへ。仮想デバイスの導入は自動では行いません。").font(.caption).foregroundStyle(.secondary)
                }
                Section("自動実行の上限") {
                    Stepper("試作は最大 \(model.settings.policy.maxJobs)件", value: $model.settings.policy.maxJobs, in: 1...10)
                    Stepper("Jev判定は最大 \(model.settings.maxJudgeCalls)回", value: $model.settings.maxJudgeCalls, in: 10...600, step: 10)
                    Stepper("音声AIは約 \(model.settings.liveSeconds)秒（返答は最後まで）", value: $model.settings.liveSeconds, in: 10...120, step: 10)
                    Stepper("会議は最大 \(model.settings.meetingMinutes)分", value: $model.settings.meetingMinutes, in: 5...120, step: 5)
                    Text("制作は1件ずつ、各5分で停止します。これらは回数・時間の制限であり、金額の保証ではありません。").font(.caption).foregroundStyle(.secondary)
                }
                Section("メモリーと判断基準") {
                    TextField("ユーザーの好み・前提", text: $model.settings.policy.memory, axis: .vertical).lineLimit(2...4)
                    TextField("会議の判断基準", text: $model.settings.rules, axis: .vertical).lineLimit(3...8)
                }
            }.formStyle(.grouped)
            HStack { Text("文字起こしは日本語の端末内音声認識を使用します。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("保存して閉じる") { model.saveSettings(); dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(22).frame(width: 750, height: 740)
    }
}

struct ContextStudioView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    @State private var speakCriteriaText = ""
    @State private var buildCriteriaText = ""
    @State private var doNotBuildCriteriaText = ""

    private let accent = Color(red: 0.17, green: 0.43, blue: 0.36)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("カテゴリ", selection: $selectedTab) {
                Text("📂 Codex・プロジェクト").tag(0)
                Text("📱 iPhone・チャットログ").tag(1)
                Text("⚡️ 4大判断基準（ポリシー）").tag(2)
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedTab {
                case 0: projectTab
                case 1: logsTab
                default: criteriaTab
                }
            }.frame(maxHeight: .infinity)

            Divider()

            HStack {
                Button("閉じる") { dismiss() }
                Spacer()
                if selectedTab != 2 {
                    Button {
                        Task {
                            await model.prepareRules()
                            syncCriteriaText()
                            selectedTab = 2
                        }
                    } label: {
                        let engineLabel: String = {
                            switch model.settings.ruleSynthesisEngine {
                            case "codex": return "Codex CLI"
                            case "agy": return "Antigravity CLI"
                            case "grok": return "Grok CLI"
                            default: return "Gemini API"
                            }
                        }()
                        Label(model.isPlanning ? "合成中…" : "⚡️ [\(engineLabel)] で判断基準を合成", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isPlanning || (model.settings.ruleSynthesisEngine == "gemini" && !model.geminiConfigured))
                }
                Button("✅ この判断基準を適用する") {
                    applyCriteriaText()
                    model.saveSettings()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 820, height: 680)
        .onAppear {
            syncCriteriaText()
            if model.scannedContext.projectSummary.isEmpty {
                model.scanProjectContext()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "brain.head.profile").font(.title).foregroundStyle(accent)
                VStack(alignment: .leading) {
                    Text("事前コンテキスト・判断基準スタジオ").font(.title2.bold())
                    Text("JEV等の高速判断器が的確に動くよう、過去のCodex成果物・チャット・iPhoneログから判断基準を策定します。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var projectTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 作業環境").font(.headline)
                    Text(AppPaths.project.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.scanProjectContext()
                } label: {
                    Label("再スキャン", systemImage: "arrow.clockwise")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.scannedContext.projectSummary.isEmpty {
                        GroupBox("📄 読み込まれた設計書・ドキュメント") {
                            Text(model.scannedContext.projectSummary)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }

                    GroupBox("🛠️ 過去の試作品・制作履歴 (\(model.scannedContext.prototypeHistory.count)件)") {
                        if model.scannedContext.prototypeHistory.isEmpty {
                            Text("過去の試作品フォルダ (Prototypes) はまだありません。").font(.caption).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.scannedContext.prototypeHistory, id: \.self) { item in
                                    HStack(alignment: .top) {
                                        Image(systemName: "cube.box").foregroundStyle(accent)
                                        Text(item).font(.caption)
                                    }
                                }
                            }
                        }
                    }

                    if !model.scannedContext.recentLogs.isEmpty {
                        GroupBox("📜 Git最近のコミット履歴") {
                            Text(model.scannedContext.recentLogs)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("📱 iPhone 胸ポケット録音・ライフログ連携（認証保護）") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(model.mobileReceiver.isRunning ? .green : .gray).frame(width: 8, height: 8)
                        Text(model.mobileReceiver.isRunning ? "iPhone連携を受信中" : "停止中").font(.caption.bold())
                        Spacer()
                        if model.mobileReceiver.isRunning {
                            Button("受信を停止") { model.mobileReceiver.stop() }.font(.caption).buttonStyle(.bordered)
                        } else {
                            Button("受信を開始") { model.mobileReceiver.start() }.font(.caption).buttonStyle(.borderedProminent)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("ペアリングPIN:").font(.caption.bold())
                        Text(model.mobileReceiver.pairingToken).font(.system(.caption, design: .monospaced)).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        Button {
                            model.mobileReceiver.regenerateToken()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2)
                        }.buttonStyle(.plain).help("PINを再生成")

                        Spacer()
                        let authUrl = "http://\(model.mobileReceiver.localIPAddress):\(model.mobileReceiver.port)/?pin=\(model.mobileReceiver.pairingToken)"
                        Button("PIN付きURLコピー") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(authUrl, forType: .string)
                        }.font(.caption)
                        Button("Safariで開く") {
                            if let url = URL(string: authUrl) { NSWorkspace.shared.open(url) }
                        }.font(.caption)
                    }

                    Text("同一Wi-Fi内のiPhoneから上記URLを開くと、PIN認証を自動通過して胸ポケット録音・ライフログを安全に送信できます（未認証リクエストは401拒絶）。")
                        .font(.caption2).foregroundStyle(.secondary)

                    if !model.mobileReceiver.receivedLogs.isEmpty {
                        Text("直近受信したログ (\(model.mobileReceiver.receivedLogs.count)件):").font(.caption2.bold())
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(model.mobileReceiver.receivedLogs.suffix(5).reversed(), id: \.self) { log in
                                    Text(log.prefix(60) + (log.count > 60 ? "…" : ""))
                                        .font(.caption2)
                                        .padding(5)
                                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("📋 外部チャット履歴・ライフログ・構想メモ").font(.headline)
                Text("ChatGPTやClaudeの会話ログ、日常の音声文字起こし、思いつきメモを貼り付けてください。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.externalNotes)
                    .font(.body)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .frame(height: 220)
            }
        }
    }

    private var criteriaTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("策定された4大判断基準（ポリシー）").font(.headline)
                Spacer()
                Picker("エンジン", selection: $model.settings.ruleSynthesisEngine) {
                    Text("Codex").tag("codex")
                    Text("Antigravity").tag("agy")
                    Text("Grok").tag("grok")
                    Text("Gemini API").tag("gemini")
                }
                .frame(width: 160)
                Button {
                    Task {
                        await model.prepareRules()
                        syncCriteriaText()
                    }
                } label: {
                    Label(model.isPlanning ? "合成中…" : "再合成する", systemImage: "sparkles")
                }.disabled(model.isPlanning || (model.settings.ruleSynthesisEngine == "gemini" && !model.geminiConfigured))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("🎭 AIの役割・ペルソナ") {
                        TextField("例: UI/UXの矛盾や実装難度を率直に指摘するシニアテックリード", text: $model.settings.policy.persona)
                            .textFieldStyle(.roundedBorder)
                    }

                    GroupBox("💬 ツッコミ・発言を入れる基準（1行に1つ）") {
                        TextEditor(text: $speakCriteriaText)
                            .font(.system(size: 12))
                            .frame(height: 70)
                    }

                    GroupBox("🛠️ 自動試作（Webアプリ実装）に着手する基準（1行に1つ）") {
                        TextEditor(text: $buildCriteriaText)
                            .font(.system(size: 12))
                            .frame(height: 70)
                    }

                    GroupBox("🚫 絶対に自動試作しない・見送り基準（1行に1つ）") {
                        TextEditor(text: $doNotBuildCriteriaText)
                            .font(.system(size: 12))
                            .frame(height: 70)
                    }

                    GroupBox("📚 プロジェクト・文脈要約") {
                        TextEditor(text: $model.settings.policy.projectContext)
                            .font(.system(size: 12))
                            .frame(height: 60)
                    }
                }
            }
        }
    }

    private func syncCriteriaText() {
        speakCriteriaText = model.settings.policy.speakCriteria.joined(separator: "\n")
        buildCriteriaText = model.settings.policy.buildCriteria.joined(separator: "\n")
        doNotBuildCriteriaText = model.settings.policy.doNotBuildCriteria.joined(separator: "\n")
    }

    private func applyCriteriaText() {
        model.settings.policy.speakCriteria = speakCriteriaText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.settings.policy.buildCriteria = buildCriteriaText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.settings.policy.doNotBuildCriteria = doNotBuildCriteriaText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let synthesized = SynthesizedRules(
            objective: model.settings.policy.objective,
            nickname: model.settings.policy.nickname,
            persona: model.settings.policy.persona,
            speakCriteria: model.settings.policy.speakCriteria,
            buildCriteria: model.settings.policy.buildCriteria,
            doNotBuildCriteria: model.settings.policy.doNotBuildCriteria,
            projectSummary: model.settings.policy.projectContext,
            rawText: model.settings.rules
        )
        model.settings.rules = synthesized.formattedMarkdown
    }
}
