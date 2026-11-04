@preconcurrency import AVFoundation
import CoreMedia
import Foundation

struct AudioTrack {
    var name: String
    var samples: [Float]
    var enabled: Bool
}

struct ClipWriterError: LocalizedError {
    let errorDescription: String?
}

enum ClipWriter {
    static func write(video: [VideoRing.Frame], end: Double, audio: [AudioTrack], audioBitrate: Int, to url: URL)
        async throws
    {
        guard let first = video.first, let hint = first.sample.formatDescription else {
            throw ClipWriterError(errorDescription: "nothing to save yet")
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: PCM.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: audioBitrate * 1000,
        ]
        let audioFormat = PCM.format.formatDescription
        let audioInputs = audio.map { track in
            let input = AVAssetWriterInput(
                mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = track.enabled
            writer.add(input)
            return input
        }

        guard writer.startWriting() else {
            throw writer.error ?? ClipWriterError(errorDescription: "couldn't make the clip file, disk full?")
        }
        let startTime = first.sample.presentationTimeStamp
        writer.startSession(atSourceTime: startTime)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = video.makeIterator()
                await pump(videoInput, label: "video") { iterator.next()?.sample }
            }
            for (track, input) in zip(audio, audioInputs) {
                group.addTask {
                    var chunks = AudioChunks(samples: track.samples, start: startTime, format: audioFormat)
                    await pump(input, label: "audio") { chunks.next() }
                }
            }
        }

        writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 90_000))
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? ClipWriterError(errorDescription: "clip broke right at the end, sorry")
        }
    }

    static func pump(_ input: AVAssetWriterInput, label: String, next: @escaping () -> CMSampleBuffer?) async {
        let queue = DispatchQueue(label: "capturemac.writer.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = next(), input.append(sample) else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}

struct AudioChunks {
    let samples: [Float]
    let start: CMTime
    let format: CMAudioFormatDescription
    var offset = 0

    static let framesPerChunk = 4096

    init(samples: [Float], start: CMTime, format: CMAudioFormatDescription) {
        self.samples = samples
        self.start = start
        self.format = format
    }

    mutating func next() -> CMSampleBuffer? {
        let totalFrames = samples.count / 2
        guard offset < totalFrames else { return nil }
        let frames = min(Self.framesPerChunk, totalFrames - offset)
        let time = CMTimeAdd(start, CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(PCM.sampleRate)))
        let sample: CMSampleBuffer? = samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return Self.makeSample(baseAddress + offset * 2, frames: frames, time: time, format: format)
        }
        offset += frames
        return sample
    }

    static func makeSample(_ data: UnsafePointer<Float>, frames: Int, time: CMTime, format: CMAudioFormatDescription)
        -> CMSampleBuffer?
    {
        let length = frames * 2 * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block
            ) == noErr, let block
        else { return nil }
        guard
            CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
                == noErr
        else { return nil }

        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample
        )
        return sample
    }
}
