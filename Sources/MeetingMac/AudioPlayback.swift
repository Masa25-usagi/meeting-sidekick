import AVFoundation
import AudioToolbox
import CoreAudio
import Combine

struct AudioOutputDevice: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let uid: String
    var isVirtual: Bool { ["blackhole", "loopback", "virtual"].contains { name.lowercased().contains($0) } }
}

@MainActor
final class PCMPlayer: ObservableObject {
    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var selectedOutputDeviceID: UInt32? { didSet { if oldValue != selectedOutputDeviceID { stop() } } }
    @Published var errorMessage: String?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var currentRate: Double = 0
    private var queuedSeconds: Double = 0
    private var epoch = UUID()

    init() { refreshOutputDevices() }

    func refreshOutputDevices() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return }
        outputDevices = ids.compactMap { id in
            var stream = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &stream, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            func string(_ selector: AudioObjectPropertySelector) -> String {
                var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var unmanaged: Unmanaged<CFString>?
                var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(id, &a, 0, nil, &n, &unmanaged) == noErr,
                      let str = unmanaged?.takeRetainedValue() else { return "" }
                return str as String
            }
            return AudioOutputDevice(id: id, name: string(kAudioObjectPropertyName), uid: string(kAudioDevicePropertyDeviceUID))
        }
    }

    func enqueue(data: Data, sampleRate: Double = 24_000) {
        guard !data.isEmpty, data.count % 2 == 0, sampleRate > 0 else { return }
        do {
            if engine == nil || currentRate != sampleRate {
                stop()
                let engine = AVAudioEngine(); let player = AVAudioPlayerNode()
                if var id = selectedOutputDeviceID, let unit = engine.outputNode.audioUnit {
                    let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<UInt32>.size))
                    guard status == noErr else { throw NSError(domain: "OutputDevice", code: Int(status)) }
                }
                let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
                engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
                try engine.start(); player.play()
                self.engine = engine; self.player = player; currentRate = sampleRate
            }
            let duration = Double(data.count / 2) / sampleRate
            guard queuedSeconds + duration < 20 else { stop(); errorMessage = "音声再生が追いつかないため停止しました。"; return }
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)), let target = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = buffer.frameCapacity
            data.withUnsafeBytes { raw in
                for i in 0..<Int(buffer.frameLength) { target[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768 }
            }
            queuedSeconds += duration
            let token = epoch
            player?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in if let self, self.epoch == token { self.queuedSeconds = max(0, self.queuedSeconds - duration) } }
            }
        } catch { errorMessage = "音声出力を開始できません: \(error.localizedDescription)"; stop() }
    }

    var isPlaying: Bool { queuedSeconds > 0.05 }
    func stop() {
        epoch = UUID(); player?.stop(); engine?.stop(); player = nil; engine = nil; queuedSeconds = 0
    }
}
