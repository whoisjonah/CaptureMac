@preconcurrency import AVFoundation
import Foundation

enum QualityPreset: String, Codable, CaseIterable, Identifiable {
    case p1080, p720, p480

    var id: String { rawValue }

    var title: String {
        switch self {
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    var height: Int {
        switch self {
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }

    var bitrate: Int {
        switch self {
        case .p1080: 8_000_000
        case .p720: 4_500_000
        case .p480: 2_000_000
        }
    }
}

enum ExportPreset: Codable, Hashable {
    case original
    case quality(QualityPreset)
    case targetSize(Int)

    static let sizes = [10, 25, 50, 100]

    var title: String {
        switch self {
        case .original: "Original"
        case .quality(let preset): preset.title
        case .targetSize(let megabytes): "Under \(megabytes) MB"
        }
    }
}

struct ExportPlan: Equatable {
    var passthrough: Bool
    var width: Int
    var height: Int
    var videoBitrate: Int
    var audioBitrate: Int
    var frameRate: Double

    static func make(
        preset: ExportPreset, duration: Double, width: Int, height: Int,
        frameRate: Double, sourceBitrate: Int, audioChanged: Bool
    ) -> ExportPlan {
        let source = ExportPlan(passthrough: true, width: width, height: height, videoBitrate: sourceBitrate, audioBitrate: 192_000, frameRate: frameRate)

        switch preset {
        case .original:
            guard audioChanged else { return source }
            return ExportPlan(passthrough: false, width: width, height: height, videoBitrate: max(sourceBitrate, 4_000_000), audioBitrate: 192_000, frameRate: frameRate)

        case .quality(let quality):
            let size = scaled(width: width, height: height, toShortSide: quality.height)
            return ExportPlan(passthrough: false, width: size.width, height: size.height, videoBitrate: min(quality.bitrate, max(sourceBitrate, 1_000_000)), audioBitrate: 160_000, frameRate: frameRate)

        case .targetSize(let megabytes):
            let budget = Double(megabytes) * 1_000_000 * 8 * 0.94
            if !audioChanged, Double(sourceBitrate) * duration <= budget {
                return source
            }
            let perSecond = budget / max(duration, 0.5)
            let audio = perSecond > 1_200_000 ? 128_000 : 64_000
            let video = max(150_000, Int(perSecond) - audio)
            let shortSide = video >= 5_000_000 ? 1080 : video >= 2_500_000 ? 720 : video >= 1_000_000 ? 540 : 360
            let size = scaled(width: width, height: height, toShortSide: shortSide)
            let fps = video < 2_000_000 ? min(frameRate, 30) : frameRate
            return ExportPlan(passthrough: false, width: size.width, height: size.height, videoBitrate: video, audioBitrate: audio, frameRate: fps)
        }
    }

    static func scaled(width: Int, height: Int, toShortSide target: Int) -> (width: Int, height: Int) {
        let short = min(width, height)
        guard short > target else { return (width & ~1, height & ~1) }
        let scale = Double(target) / Double(short)
        return (Int((Double(width) * scale).rounded()) & ~1, Int((Double(height) * scale).rounded()) & ~1)
    }

    func estimatedBytes(duration: Double) -> Int64 {
        Int64(Double(videoBitrate + audioBitrate) * duration / 8)
    }
}

struct SourceInfo {
    var duration: Double
    var width: Int
    var height: Int
    var frameRate: Double
    var bitrate: Int

    static func load(_ url: URL) async throws -> SourceInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipWriterError(errorDescription: "no video in this clip??")
        }
        let (size, rate) = try await track.load(.naturalSize, .nominalFrameRate)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return SourceInfo(
            duration: duration, width: Int(size.width), height: Int(size.height),
            frameRate: Double(rate > 0 ? rate : 60), bitrate: Int(Double(bytes) * 8 / max(duration, 0.1))
        )
    }
}

enum Exporter {
    static func export(
        _ source: URL, ranges: [CMTimeRange]? = nil, preset: ExportPreset, volumes: [Float]? = nil,
        to output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let info = try await SourceInfo.load(source)
        let asset: AVAsset
        let range: CMTimeRange
        if let ranges, ranges.count > 1 {
            asset = try await composition(of: AVURLAsset(url: source), ranges: ranges)
            range = CMTimeRange(start: .zero, duration: ranges.reduce(.zero) { CMTimeAdd($0, $1.duration) })
        } else {
            asset = AVURLAsset(url: source)
            range = ranges?.first ?? CMTimeRange(start: .zero, duration: CMTime(seconds: info.duration, preferredTimescale: 600))
        }
        let plan = ExportPlan.make(
            preset: preset, duration: range.duration.seconds, width: info.width, height: info.height,
            frameRate: info.frameRate, sourceBitrate: info.bitrate, audioChanged: volumes != nil || (ranges?.count ?? 1) > 1
        )
        try? FileManager.default.removeItem(at: output)

        if plan.passthrough {
            try await passthrough(asset, range: range, to: output)
            progress(1)
            return
        }

        try await transcode(asset, range: range, plan: plan, volumes: volumes, to: output, progress: progress)

        if case .targetSize(let megabytes) = preset {
            let limit = Double(megabytes) * 1_000_000
            let actual = Double((try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0)
            if actual > limit {
                var retry = plan
                retry.videoBitrate = max(120_000, Int(Double(plan.videoBitrate) * limit / actual * 0.9))
                try? FileManager.default.removeItem(at: output)
                try await transcode(asset, range: range, plan: retry, volumes: volumes, to: output, progress: progress)
            }
        }
    }

    private static func composition(of source: AVURLAsset, ranges: [CMTimeRange]) async throws -> AVAsset {
        let composition = AVMutableComposition()
        for track in try await source.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let target = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var cursor = CMTime.zero
            for range in ranges {
                try target.insertTimeRange(range, of: track, at: cursor)
                cursor = CMTimeAdd(cursor, range.duration)
            }
            target.isEnabled = try await track.load(.isEnabled)
            if track.mediaType == .video {
                target.preferredTransform = try await track.load(.preferredTransform)
            }
        }
        return composition
    }

    private static func passthrough(_ asset: AVAsset, range: CMTimeRange, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ClipWriterError(errorDescription: "export wouldn't start")
        }
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: output, as: .mp4)
    }

    private static func transcode(
        _ asset: AVAsset, range: CMTimeRange, plan: ExportPlan, volumes: [Float]?,
        to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipWriterError(errorDescription: "no video in this clip??")
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let audioOutput = try await audioMixOutput(for: asset, volumes: volumes)
        if let audioOutput { reader.add(audioOutput) }

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoExpectedSourceFrameRateKey: Int(plan.frameRate),
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: PCM.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: plan.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else {
            throw reader.error ?? ClipWriterError(errorDescription: "couldn't read the clip, did it move?")
        }
        guard writer.startWriting() else {
            throw writer.error ?? ClipWriterError(errorDescription: "couldn't make the export file")
        }
        writer.startSession(atSourceTime: range.start)

        let start = range.start.seconds
        let duration = max(range.duration.seconds, 0.01)
        let spacing = 1 / plan.frameRate * 0.98

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var lastKept = -Double.infinity
                await ClipWriter.pump(videoInput, label: "video") {
                    while let sample = videoOutput.copyNextSampleBuffer() {
                        let time = sample.presentationTimeStamp.seconds
                        guard time - lastKept >= spacing else { continue }
                        lastKept = time
                        progress(min(1, (time - start) / duration))
                        return sample
                    }
                    return nil
                }
            }
            if let audioOutput, let audioInput {
                group.addTask {
                    await ClipWriter.pump(audioInput, label: "audio") { audioOutput.copyNextSampleBuffer() }
                }
            }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? ClipWriterError(errorDescription: "couldn't read the clip, did it move?")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ClipWriterError(errorDescription: "export died at the end, try again")
        }
        progress(1)
    }

    private static func audioMixOutput(for asset: AVAsset, volumes: [Float]?) async throws -> AVAssetReaderAudioMixOutput? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }

        var chosen: [(AVAssetTrack, Float)] = []
        if let volumes, volumes.count == tracks.count {
            chosen = zip(tracks, volumes).filter { $0.1 > 0 }
        } else {
            for track in tracks where (try? await track.load(.isEnabled)) == true {
                chosen.append((track, 1))
            }
            if chosen.isEmpty { chosen = [(tracks[0], 1)] }
        }
        guard !chosen.isEmpty else { return nil }

        let output = AVAssetReaderAudioMixOutput(audioTracks: chosen.map(\.0), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: PCM.sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        let mix = AVMutableAudioMix()
        mix.inputParameters = chosen.map { track, volume in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(volume, at: .zero)
            return parameters
        }
        output.audioMix = mix
        return output
    }
}
