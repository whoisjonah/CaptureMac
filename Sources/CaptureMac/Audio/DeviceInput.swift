import CoreAudio
import CoreMedia
import Foundation
import Synchronization

final class LevelMeter: Sendable {
    private let bits = Atomic<UInt32>(0)

    func record(_ peak: Float) {
        let current = Float(bitPattern: bits.load(ordering: .relaxed))
        if peak > current { bits.store(peak.bitPattern, ordering: .relaxed) }
    }

    func take() -> Float {
        Float(bitPattern: bits.exchange(0, ordering: .relaxed))
    }
}

final class DeviceInput {
    let device: AudioObjectID
    let ring: AudioRing
    let meter: LevelMeter
    let downmixMono: Bool

    private var procID: AudioDeviceIOProcID?
    private var scratch: UnsafeMutablePointer<Float>
    private var scratchFrames = 16_384

    init(device: AudioObjectID, ring: AudioRing, meter: LevelMeter, downmixMono: Bool) {
        self.device = device
        self.ring = ring
        self.meter = meter
        self.downmixMono = downmixMono
        scratch = .allocate(capacity: scratchFrames * AudioRing.channels)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    func start() throws {
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { [unowned self] _, input, inputTime, _, _ in
                self.receive(input, at: inputTime.pointee)
            }, "couldn't hook into the audio device")
        try check(AudioDeviceStart(device, procID), "audio device wouldn't start")
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>, at timestamp: AudioTimeStamp) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0, let data = first.mData else { return }

        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard frames > 0 else { return }
        if frames > scratchFrames {
            scratch.deallocate()
            scratchFrames = frames
            scratch = .allocate(capacity: frames * AudioRing.channels)
        }

        let left: UnsafePointer<Float>
        let right: UnsafePointer<Float>
        let leftStride: Int
        let rightStride: Int

        let firstData = UnsafePointer(data.assumingMemoryBound(to: Float.self))
        if first.mNumberChannels >= 2 {
            left = firstData
            right = firstData + 1
            leftStride = Int(first.mNumberChannels)
            rightStride = leftStride
        } else if buffers.count >= 2, let second = buffers[1].mData {
            left = firstData
            right = UnsafePointer(second.assumingMemoryBound(to: Float.self))
            leftStride = 1
            rightStride = Int(buffers[1].mNumberChannels)
        } else {
            left = firstData
            right = firstData
            leftStride = 1
            rightStride = 1
        }

        var peak: Float = 0
        for frame in 0..<frames {
            var l = left[frame * leftStride]
            var r = right[frame * rightStride]
            if downmixMono {
                l = (l + r) * 0.5
                r = l
            }
            scratch[frame * 2] = l
            scratch[frame * 2 + 1] = r
            peak = max(peak, abs(l), abs(r))
        }
        meter.record(peak)

        let time: Double
        if timestamp.mFlags.contains(.hostTimeValid) {
            time = HostClock.seconds(fromHostTime: timestamp.mHostTime)
        } else {
            time = HostClock.now
        }
        ring.write(scratch, frames: frames, time: time)
    }
}

enum HostClock {
    static var now: Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    static func seconds(fromHostTime hostTime: UInt64) -> Double {
        CMClockMakeHostTimeFromSystemUnits(hostTime).seconds
    }
}
