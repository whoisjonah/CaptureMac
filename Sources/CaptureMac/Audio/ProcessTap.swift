import AppKit
import CoreAudio
import Foundation

enum TapScope: Equatable {
    case everything
    case app(AppIdentity)
    case everythingExcept(AppIdentity)
}

struct AppIdentity: Codable, Hashable {
    var bundleID: String?
    var pid: pid_t
    var name: String

    func owns(bundleID other: String?, pid otherPID: pid_t) -> Bool {
        if otherPID == pid { return true }
        guard let bundleID, let other else { return false }
        return other == bundleID || other.hasPrefix(bundleID + ".")
    }
}

enum AudioProcesses {
    static func all() -> [(object: AudioObjectID, pid: pid_t, bundleID: String?)] {
        let objects = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)) ?? []
        return objects.compactMap { object in
            guard let pid = try? object.read(kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
            return (object, pid, object.readString(kAudioProcessPropertyBundleID))
        }
    }

    static func objects(matching app: AppIdentity) -> [AudioObjectID] {
        all().filter { app.owns(bundleID: $0.bundleID, pid: $0.pid) }.map(\.object)
    }

    static func ownObjects() -> [AudioObjectID] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return all().filter { $0.pid == pid }.map(\.object)
    }
}

final class ProcessTap {
    let ring: AudioRing
    let meter = LevelMeter()
    private(set) var scope: TapScope
    var onFormatChange: (() -> Void)?

    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var input: DeviceInput?
    private var listeners: [PropertyListener] = []
    private var appliedProcesses: [AudioObjectID] = []

    var sampleRate: Double { ring.sampleRate }

    init(scope: TapScope, seconds: Double) throws {
        self.scope = scope
        let processes = Self.processes(for: scope)
        switch scope {
        case .app:
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        case .everything, .everythingExcept:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        }
        description.uuid = UUID()
        description.name = "CaptureMac"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        appliedProcesses = processes

        try check(AudioHardwareCreateProcessTap(description, &tapID), "couldn't tap system audio")
        let format = try tapID.read(kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
        ring = AudioRing(sampleRate: format.mSampleRate > 0 ? format.mSampleRate : 48_000, seconds: seconds)

        do {
            try buildAggregate()
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        listeners = [
            PropertyListener(.system, kAudioHardwarePropertyDefaultSystemOutputDevice) { [weak self] in self?.rebuild() },
            PropertyListener(.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refreshProcesses() },
        ]
    }

    deinit {
        listeners.removeAll()
        teardownAggregate()
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }

    func update(scope: TapScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        refreshProcesses()
    }

    private static func processes(for scope: TapScope) -> [AudioObjectID] {
        switch scope {
        case .everything:
            return AudioProcesses.ownObjects()
        case .app(let app):
            return AudioProcesses.objects(matching: app)
        case .everythingExcept(let app):
            return AudioProcesses.ownObjects() + AudioProcesses.objects(matching: app)
        }
    }

    private func refreshProcesses() {
        let processes = Self.processes(for: scope)
        guard Set(processes) != Set(appliedProcesses) else { return }
        description.processes = processes
        var address = AudioObjectPropertyAddress(kAudioTapPropertyDescription)
        var reference: Unmanaged<CATapDescription> = .passUnretained(description)
        let status = AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), &reference)
        if status == noErr { appliedProcesses = processes }
    }

    private func rebuild() {
        teardownAggregate()
        let format = try? tapID.read(kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
        if let rate = format?.mSampleRate, rate > 0, rate != ring.sampleRate {
            onFormatChange?()
            return
        }
        try? buildAggregate()
    }

    private func buildAggregate() throws {
        let output = try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioObjectID.self)
        guard let outputUID = output.readString(kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, action: "can't find your speakers")
        }

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CaptureMac Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]

        try check(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID), "couldn't make the audio device")
        let input = DeviceInput(device: aggregateID, ring: ring, meter: meter, downmixMono: false)
        try input.start()
        self.input = input
    }

    private func teardownAggregate() {
        input?.stop()
        input = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
