import Foundation
import Synchronization
import os

final class AudioRing: @unchecked Sendable {
    struct Anchor {
        var position: Int
        var time: Double
    }

    static let channels = 2

    let sampleRate: Double
    let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let firstPosition = Atomic<Int>(-1)
    private let anchors = OSAllocatedUnfairLock(initialState: [Anchor]())
    private let gapThreshold: Double
    private let anchorInterval: Double
    private let maxAnchors: Int

    private var nextPosition = 0
    private var lastAnchor: Anchor?
    private var predictedTime: Double?

    init(sampleRate: Double, seconds: Double, gapThreshold: Double = 0.08, anchorInterval: Double = 0.5) {
        self.sampleRate = sampleRate
        self.capacity = Int((seconds + 6) * sampleRate)
        self.gapThreshold = gapThreshold
        self.anchorInterval = anchorInterval
        self.maxAnchors = Int((seconds + 6) / anchorInterval) * 2 + 64
        storage = .allocate(capacity: capacity * Self.channels)
        storage.initialize(repeating: 0, count: capacity * Self.channels)
    }

    deinit {
        storage.deallocate()
    }

    var bufferedSeconds: Double {
        let first = firstPosition.load(ordering: .acquiring)
        guard first >= 0 else { return 0 }
        let end = written.load(ordering: .acquiring)
        return Double(min(end - first, capacity)) / sampleRate
    }

    func write(_ samples: UnsafePointer<Float>, frames: Int, time: Double) {
        guard frames > 0 else { return }
        var position = nextPosition

        if let predicted = predictedTime {
            let error = time - predicted
            if error > gapThreshold {
                let gap = Int(error * sampleRate)
                zero(from: position, count: min(gap, capacity))
                position += gap
                addAnchor(Anchor(position: position, time: time))
            } else if error < -gapThreshold {
                addAnchor(Anchor(position: position, time: time))
            } else if let last = lastAnchor, time - last.time >= anchorInterval {
                addAnchor(Anchor(position: position, time: time))
            }
        } else {
            addAnchor(Anchor(position: position, time: time))
            firstPosition.store(position, ordering: .releasing)
        }

        copy(samples, frames: frames, to: position)
        nextPosition = position + frames
        predictedTime = time + Double(frames) / sampleRate
        written.store(nextPosition, ordering: .releasing)
    }

    func read(from start: Double, to end: Double) -> [Float] {
        let frames = Int(((end - start) * sampleRate).rounded())
        guard frames > 0 else { return [] }
        var output = [Float](repeating: 0, count: frames * Self.channels)
        guard let startPosition = position(at: start) else { return output }

        let newest = written.load(ordering: .acquiring)
        let oldest = max(firstPosition.load(ordering: .acquiring), newest - capacity + Int(sampleRate * 3))
        let lower = max(startPosition, oldest)
        let upper = min(startPosition + frames, newest)
        guard upper > lower else { return output }

        output.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var position = lower
            while position < upper {
                let index = position % capacity
                let run = min(upper - position, capacity - index)
                let destination = baseAddress + (position - startPosition) * Self.channels
                destination.update(from: storage + index * Self.channels, count: run * Self.channels)
                position += run
            }
        }
        return output
    }

    func position(at time: Double) -> Int? {
        anchors.withLock { anchors in
            guard !anchors.isEmpty else { return nil }
            var low = 0
            var high = anchors.count - 1
            if time <= anchors[0].time {
                return anchors[0].position + Int(((time - anchors[0].time) * sampleRate).rounded())
            }
            while low < high {
                let mid = (low + high + 1) / 2
                if anchors[mid].time <= time { low = mid } else { high = mid - 1 }
            }
            let anchor = anchors[low]
            return anchor.position + Int(((time - anchor.time) * sampleRate).rounded())
        }
    }

    private func addAnchor(_ anchor: Anchor) {
        lastAnchor = anchor
        anchors.withLock { anchors in
            while let last = anchors.last, last.position >= anchor.position || last.time >= anchor.time {
                anchors.removeLast()
            }
            anchors.append(anchor)
            if anchors.count > maxAnchors {
                anchors.removeFirst(anchors.count - maxAnchors / 2)
            }
        }
    }

    private func copy(_ samples: UnsafePointer<Float>, frames: Int, to start: Int) {
        var offset = 0
        if frames > capacity { offset = frames - capacity }
        var position = start + offset
        let end = start + frames
        while position < end {
            let index = position % capacity
            let run = min(end - position, capacity - index)
            (storage + index * Self.channels).update(
                from: samples + (position - start) * Self.channels, count: run * Self.channels)
            position += run
        }
    }

    private func zero(from start: Int, count: Int) {
        var position = start
        let end = start + count
        while position < end {
            let index = position % capacity
            let run = min(end - position, capacity - index)
            (storage + index * Self.channels).update(repeating: 0, count: run * Self.channels)
            position += run
        }
    }
}
