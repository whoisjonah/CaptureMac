import Testing
@testable import CaptureMac

struct AudioRingTests {
    private func block(_ value: Float, frames: Int) -> [Float] {
        [Float](repeating: value, count: frames * 2)
    }

    @Test func jitterDoesNotCreateGaps() {
        let ring = AudioRing(sampleRate: 48_000, seconds: 10)
        let frames = 480
        var time = 100.0
        for index in 0..<1000 {
            let jitter = index.isMultiple(of: 2) ? 0.002 : -0.002
            block(1, frames: frames).withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames, time: time + jitter) }
            time += Double(frames) / 48_000
        }
        let samples = ring.read(from: 101, to: 105)
        #expect(samples.count == 4 * 48_000 * 2)
        #expect(samples.allSatisfy { $0 == 1 })
    }

    @Test func realGapIsSilentAndLaterAudioStaysAligned() {
        let ring = AudioRing(sampleRate: 48_000, seconds: 10)
        let frames = 4800
        for index in 0..<10 {
            block(1, frames: frames).withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames, time: 10 + Double(index) * 0.1) }
        }
        for index in 0..<10 {
            block(2, frames: frames).withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames, time: 13 + Double(index) * 0.1) }
        }

        let before = ring.read(from: 10.5, to: 10.9)
        #expect(before.allSatisfy { $0 == 1 })
        let gap = ring.read(from: 11.5, to: 12.5)
        #expect(gap.allSatisfy { $0 == 0 })
        let after = ring.read(from: 13.0, to: 13.9)
        #expect(after.allSatisfy { $0 == 2 })
    }

    @Test func clockDriftStaysContinuousAndMapped() {
        let ring = AudioRing(sampleRate: 48_000, seconds: 120)
        let frames = 512
        let deviceRate = 48_000 * 1.0002
        var time = 0.0
        var written = 0
        while time < 90 {
            let value = Float(written / 48_000)
            block(value, frames: frames).withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames, time: time) }
            written += frames
            time = Double(written) / deviceRate
        }
        let position = ring.position(at: 80)!
        let expected = Int(80 * deviceRate)
        #expect(abs(position - expected) < 600)

        let samples = ring.read(from: 60, to: 80)
        #expect(!samples.contains(0))
    }

    @Test func readingBeforeFirstSampleReturnsSilence() {
        let ring = AudioRing(sampleRate: 48_000, seconds: 10)
        block(1, frames: 4800).withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 4800, time: 50) }
        let samples = ring.read(from: 49.9, to: 50.1)
        let frames = samples.count / 2
        #expect(samples[0] == 0)
        #expect(samples[(frames - 1) * 2] == 1)
    }
}
