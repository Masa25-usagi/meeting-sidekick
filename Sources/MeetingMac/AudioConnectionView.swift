import SwiftUI
import MeetingCore

struct AudioConnectionView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var heardReply = false
    private var fromMeeting: Bool { model.settings.liveInputSource == "meeting" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("声をつなぐ", systemImage: "waveform").font(.title2.bold())
                Spacer()
                Button("閉じる") { model.saveSettings(); dismiss() }
            }
            Text("いつものMeetのまま、声が届くか確かめます。")
                .foregroundStyle(.secondary)
            Form {
                Section("どこから話しますか？") {
                    Picker("話す場所", selection: $model.settings.liveInputSource) {
                        Text("Macから").tag("microphone")
                        Text("iPhone・会議から").tag("meeting")
                    }.pickerStyle(.segmented).disabled(model.running || model.starting)
                    Picker("Meetを開いているアプリ", selection: $model.selectedApplicationID) {
                        Text(fromMeeting ? "アプリを選ぶ" : "マイクだけ").tag(Int32(0))
                        ForEach(model.capture.applications) { Text($0.name).tag($0.id) }
                    }.disabled(model.running || model.starting)
                    Button("一覧を更新") { Task { await model.capture.refreshApplications() } }
                    if fromMeeting {
                        Text("iPhoneも同じMeetに入り、そこで話してください。Macのマイクは使いません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("返事を届ける先") {
                    Picker("AIの声", selection: Binding(get: { model.player.selectedOutputDeviceID ?? 0 }, set: {
                        model.player.selectedOutputDeviceID = $0 == 0 ? nil : $0
                        model.receivedVoiceAudio = false; heardReply = false
                    })) {
                        Text("Macの既定出力").tag(UInt32(0))
                        ForEach(model.player.outputDevices) { Text($0.name).tag($0.id) }
                    }
                    Text(fromMeeting
                         ? "iPhoneにも返すには、仮想出力を選び、Meetのマイクを同じデバイスにします。Meetの設定は自動では変えません。"
                         : "イヤホンを使うと、相棒の声がマイクに戻りにくくなります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("声の往復を確認") {
                    inputRow("Macの声", source: .microphone, level: model.capture.microphoneLevel,
                             lastAudio: model.capture.lastMicrophoneAudioAt)
                    inputRow("iPhone・会議の声", source: .meeting, level: model.capture.meetingLevel,
                             lastAudio: model.capture.lastMeetingAudioAt)
                    if model.running {
                        Button("返事を試す") {
                            heardReply = false; model.receivedVoiceAudio = false
                            Task { await model.wakeVoice(prompt: "接続確認です。『声が届いています』とだけ短く話してください。") }
                        }.disabled(model.connecting)
                        if let error = model.player.errorMessage { Text(error).foregroundStyle(.orange).font(.caption) }
                        if model.receivedVoiceAudio {
                            HStack {
                                Label(heardReply ? "返事を聞けたことを確認しました" : "返事の音声を受信しました", systemImage: heardReply ? "checkmark.circle" : "speaker.wave.2")
                                Spacer()
                                if !heardReply {
                                    Button(fromMeeting ? "iPhoneで聞こえた" : "聞こえた") { heardReply = true }
                                }
                            }.font(.caption)
                        } else {
                            Text("返事が聞こえるかは、まだ確認していません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("「一緒に聞く」を押して、ひとこと話してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(4) }
            HStack {
                if model.running || model.starting {
                    Button("停止") { Task { await model.stopMeeting() } }
                }
                Spacer()
                if model.running {
                    Button("このまま使う") {
                        model.settings.audioSetupSeen = true; model.saveSettings(); dismiss()
                    }.buttonStyle(.borderedProminent)
                } else {
                    Button(model.starting ? "つないでいます…" : "一緒に聞く") {
                        model.settings.includeMicrophone = !fromMeeting
                        Task { await model.startMeeting() }
                    }.buttonStyle(.borderedProminent)
                        .disabled(model.starting || (fromMeeting && model.selectedApplicationID == 0))
                }
            }
        }.padding(22).frame(width: 580, height: 650)
            .onAppear { model.player.refreshOutputDevices() }
            .onChange(of: model.settings.liveInputSource) { _, value in
                model.settings.includeMicrophone = value != "meeting"
                model.receivedVoiceAudio = false; heardReply = false
            }
            .onChange(of: model.selectedApplicationID) { _, _ in
                model.receivedVoiceAudio = false; heardReply = false
            }
    }

    private func inputRow(_ title: String, source: AudioSource, level: Float, lastAudio: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                ProgressView(value: Double(min(1, level * 5))).frame(width: 75)
                Text(lastAudio == nil ? "未受信" : (Date().timeIntervalSince(lastAudio!) < 3 ? "音声データ受信" : "音声が途切れています"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let event = model.events.last(where: { $0.source == source && !$0.text.isEmpty }) {
                Text("聞き取った言葉：\(event.text)").font(.caption).lineLimit(2)
            }
        }.accessibilityElement(children: .combine)
    }
}
