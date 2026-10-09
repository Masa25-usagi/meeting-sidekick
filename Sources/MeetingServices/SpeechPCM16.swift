import Foundation
import AVFoundation

public enum SpeechPCM16 {
    public static let sampleRate: Double = 16_000
    public static let bytesPerSecond = 32_000
    public static func buffer(_ data: Data) -> AVAudioPCMBuffer? {
        guard !data.isEmpty, data.count.isMultiple(of: 2),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.int16ChannelData?.pointee else { return nil }
        buffer.frameLength = buffer.frameCapacity
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: data.count))
        return buffer
    }

    /// A short voiced interval must not disappear when averaged with a quiet capture chunk.
    public static func containsSpeech(_ data: Data, continuing: Bool = false) -> Bool {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else { return false }
        let threshold = continuing ? 0.004 : 0.006
        return data.withUnsafeBytes { raw in
            let count = data.count / 2
            for start in stride(from: 0, to: count, by: 320) {
                let end = min(start + 320, count)
                var energy = 0.0
                for index in start..<end {
                    let value = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
                    energy += value * value
                }
                if sqrt(energy / Double(end - start)) > threshold { return true }
            }
            return false
        }
    }
}

public struct PCM16Window {
    public private(set) var data = Data()
    private let capacity: Int
    public init(seconds: Double) {
        capacity = Int(max(0, min(seconds.isFinite ? seconds : 0, 4)) * Double(SpeechPCM16.bytesPerSecond)) / 2 * 2
    }
    @discardableResult public mutating func append(_ incoming: Data) -> Int {
        guard incoming.count.isMultiple(of: 2) else { return 0 }
        data.append(incoming)
        let dropped = max(0, data.count - capacity)
        if dropped > 0 { data.removeFirst(dropped) }
        return dropped
    }
}

/// One streaming converter per source. Explicit downmix retains a right-only stereo microphone.
public final class PCM16Converter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    public init() {}
    public func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return nil }
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if provided { inputStatus.pointee = .noDataNow; return nil }
            provided = true; inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let samples = output.int16ChannelData?.pointee else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}
