import CoreMedia
import Foundation

final class VideoRing: @unchecked Sendable {
    struct Frame {
        let sample: CMSampleBuffer
        let time: Double
        let isKeyframe: Bool
        let bytes: Int
    }

    private let lock = NSLock()
    private var frames: [Frame] = []
    private var head = 0
    private var totalBytes = 0
    private var keep: Double
    private var limit = Int.max
    private var observer: ((CMSampleBuffer) -> Void)?

    init(seconds: Double) {
        keep = seconds
    }

    var seconds: Double {
        get { lock.withLock { keep } }
        set { lock.withLock { keep = newValue } }
    }

    var bytes: Int { lock.withLock { totalBytes } }

    var byteLimit: Int {
        get { lock.withLock { limit } }
        set { lock.withLock { limit = newValue } }
    }

    var sink: ((CMSampleBuffer) -> Void)? {
        get { lock.withLock { observer } }
        set { lock.withLock { observer = newValue } }
    }

    var bufferedSeconds: Double {
        lock.withLock {
            guard head < frames.count else { return 0 }
            return frames[frames.count - 1].time - frames[head].time
        }
    }

    var latestTime: Double? {
        lock.withLock { head < frames.count ? frames[frames.count - 1].time : nil }
    }

    func append(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let frame = Frame(
            sample: sample,
            time: sample.presentationTimeStamp.seconds,
            isKeyframe: !notSync,
            bytes: sample.totalSampleSize
        )

        lock.withLock {
            if let last = frames.last, head < frames.count, !Self.compatible(last.sample, sample) {
                frames.removeAll(keepingCapacity: true)
                head = 0
                totalBytes = 0
            }
            if head == frames.count && !frame.isKeyframe { return }
            frames.append(frame)
            totalBytes += frame.bytes
            evict()
        }
        sink?(sample)
    }

    func reset() {
        lock.withLock {
            frames.removeAll()
            head = 0
            totalBytes = 0
        }
    }

    func frames(from start: Double, to end: Double) -> [Frame] {
        lock.withLock {
            guard head < frames.count else { return [] }
            var first = head
            for index in head..<frames.count where frames[index].isKeyframe {
                if frames[index].time <= start { first = index } else { break }
            }
            var result: [Frame] = []
            for index in first..<frames.count {
                let frame = frames[index]
                if frame.time > end { break }
                result.append(frame)
            }
            return result
        }
    }

    private func evict() {
        guard let newest = frames.last?.time else { return }
        var next = head + 1
        while next < frames.count {
            if frames[next].isKeyframe {
                if newest - frames[next].time >= keep {
                    while head < next {
                        totalBytes -= frames[head].bytes
                        head += 1
                    }
                } else if totalBytes > limit {
                    while head < next {
                        totalBytes -= frames[head].bytes
                        head += 1
                    }
                } else {
                    break
                }
            }
            next += 1
        }
        if head > 512 && head * 2 > frames.count {
            frames.removeFirst(head)
            head = 0
        }
    }

    private static func compatible(_ a: CMSampleBuffer, _ b: CMSampleBuffer) -> Bool {
        guard let left = a.formatDescription, let right = b.formatDescription else { return false }
        return left.mediaSubType == right.mediaSubType && left.dimensions.width == right.dimensions.width && left.dimensions.height == right.dimensions.height
    }
}
