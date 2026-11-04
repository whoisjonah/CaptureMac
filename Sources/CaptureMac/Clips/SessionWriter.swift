@preconcurrency import AVFoundation
import Foundation

final class SessionWriter: @unchecked Sendable {
    struct Source {
        let role: AudioRole
        let ring: AudioRing
        let gain: Float
        let resampler: Resampler
    }

    let url: URL

    private let writer: AVAssetWriter
    private let layout: TrackLayout
    private let sources: [Source]
    private let audioBitrate: Int
    private let queue = DispatchQueue(label: "capturemac.session", qos: .userInitiated)
    private var videoInput: AVAssetWriterInput?
    private var audioInputs: [AVAssetWriterInput] = []
    private var start: CMTime?
    private var audioCursor = 0.0
    private var audioFrames = 0
    private var lastVideoTime = 0.0
    private var timer: DispatchSourceTimer?
    private var dimensions = CMVideoDimensions(width: 0, height: 0)

    init(url: URL, sources: [(AudioRole, AudioRing, Float)], layout: TrackLayout, audioBitrate: Int) throws {
        self.url = url
        self.layout = layout
        self.audioBitrate = audioBitrate
        self.sources = sources.map { Source(role: $0.0, ring: $0.1, gain: $0.2, resampler: Resampler(from: $0.1.sampleRate)) }
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
    }

    var trackNames: [String] {
        Recorder.tracks(from: sources.map { ($0.role, []) }, layout: layout).map(\.name)
    }

    var size: CMVideoDimensions {
        queue.sync { dimensions }
    }

    func append(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            if start == nil {
                guard Self.isKeyframe(sample), begin(with: sample) else { return }
            }
            guard let videoInput, writer.status == .writing else { return }
            var attempts = 0
            while !videoInput.isReadyForMoreMediaData && attempts < 20 {
                usleep(2000)
                attempts += 1
            }
            if videoInput.isReadyForMoreMediaData, videoInput.append(sample) {
                lastVideoTime = sample.presentationTimeStamp.seconds
            }
        }
    }

    func finish() async -> Double? {
        let duration: Double? = queue.sync {
            timer?.cancel()
            timer = nil
            guard let start, writer.status == .writing else { return nil }
            flushAudio(until: lastVideoTime + 1.0 / 60)
            videoInput?.markAsFinished()
            audioInputs.forEach { $0.markAsFinished() }
            writer.endSession(atSourceTime: CMTime(seconds: lastVideoTime + 1.0 / 60, preferredTimescale: 90_000))
            return lastVideoTime - start.seconds
        }
        guard let duration else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        await writer.finishWriting()
        return writer.status == .completed ? duration : nil
    }

    private func begin(with sample: CMSampleBuffer) -> Bool {
        guard let format = sample.formatDescription else { return false }
        dimensions = format.dimensions

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: PCM.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: audioBitrate * 1000,
        ]
        let enabled = Recorder.tracks(from: sources.map { ($0.role, []) }, layout: layout).map(\.enabled)
        audioInputs = enabled.map { isEnabled in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: PCM.format.formatDescription)
            input.expectsMediaDataInRealTime = true
            input.marksOutputTrackAsEnabled = isEnabled
            writer.add(input)
            return input
        }

        guard writer.startWriting() else { return false }
        let time = sample.presentationTimeStamp
        writer.startSession(atSourceTime: time)
        start = time
        videoInput = video
        audioCursor = time.seconds

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.flushAudio(until: HostClock.now - 0.3)
        }
        timer.resume()
        self.timer = timer
        return true
    }

    private func flushAudio(until end: Double) {
        guard let start, !audioInputs.isEmpty, end > audioCursor else { return }
        let target = Int(((end - start.seconds) * PCM.sampleRate).rounded())
        let frames = target - audioFrames
        guard frames > 0 else { return }

        let decoded = sources.map { source in
            source.resampler.push(source.ring.read(from: audioCursor, to: end))
            return (source.role, PCM.scaled(source.resampler.take(frames), by: source.gain))
        }
        let tracks = Recorder.tracks(from: decoded, layout: layout)
        let time = CMTimeAdd(start, CMTime(value: CMTimeValue(audioFrames), timescale: CMTimeScale(PCM.sampleRate)))

        for (track, input) in zip(tracks, audioInputs) {
            var chunks = AudioChunks(samples: track.samples, start: time, format: PCM.format.formatDescription)
            while let chunk = chunks.next() {
                var attempts = 0
                while !input.isReadyForMoreMediaData && attempts < 50 {
                    usleep(2000)
                    attempts += 1
                }
                input.append(chunk)
            }
        }
        audioFrames = target
        audioCursor = end
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        return !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
}
