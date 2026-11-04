import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import CaptureMac

struct PipelineTests {
    private func pixelBuffer(shade: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
            let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane)
            memset(base, Int32(plane == 0 ? shade : 128), bytes)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    private func noise(seed: Int) -> CVPixelBuffer {
        let pixels = pixelBuffer(shade: 0)
        CVPixelBufferLockBaseAddress(pixels, [])
        var generator = SystemRandomNumberGenerator()
        for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
            let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane)!.assumingMemoryBound(to: UInt64.self)
            let words = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane) / 8
            for index in 0..<words { base[index] = generator.next() &+ UInt64(seed) }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    private func encodedBytes(_ frame: (Int) -> CVPixelBuffer) throws -> (bytes: Int, constantQuality: Bool) {
        let ring = VideoRing(seconds: 10)
        let encoder = try VideoEncoder(width: 1280, height: 720, codec: .h264, bitrate: 60_000_000, quality: 0.7, frameRate: 30) { ring.append($0) }
        for index in 0..<30 {
            encoder.encode(frame(index), at: CMTime(seconds: Double(index) / 30, preferredTimescale: 90_000))
        }
        let constantQuality = encoder.usesConstantQuality
        encoder.invalidate()
        return (ring.bytes, constantQuality)
    }

    @Test func bitrateFollowsTheContent() throws {
        let still = pixelBuffer(shade: 90)
        let calm = try encodedBytes { _ in still }
        let busy = try encodedBytes { noise(seed: $0) }
        print("constant quality: \(calm.constantQuality), still: \(calm.bytes) bytes, busy: \(busy.bytes) bytes")
        #expect(busy.bytes > calm.bytes * 10)
    }

    private func tone(_ frequency: Double, seconds: Double) -> [Float] {
        let frames = Int(seconds * PCM.sampleRate)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(sin(2 * .pi * frequency * Double(frame) / PCM.sampleRate) * 0.3)
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return samples
    }

    private func makeClip() async throws -> URL {
        let ring = VideoRing(seconds: 10)
        let encoder = try VideoEncoder(width: 1280, height: 720, codec: .h264, bitrate: 6_000_000, frameRate: 30) { ring.append($0) }
        let start = 1000.0
        for index in 0..<90 {
            let time = CMTime(seconds: start + Double(index) / 30, preferredTimescale: 90_000)
            encoder.encode(pixelBuffer(shade: UInt8(16 + index * 2)), at: time)
        }
        encoder.invalidate()

        let frames = ring.frames(from: start, to: start + 3)
        #expect(frames.count == 90)
        #expect(frames.first?.isKeyframe == true)

        let sources: [(AudioRole, [Float])] = [(.game, tone(440, seconds: 3)), (.microphone, tone(220, seconds: 3))]
        let tracks = Recorder.tracks(from: sources, layout: .mixedAndSeparate)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capturemac-\(UUID().uuidString).mp4")
        try await ClipWriter.write(video: frames, end: start + 3, audio: tracks, audioBitrate: 192, to: url)
        return url
    }

    @Test func writesPlayableClipWithAllTracks() async throws {
        let url = try await makeClip()
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)

        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == 3)
        let enabled = try await audio.asyncMap { try await $0.load(.isEnabled) }
        #expect(enabled == [true, false, false])
    }

    @Test func shrinksToTargetSize() async throws {
        let url = try await makeClip()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("capturemac-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: output)
        }

        let original = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int64
        try await Exporter.export(url, preset: .quality(.p480), volumes: [0, 1, 0], to: output)

        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video).first!
        let size = try await video.load(.naturalSize)
        #expect(size.height == 480)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)

        let exported = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as! Int64
        #expect(exported < original)
    }

    @Test func trimsToRange() async throws {
        let url = try await makeClip()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("capturemac-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: output)
        }

        try await Exporter.export(url, ranges: [TrimRange(start: 1, end: 2).range], preset: .quality(.p720), to: output)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1) < 0.1)
    }

    @Test func cutsChunksOut() async throws {
        let url = try await makeClip()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("capturemac-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: output)
        }

        let kept = [TrimRange(start: 0, end: 1).range, TrimRange(start: 2, end: 3).range]
        try await Exporter.export(url, ranges: kept, preset: .original, to: output)
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func sessionStreamsToDisk() async throws {
        let game = AudioRing(sampleRate: 44_100, seconds: 10)
        let microphone = AudioRing(sampleRate: 48_000, seconds: 10)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capturemac-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try SessionWriter(url: url, sources: [(.game, game, 1), (.microphone, microphone, 1)], layout: .mixedAndSeparate, audioBitrate: 160)
        let encoder = try VideoEncoder(width: 1280, height: 720, codec: .h264, bitrate: 4_000_000, frameRate: 30) { writer.append($0) }
        let gameBlock = [Float](repeating: 0.2, count: 1470 * 2)
        let micBlock = [Float](repeating: 0.1, count: 1600 * 2)

        let start = HostClock.now
        for index in 0..<60 {
            let time = start + Double(index) / 30
            encoder.encode(pixelBuffer(shade: UInt8(20 + index)), at: CMTime(seconds: time, preferredTimescale: 90_000))
            gameBlock.withUnsafeBufferPointer { game.write($0.baseAddress!, frames: 1470, time: time) }
            micBlock.withUnsafeBufferPointer { microphone.write($0.baseAddress!, frames: 1600, time: time) }
            try await Task.sleep(for: .milliseconds(33))
        }
        encoder.invalidate()
        try await Task.sleep(for: .milliseconds(100))

        let duration = try #require(await writer.finish())
        #expect(abs(duration - 2) < 0.2)
        #expect(writer.trackNames == ["Mixed", "Game", "Microphone"])

        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == 3)
        let audioDuration = try await audio[0].load(.timeRange).duration.seconds
        #expect(abs(audioDuration - duration) < 0.2)
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}
