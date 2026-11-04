import CoreMedia
import Testing
@testable import CaptureMac

struct VideoRingTests {
    private let format: CMVideoFormatDescription = {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 1920, height: 1080, extensions: nil, formatDescriptionOut: &description)
        return description!
    }()

    private func frame(at time: Double, keyframe: Bool) -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        )
        if !keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample!
    }

    private func fill(_ ring: VideoRing, seconds: Double, fps: Double = 30) {
        var index = 0
        while Double(index) / fps < seconds {
            let time = Double(index) / fps
            ring.append(frame(at: time, keyframe: index % Int(fps) == 0))
            index += 1
        }
    }

    @Test func keepsRequestedLengthFromAKeyframe() {
        let ring = VideoRing(seconds: 10)
        fill(ring, seconds: 30)
        let frames = ring.frames(from: 0, to: 100)
        #expect(frames.first?.isKeyframe == true)
        #expect(ring.bufferedSeconds >= 10)
        #expect(ring.bufferedSeconds < 11.1)
    }

    @Test func clipsStartOnPrecedingKeyframe() {
        let ring = VideoRing(seconds: 20)
        fill(ring, seconds: 20)
        let frames = ring.frames(from: 12.5, to: 15)
        #expect(frames.first?.isKeyframe == true)
        #expect(abs(frames.first!.time - 12) < 0.001)
        #expect(frames.last!.time <= 15)
    }

    @Test func byteLimitTrimsOldestGroups() {
        let ring = VideoRing(seconds: 60)
        ring.byteLimit = -1
        fill(ring, seconds: 10)
        #expect(ring.frames(from: 0, to: 100).first?.time ?? 0 >= 9)
    }

    @Test func dropsLeadingNonKeyframes() {
        let ring = VideoRing(seconds: 10)
        ring.append(frame(at: 0, keyframe: false))
        ring.append(frame(at: 0.1, keyframe: false))
        #expect(ring.frames(from: 0, to: 1).isEmpty)
        ring.append(frame(at: 0.2, keyframe: true))
        #expect(ring.frames(from: 0, to: 1).count == 1)
    }
}
