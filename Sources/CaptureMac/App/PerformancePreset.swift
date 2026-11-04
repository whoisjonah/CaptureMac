import AppKit

enum PerformancePreset: String, CaseIterable, Identifiable {
    case potato, normal, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .potato: "Potato"
        case .normal: "Normal"
        case .max: "Max"
        }
    }

    var symbol: String {
        switch self {
        case .potato: "leaf"
        case .normal: "gauge.with.dots.needle.50percent"
        case .max: "flame"
        }
    }

    var resolution: Resolution {
        switch self {
        case .potato: .p720
        case .normal: .p1080
        case .max: .native
        }
    }

    var frameRate: Int {
        switch self {
        case .potato: 30
        case .normal: 60
        case .max: Self.displayRefreshRate >= 120 ? 120 : 60
        }
    }

    var quality: VideoQuality {
        switch self {
        case .potato: .low
        case .normal: .balanced
        case .max: .high
        }
    }

    var summary: String {
        "\(resolution.title), \(frameRate) fps, \(quality.title.lowercased()) quality"
    }

    var detail: String {
        switch self {
        case .potato: "Lightest on older Macs and laptops on battery"
        case .normal: "Sharp 1080p that most Macs handle without noticing"
        case .max: "Full resolution and the best quality, for Pro and Max chips"
        }
    }

    @MainActor
    func apply(to preferences: Preferences) {
        preferences.resolution = resolution
        preferences.frameRate = frameRate
        preferences.quality = quality
        preferences.codec = .h264
    }

    @MainActor
    static func matching(_ preferences: Preferences) -> PerformancePreset? {
        allCases.first {
            $0.resolution == preferences.resolution && $0.frameRate == preferences.frameRate && $0.quality == preferences.quality && preferences.codec == .h264
        }
    }

    static var recommended: PerformancePreset {
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        guard Hardware.isAppleSilicon else {
            return memory >= 16 ? .normal : .potato
        }
        if memory < 8 { return .potato }
        if memory >= 16 && Hardware.performanceCores >= 6 { return .max }
        return .normal
    }

    static var displayRefreshRate: Int {
        NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
    }
}

enum Hardware {
    static var isAppleSilicon: Bool {
        sysctl(int: "hw.optional.arm64") == 1
    }

    static var performanceCores: Int {
        sysctl(int: "hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
    }

    static var chip: String {
        sysctl(string: "machdep.cpu.brand_string") ?? "this Mac"
    }

    static var memory: String {
        "\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB"
    }

    private static func sysctl(int name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctl(string name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
