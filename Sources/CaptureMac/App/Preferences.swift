import CoreGraphics
import Foundation
import Observation

enum Resolution: String, Codable, CaseIterable, Identifiable {
    case native, p1440, p1080, p720

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: "Native"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }

    var maxHeight: Int? {
        switch self {
        case .native: nil
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        }
    }
}

enum VideoQuality: String, Codable, CaseIterable, Identifiable {
    case low, balanced, high, custom

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var constantQuality: Double? {
        switch self {
        case .low: 0.55
        case .balanced: 0.7
        case .high: 0.82
        case .custom: nil
        }
    }

    var bitsPerPixel: Double {
        switch self {
        case .low: 0.12
        case .balanced: 0.2
        case .high: 0.3
        case .custom: 0.12
        }
    }
}

enum SystemAudioMode: String, Codable, CaseIterable, Identifiable {
    case off, everything, appOnly, split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .everything: "All system audio"
        case .appOnly: "Captured app only"
        case .split: "Captured app and everything else"
        }
    }
}

enum TrackLayout: String, Codable, CaseIterable, Identifiable {
    case mixed, mixedAndSeparate, separate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixed: "One mixed track"
        case .mixedAndSeparate: "Mixed track plus one per source"
        case .separate: "One track per source"
        }
    }
}

enum ScreenCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

struct R2Settings: Codable, Equatable {
    var accountID = ""
    var accessKeyID = ""
    var bucket = ""
    var publicURL = ""
    var folder = "clips"

    var isComplete: Bool {
        !accountID.isEmpty && !accessKeyID.isEmpty && !bucket.isEmpty && !publicURL.isEmpty
    }
}

@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    var bufferSeconds = load("bufferSeconds", 60) { didSet { save("bufferSeconds", bufferSeconds) } }
    var target = load("target", CaptureTarget.display(CGMainDisplayID())) { didSet { save("target", target) } }
    var frameRate = load("frameRate", 60) { didSet { save("frameRate", frameRate) } }
    var resolution = load("resolution", Resolution.native) { didSet { save("resolution", resolution) } }
    var quality = load("quality", VideoQuality.balanced) { didSet { save("quality", quality) } }
    var customBitrate = load("customBitrate", 20.0) { didSet { save("customBitrate", customBitrate) } }
    var codec = load("codec", VideoCodec.h264) { didSet { save("codec", codec) } }
    var showsCursor = load("showsCursor", true) { didSet { save("showsCursor", showsCursor) } }

    var systemAudio = load("systemAudio", SystemAudioMode.everything) { didSet { save("systemAudio", systemAudio) } }
    var microphoneEnabled = load("microphoneEnabled", false) { didSet { save("microphoneEnabled", microphoneEnabled) } }
    var microphoneUID = load("microphoneUID", String?.none) { didSet { save("microphoneUID", microphoneUID) } }
    var gameVolume = load("gameVolume", 1.0) { didSet { save("gameVolume", gameVolume) } }
    var otherVolume = load("otherVolume", 1.0) { didSet { save("otherVolume", otherVolume) } }
    var microphoneVolume = load("microphoneVolume", 1.0) { didSet { save("microphoneVolume", microphoneVolume) } }
    var trackLayout = load("trackLayout", TrackLayout.mixedAndSeparate) { didSet { save("trackLayout", trackLayout) } }
    var audioBitrate = load("audioBitrate", 192) { didSet { save("audioBitrate", audioBitrate) } }

    var clipsFolder = load("clipsFolder", Preferences.defaultFolder) { didSet { save("clipsFolder", clipsFolder) } }
    var groupByApp = load("groupByApp", true) { didSet { save("groupByApp", groupByApp) } }
    var showPopup = load("showPopup", true) { didSet { save("showPopup", showPopup) } }
    var popupSeconds = load("popupSeconds", 6.0) { didSet { save("popupSeconds", popupSeconds) } }
    var popupCorner = load("popupCorner", ScreenCorner.bottomRight) { didSet { save("popupCorner", popupCorner) } }
    var playsSound = load("playsSound", true) { didSet { save("playsSound", playsSound) } }
    var confirmsDelete = load("confirmsDelete", true) { didSet { save("confirmsDelete", confirmsDelete) } }
    var copiesClip = load("copiesClip", false) { didSet { save("copiesClip", copiesClip) } }
    var savesCopy = load("savesCopy", false) { didSet { save("savesCopy", savesCopy) } }
    var copyFolder = load("copyFolder", FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]) { didSet { save("copyFolder", copyFolder) } }
    var startOnLaunch = load("startOnLaunch", true) { didSet { save("startOnLaunch", startOnLaunch) } }
    var checksForUpdates = load("checksForUpdates", true) { didSet { save("checksForUpdates", checksForUpdates) } }

    var saveShortcut = load("saveShortcut", Shortcut?.some(.defaultSave)) { didSet { save("saveShortcut", saveShortcut) } }
    var toggleShortcut = load("toggleShortcut", Shortcut?.some(.defaultToggle)) { didSet { save("toggleShortcut", toggleShortcut) } }
    var recordShortcut = load("recordShortcut", Shortcut?.some(.defaultRecord)) { didSet { save("recordShortcut", recordShortcut) } }

    var r2 = load("r2", R2Settings()) { didSet { save("r2", r2) } }
    var uploadPreset = load("uploadPreset", ExportPreset.original) { didSet { save("uploadPreset", uploadPreset) } }
    var autoUpload = load("autoUpload", false) { didSet { save("autoUpload", autoUpload) } }
    var exportPreset = load("exportPreset", ExportPreset.targetSize(25)) { didSet { save("exportPreset", exportPreset) } }

    var thumbnailSize = load("thumbnailSize", 220.0) { didSet { save("thumbnailSize", thumbnailSize) } }
    var onboarded = load("onboarded", false) { didSet { save("onboarded", onboarded) } }

    private init() {
        if UserDefaults.standard.data(forKey: "resolution") == nil {
            PerformancePreset.recommended.apply(to: self)
        }
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("CaptureMac", isDirectory: true)
    }

    func bitrate(width: Int, height: Int) -> Int {
        if quality == .custom { return Int(customBitrate * 1_000_000) }
        let scale = codec == .hevc ? 0.7 : 1.0
        let bits = Double(width * height * frameRate) * quality.bitsPerPixel * scale
        return Int(min(max(bits, 4_000_000), 150_000_000))
    }

    private static func load<T: Codable>(_ key: String, _ fallback: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    private func save<T: Codable>(_ key: String, _ value: T) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
