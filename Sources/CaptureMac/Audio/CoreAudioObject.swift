import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let action: String

    var errorDescription: String? { "\(action) (\(status))" }
}

func check(_ status: OSStatus, _ action: String) throws {
    if status != noErr { throw CoreAudioError(status: status, action: action) }
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func read<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: T.Type, qualifier: Any? = nil) throws -> T {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        if var pid = qualifier as? pid_t {
            try check(AudioObjectGetPropertyData(self, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, value), "couldn't read an audio setting")
        } else {
            try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, value), "couldn't read an audio setting")
        }
        return value.load(as: T.self)
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of type: T.Type) throws -> [T] {
        var address = AudioObjectPropertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "couldn't read an audio setting")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer), "couldn't read an audio setting")
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    func readString(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    func inputChannelCount() -> Int {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func nominalSampleRate() throws -> Double {
        try read(kAudioDevicePropertyNominalSampleRate, as: Float64.self)
    }
}

class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue

    init(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        self.object = object
        self.address = AudioObjectPropertyAddress(selector)
        self.queue = queue
        self.block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
