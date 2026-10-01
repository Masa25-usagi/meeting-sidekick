import AppKit
import AVFoundation
import Combine
import CoreImage
import MeetingCore
import ScreenCaptureKit

struct CaptureApplication: Identifiable, Hashable {
    let id: Int32
    let name: String
    let bundleIdentifier: String?
}

enum CaptureFailure: LocalizedError {
    case microphonePermission, applicationUnavailable, noWindow, noInput, invalidAudio
    var errorDescription: String? {
        switch self {
        case .microphonePermission: return "マイクの使用が許可されていません。システム設定のプライバシーとセキュリティで許可してください。"
        case .applicationUnavailable: return "選択したアプリが見つかりません。会議を開いてから選び直してください。"
        case .noWindow: return "選択したアプリに取得できるウィンドウがありません。会議ウィンドウを画面に表示してください。"
        case .noInput: return "入力を選択してください。マイクのみの場合はマイクを有効にしてください。"
        case .invalidAudio: return "マイクの音声形式を取得できません。入力デバイスを確認してください。"
        }
    }
}

/// Captures only after the user explicitly starts a session. Listing apps never asks
/// for Screen Recording permission and never reads window or audio content.
@MainActor
final class CaptureService: ObservableObject {
    @Published private(set) var applications: [CaptureApplication] = []
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var level: Float = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var meetingLevel: Float = 0
    /// PCM arrival, including silence; a moving meter separately indicates signal.
    @Published private(set) var lastMicrophoneAudioAt: Date?
    @Published private(set) var lastMeetingAudioAt: Date?
    var onAudio: ((Data, AudioSource) -> Void)?
    var onFrame: ((Data) -> Void)?
    var onSpeechActivity: ((AudioSource) -> Void)?

    private var stream: SCStream?
    private var microphoneEngine: AVAudioEngine?
    private var receiver: CaptureReceiver?
    private var generation = UUID()
    private var meterTask: Task<Void, Never>?
    private let sampleQueue = DispatchQueue(label: "meeting.capture.samples", qos: .userInitiated)

    func refreshApplications() async {
        applications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .map { CaptureApplication(id: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "アプリ", bundleIdentifier: $0.bundleIdentifier) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start(applicationID: Int32?, includeMicrophone: Bool, includeScreen: Bool) async throws {
        await stop()
        errorMessage = nil
        let token = UUID()
        generation = token
        do {
            guard applicationID != nil || includeMicrophone else { throw CaptureFailure.noInput }
            if includeMicrophone {
                let permitted = await AVCaptureDevice.requestAccess(for: .audio)
                guard permitted else { throw CaptureFailure.microphonePermission }
            }
            guard generation == token else { throw CancellationError() }
            let receiver = CaptureReceiver(includeScreen: includeScreen && applicationID != nil)
            receiver.deliver = { [weak self] batch in
                guard let self, self.generation == token, self.isRunning else { return }
                if let value = batch.microphoneLevel {
                    self.microphoneLevel = value
                    self.lastMicrophoneAudioAt = batch.microphoneArrivedAt
                }
                if let value = batch.meetingLevel {
                    self.meetingLevel = value
                    self.lastMeetingAudioAt = batch.meetingArrivedAt
                }
                self.level = max(self.microphoneLevel, self.meetingLevel)
                for (data, source) in batch.audio { self.onAudio?(data, source) }
                for source in batch.activity { self.onSpeechActivity?(source) }
                if let frame = batch.frame { self.onFrame?(frame) }
                if let error = batch.error {
                    self.errorMessage = error
                    self.isRunning = false
                    self.microphoneLevel = 0
                    self.meetingLevel = 0
                    self.level = 0
                    Task { [weak self] in
                        guard let self, self.generation == token else { return }
                        await self.stop()
                    }
                }
            }
            self.receiver = receiver
            if let applicationID {
                // This is the first ScreenCaptureKit call and can prompt for OS consent.
                // The connection sheet may cover the browser, or it may be on
                // another Space. Visibility must not invalidate the app selection.
                let selected = applications.first { $0.id == applicationID }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard generation == token else { throw CancellationError() }
                let candidates = content.applications.filter {
                    if let identifier = selected?.bundleIdentifier { return $0.bundleIdentifier == identifier }
                    return $0.processID == applicationID
                }
                // A browser restart changes its PID. Only resolve by bundle ID
                // when unique; never fall back to capturing another application.
                guard let app = candidates.first(where: { $0.processID == applicationID })
                        ?? (candidates.count == 1 ? candidates.first : nil) else {
                    if NSWorkspace.shared.runningApplications.contains(where: { $0.processIdentifier == applicationID }) {
                        throw CaptureFailure.noWindow
                    }
                    throw CaptureFailure.applicationUnavailable
                }
                let windows = content.windows.filter {
                    $0.owningApplication?.processID == app.processID && $0.frame.width > 100 && $0.frame.height > 100
                }
                guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                    throw CaptureFailure.noWindow
                }
                // Window filtering selects video; SCK audio remains application-wide.
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 16_000
                configuration.channelCount = 1
                configuration.captureMicrophone = includeMicrophone
                configuration.showsCursor = false
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.queueDepth = 3
                let scale = min(1, 1280 / max(window.frame.width, window.frame.height))
                configuration.width = includeScreen ? max(2, Int(window.frame.width * scale)) : 2
                configuration.height = includeScreen ? max(2, Int(window.frame.height * scale)) : 2
                let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
                try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: sampleQueue)
                if includeMicrophone {
                    try stream.addStreamOutput(receiver, type: .microphone, sampleHandlerQueue: sampleQueue)
                }
                if includeScreen {
                    try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: sampleQueue)
                }
                self.stream = stream
                try await stream.startCapture()
                guard generation == token else {
                    try? await stream.stopCapture()
                    throw CancellationError()
                }
                _ = app // Ensures the selected PID is still represented by SCK.
            } else {
                // Mic-only mode does not create an SCStream or request screen access.
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureFailure.invalidAudio }
                input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak receiver] buffer, _ in
                    receiver?.processMicrophone(buffer)
                }
                self.microphoneEngine = engine
                engine.prepare()
                try engine.start()
            }
            isRunning = true
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, !Task.isCancelled, self.generation == token, self.isRunning else { return }
                    let now = Date()
                    if now.timeIntervalSince(self.lastMicrophoneAudioAt ?? .distantPast) > 0.5 { self.microphoneLevel = 0 }
                    if now.timeIntervalSince(self.lastMeetingAudioAt ?? .distantPast) > 0.5 { self.meetingLevel = 0 }
                    self.level = max(self.microphoneLevel, self.meetingLevel)
                }
            }
        } catch {
            if generation == token {
                await stop()
                errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func stop() async {
        generation = UUID()
        isRunning = false
        meterTask?.cancel()
        meterTask = nil
        level = 0
        microphoneLevel = 0
        meetingLevel = 0
        lastMicrophoneAudioAt = nil
        lastMeetingAudioAt = nil
        receiver?.deactivate()
        if let engine = microphoneEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        microphoneEngine = nil
        let previousStream = stream
        stream = nil
        if let previousStream { try? await previousStream.stopCapture() }
        receiver = nil
    }
}

private struct CaptureBatch {
    var audio: [(Data, AudioSource)] = []
    var activity: [AudioSource] = []
    var frame: Data?
    var microphoneLevel: Float?
    var meetingLevel: Float?
    var microphoneArrivedAt: Date?
    var meetingArrivedAt: Date?
    var error: String?
}

/// A bounded mailbox uses one main-queue delivery at a time, rather than creating
/// a Task for every audio buffer. Audio conversion runs on the capture callback.
private final class CaptureReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    var deliver: ((CaptureBatch) -> Void)?
    private let includeScreen: Bool
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var active = true
    private var deliveryScheduled = false
    private var batch = CaptureBatch()
    private var converters: [String: PCM16Converter] = [:]
    private var pending: [String: Data] = [:]
    private var lastActivity: [String: TimeInterval] = [:]
    private var lastFrame: TimeInterval = 0

    init(includeScreen: Bool) { self.includeScreen = includeScreen }
    func deactivate() { lock.lock(); active = false; batch = CaptureBatch(); lock.unlock() }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        publish { $0.error = "音声取得が停止しました: \(error.localizedDescription)" }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio, .microphone:
            guard sampleBuffer.numSamples > 0,
                  let description = sampleBuffer.formatDescription,
                  let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { return }
            buffer.frameLength = buffer.frameCapacity
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList) == noErr else { return }
            process(buffer, source: type == .microphone ? .microphone : .meeting)
        case .screen:
            guard includeScreen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let now = Date.timeIntervalSinceReferenceDate
            guard now - lastFrame >= 0.95 else { return }
            lastFrame = now
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let factor = min(1, 1280 / max(image.extent.width, image.extent.height))
            let resized = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            guard let jpeg = context.jpegRepresentation(of: resized, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.65]) else { return }
            publish { $0.frame = jpeg }
        @unknown default: break
        }
    }

    func processMicrophone(_ buffer: AVAudioPCMBuffer) { process(buffer, source: .microphone) }

    private func process(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        lock.lock(); let enabled = active; lock.unlock()
        guard enabled else { return }
        let key = source == .microphone ? "microphone" : "meeting"
        if converters[key] == nil { converters[key] = PCM16Converter() }
        guard let data = converters[key]?.convert(buffer), !data.isEmpty else { return }
        let rms: Float = data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            guard !values.isEmpty else { return 0 }
            let energy = values.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) }
            return Float(sqrt(energy / Double(values.count)))
        }
        pending[key, default: Data()].append(data)
        let now = Date.timeIntervalSinceReferenceDate
        let activity = rms > 0.015 && now - (lastActivity[key] ?? 0) > 0.25
        if activity { lastActivity[key] = now }
        // Emit at least 100 ms at a time to keep downstream call volume bounded.
        if (pending[key]?.count ?? 0) >= 3_200 {
            let chunk = pending.removeValue(forKey: key) ?? Data()
            publish {
                // At most roughly two seconds of pending buffers per input.
                if $0.audio.count >= 40 { $0.audio.removeFirst() }
                $0.audio.append((chunk, source))
                recordMeter(in: &$0, source: source, rms: rms)
                if activity, !$0.activity.contains(source) { $0.activity.append(source) }
            }
        } else if activity {
            publish {
                if !$0.activity.contains(source) { $0.activity.append(source) }
                recordMeter(in: &$0, source: source, rms: rms)
            }
        }
    }

    private func recordMeter(in value: inout CaptureBatch, source: AudioSource, rms: Float) {
        if source == .microphone {
            value.microphoneLevel = min(1, rms * 8)
            value.microphoneArrivedAt = Date()
        } else {
            value.meetingLevel = min(1, rms * 8)
            value.meetingArrivedAt = Date()
        }
    }

    private func publish(_ update: (inout CaptureBatch) -> Void) {
        lock.lock()
        guard active else { lock.unlock(); return }
        update(&batch)
        let needsDelivery = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        guard needsDelivery else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let value = self.batch
            self.batch = CaptureBatch()
            self.deliveryScheduled = false
            let enabled = self.active
            self.lock.unlock()
            if enabled { self.deliver?(value) }
        }
    }
}

private final class PCM16Converter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var provided = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = output.int16ChannelData?.pointee else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}
