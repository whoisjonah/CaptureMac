import AVFoundation
import Foundation

enum PCM {
    static let sampleRate = 48_000.0

    static let format: AVAudioFormat = {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true)
        else {
            preconditionFailure("the standard audio format isn't available")
        }
        return format
    }()

    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != sampleRate, !samples.isEmpty else { return samples }
        guard
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true),
            let converter = AVAudioConverter(from: source, to: format)
        else { return samples }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let inputFrames = samples.count / 2
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(inputFrames)) else {
            return samples
        }
        input.frameLength = AVAudioFrameCount(inputFrames)
        guard let inputData = input.floatChannelData?.pointee else { return samples }
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            inputData.update(from: baseAddress, count: samples.count)
        }

        let outputFrames = AVAudioFrameCount(Double(inputFrames) * sampleRate / rate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrames) else { return samples }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil else { return samples }
        guard let outputData = output.floatChannelData?.pointee else { return samples }
        return Array(UnsafeBufferPointer(start: outputData, count: Int(output.frameLength) * 2))
    }

    static func scaled(_ samples: [Float], by gain: Float) -> [Float] {
        gain == 1 ? samples : samples.map { $0 * gain }
    }

    static func mix(_ tracks: [[Float]]) -> [Float] {
        guard let longest = tracks.map(\.count).max() else { return [] }
        var output = [Float](repeating: 0, count: longest)
        for track in tracks {
            for index in track.indices {
                output[index] += track[index]
            }
        }
        for index in output.indices {
            output[index] = min(max(output[index], -1), 1)
        }
        return output
    }

    static func fit(_ samples: [Float], frames: Int) -> [Float] {
        let count = frames * 2
        if samples.count == count { return samples }
        if samples.count > count { return Array(samples.prefix(count)) }
        return samples + [Float](repeating: 0, count: count - samples.count)
    }
}

final class Resampler {
    private let converter: AVAudioConverter?
    private let source: AVAudioFormat?
    private var pending: [Float] = []

    init(from rate: Double) {
        if rate == PCM.sampleRate {
            source = nil
            converter = nil
        } else {
            source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)
            converter = source.flatMap { AVAudioConverter(from: $0, to: PCM.format) }
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
    }

    func push(_ samples: [Float]) {
        guard let converter, let source else {
            pending += samples
            return
        }
        let frames = samples.count / 2
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        input.frameLength = AVAudioFrameCount(frames)
        guard let inputData = input.floatChannelData?.pointee else { return }
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            inputData.update(from: baseAddress, count: samples.count)
        }

        let capacity = AVAudioFrameCount(Double(frames) * PCM.sampleRate / source.sampleRate) + 2048
        guard let output = AVAudioPCMBuffer(pcmFormat: PCM.format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard let outputData = output.floatChannelData?.pointee else { return }
        pending += UnsafeBufferPointer(start: outputData, count: Int(output.frameLength) * 2)
    }

    func take(_ frames: Int) -> [Float] {
        let count = frames * 2
        if pending.count >= count {
            let chunk = Array(pending.prefix(count))
            pending.removeFirst(count)
            return chunk
        }
        let chunk = pending + [Float](repeating: 0, count: count - pending.count)
        pending.removeAll()
        return chunk
    }
}
