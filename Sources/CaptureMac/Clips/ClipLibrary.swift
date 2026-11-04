import AppKit
import AVFoundation
import Observation

struct Clip: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    var title: String
    var appName: String
    var bundleID: String?
    var createdAt: Date
    var duration: Double
    var size: Int64
    var width: Int
    var height: Int
    var audioTracks: [String]
    var shareURL: URL?
    var favorite = false
    var recording: Bool?

    var url: URL { URL(fileURLWithPath: path) }
    var isRecording: Bool { recording == true }
}

@MainActor
@Observable
final class ClipLibrary {
    static let shared = ClipLibrary()

    private(set) var clips: [Clip] = []

    @ObservationIgnored private let indexURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        indexURL = support.appendingPathComponent("library.json")
        load()
    }

    var apps: [(name: String, bundleID: String?, count: Int)] {
        let grouped = Dictionary(grouping: clips, by: \.appName)
        return grouped
            .map { (name: $0.key, bundleID: $0.value.first?.bundleID, count: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func clip(_ id: Clip.ID) -> Clip? {
        clips.first { $0.id == id }
    }

    func add(_ clip: Clip) {
        clips.insert(clip, at: 0)
        persist()
    }

    func update(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index] = clip
        persist()
    }

    func rename(_ clip: Clip, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var updated = self.clip(clip.id) else { return }
        let destination = clip.url.deletingLastPathComponent().appendingPathComponent(Self.safeName(trimmed)).appendingPathExtension(clip.url.pathExtension)
        if destination != clip.url, !FileManager.default.fileExists(atPath: destination.path),
           (try? FileManager.default.moveItem(at: clip.url, to: destination)) != nil {
            updated.path = destination.path
        }
        updated.title = trimmed
        update(updated)
    }

    func delete(_ clip: Clip) {
        try? FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
        clips.removeAll { $0.id == clip.id }
        Thumbnails.shared.forget(clip)
        persist()
    }

    func reveal(_ clip: Clip) {
        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    }

    func copyFile(_ clip: Clip) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([clip.url as NSURL])
    }

    func copyLink(_ clip: Clip) {
        guard let link = clip.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    func importFile(at url: URL, title: String, appName: String, bundleID: String?) async -> Clip? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
        let size = (try? await videoTrack?.load(.naturalSize)) ?? .zero
        let audioCount = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let clip = Clip(
            path: url.path, title: title, appName: appName, bundleID: bundleID, createdAt: .now,
            duration: duration.seconds, size: bytes, width: Int(size.width), height: Int(size.height),
            audioTracks: audioCount == 1 ? ["Audio"] : (0..<audioCount).map { "Track \($0 + 1)" }
        )
        add(clip)
        return clip
    }

    static func safeName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([Clip].self, from: data) else { return }
        clips = stored.filter { FileManager.default.fileExists(atPath: $0.path) }
        if clips.count != stored.count { persist() }
    }

    private func persist() {
        let snapshot = clips
        let url = indexURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    private let cache = NSCache<NSString, NSImage>()
    private let folder: URL

    private init() {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureMac/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func image(for clip: Clip) async -> NSImage? {
        let key = clip.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let file = folder.appendingPathComponent("\(clip.id.uuidString).jpg")
        if let image = NSImage(contentsOf: file) {
            cache.setObject(image, forKey: key)
            return image
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: max(0, clip.duration - 1.5), preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: time) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        if let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? data.write(to: file)
        }
        return image
    }

    func forget(_ clip: Clip) {
        cache.removeObject(forKey: clip.id.uuidString as NSString)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(clip.id.uuidString).jpg"))
    }
}
