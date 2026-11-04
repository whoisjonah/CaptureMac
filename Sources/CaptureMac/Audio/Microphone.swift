import AVFoundation
import CoreAudio
import Foundation

struct InputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String

    static func all() -> [InputDevice] {
        let devices = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioObjectID.self)) ?? []
        return devices.compactMap { device in
            guard device.inputChannelCount() > 0,
                  let uid = device.readString(kAudioDevicePropertyDeviceUID),
                  let name = device.readString(kAudioObjectPropertyName),
                  !uid.hasPrefix("CaptureMac") else { return nil }
            return InputDevice(id: device, uid: uid, name: name)
        }
    }

    static func resolve(uid: String?) -> AudioObjectID? {
        if let uid, let match = all().first(where: { $0.uid == uid }) {
            return match.id
        }
        let fallback = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self)
        return fallback.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }
}

final class Microphone {
    let ring: AudioRing
    let meter = LevelMeter()
    var onFormatChange: (() -> Void)?

    private let preferredUID: String?
    private var device: AudioObjectID
    private var input: DeviceInput?
    private var listeners: [PropertyListener] = []

    init(uid: String?, seconds: Double) throws {
        guard let device = InputDevice.resolve(uid: uid) else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, action: "no mic found")
        }
        self.preferredUID = uid
        self.device = device
        ring = AudioRing(sampleRate: try device.nominalSampleRate(), seconds: seconds)
        try attach()
        listeners.append(PropertyListener(.system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.follow() })
        listeners.append(PropertyListener(.system, kAudioHardwarePropertyDevices) { [weak self] in self?.follow() })
    }

    deinit {
        listeners.removeAll()
        input?.stop()
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private func attach() throws {
        let input = DeviceInput(device: device, ring: ring, meter: meter, downmixMono: true)
        try input.start()
        self.input = input
        listeners.removeAll { $0 is DeviceRateListener }
        listeners.append(DeviceRateListener(device) { [weak self] in self?.reattach() })
    }

    private func follow() {
        guard let resolved = InputDevice.resolve(uid: preferredUID), resolved != device else { return }
        device = resolved
        reattach()
    }

    private func reattach() {
        input?.stop()
        input = nil
        guard let rate = try? device.nominalSampleRate(), rate == ring.sampleRate else {
            onFormatChange?()
            return
        }
        try? attach()
    }
}

final class DeviceRateListener: PropertyListener {
    init(_ device: AudioObjectID, handler: @escaping () -> Void) {
        super.init(device, kAudioDevicePropertyNominalSampleRate, handler: handler)
    }
}
