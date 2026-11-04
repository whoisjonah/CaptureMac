import AVFoundation
import AppKit
import Observation

@MainActor
@Observable
final class EditorModel {
    struct Track: Identifiable {
        let id: Int
        let name: String
        var volume: Float
        var muted: Bool
    }

    let clip: Clip
    let player: AVPlayer

    var duration: Double
    var trimStart: Double = 0
    var trimEnd: Double
    var splits: [Double] = []
    var removed: Set<Int> = []
    var selectedSegment: Int?
    var currentTime: Double = 0
    var isPlaying = false
    var tracks: [Track] = []
    var customMix = false
    var preset: ExportPreset
    var filmstrip: [NSImage] = []
    var exportProgress: Double?
    var message: String?
    var info: SourceInfo?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var assetTracks: [AVAssetTrack] = []

    init(clip: Clip) {
        self.clip = clip
        player = AVPlayer(url: clip.url)
        player.actionAtItemEnd = .pause
        duration = clip.duration
        trimEnd = clip.duration
        preset = Preferences.shared.exportPreset
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    var hasMixedTrack: Bool {
        clip.audioTracks.first == "Mixed" && clip.audioTracks.count > 1
    }

    var editableTracks: [Track] {
        hasMixedTrack ? tracks.filter { $0.id != 0 } : tracks
    }

    var isTrimmed: Bool {
        trimStart > 0.05 || trimEnd < duration - 0.05
    }

    var segments: [TrimRange] {
        let bounds = [0] + splits + [duration]
        return zip(bounds, bounds.dropFirst()).map { TrimRange(start: $0, end: $1) }
    }

    var keptRanges: [TrimRange] {
        segments.enumerated().compactMap { index, segment in
            guard !removed.contains(index) else { return nil }
            let start = max(segment.start, trimStart)
            let end = min(segment.end, trimEnd)
            return end - start > 0.05 ? TrimRange(start: start, end: end) : nil
        }
    }

    var isEdited: Bool {
        isTrimmed || !removed.isEmpty
    }

    var edits: [TrimRange]? {
        isEdited ? keptRanges : nil
    }

    var editedDuration: Double {
        keptRanges.reduce(0) { $0 + $1.end - $1.start }
    }

    func segment(at time: Double) -> Int? {
        segments.firstIndex { time >= $0.start && time < $0.end } ?? (segments.isEmpty ? nil : segments.count - 1)
    }

    func split() {
        let time = currentTime
        guard time > 0.1, time < duration - 0.1, !splits.contains(where: { abs($0 - time) < 0.1 }),
              let index = segment(at: time) else { return }
        splits.append(time)
        splits.sort()
        removed = Set(removed.flatMap { $0 < index ? [$0] : $0 == index ? [$0, $0 + 1] : [$0 + 1] })
        selectedSegment = index + 1
    }

    func toggleRemoved(_ index: Int? = nil) {
        guard let index = index ?? selectedSegment ?? segment(at: currentTime) else { return }
        if removed.contains(index) {
            removed.remove(index)
        } else if removed.count + 1 < segments.count {
            removed.insert(index)
        }
        selectedSegment = index
    }

    func resetEdits() {
        trimStart = 0
        trimEnd = duration
        splits = []
        removed = []
        selectedSegment = nil
    }

    var volumes: [Float]? {
        guard customMix else { return nil }
        return tracks.map { track in
            if hasMixedTrack && track.id == 0 { return 0 }
            return track.muted ? 0 : track.volume
        }
    }

    var plan: ExportPlan? {
        guard let info else { return nil }
        return ExportPlan.make(
            preset: preset, duration: editedDuration, width: info.width, height: info.height,
            frameRate: info.frameRate, sourceBitrate: info.bitrate, audioChanged: volumes != nil || keptRanges.count > 1
        )
    }

    func load() async {
        let asset = AVURLAsset(url: clip.url)
        info = try? await SourceInfo.load(clip.url)
        if let info { duration = info.duration; trimEnd = info.duration }
        assetTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        tracks = assetTracks.indices.map { index in
            let name = index < clip.audioTracks.count ? clip.audioTracks[index] : "Track \(index + 1)"
            return Track(id: index, name: name, volume: 1, muted: false)
        }
        await loadFilmstrip(asset)
    }

    private func loadFilmstrip(_ asset: AVURLAsset) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let count = 14
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var images: [NSImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                images.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            }
        }
        filmstrip = images
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= trimEnd - 0.05 || currentTime < trimStart {
                seek(to: keptRanges.first?.start ?? trimStart)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setIn() {
        trimStart = min(currentTime, trimEnd - 0.5)
    }

    func setOut() {
        trimEnd = max(currentTime, trimStart + 0.5)
    }

    func step(by frames: Int) {
        player.pause()
        isPlaying = false
        let fps = info?.frameRate ?? 60
        seek(to: currentTime + Double(frames) / fps)
    }

    func updateMix() {
        customMix = true
        guard let item = player.currentItem else { return }
        let parameters = zip(assetTracks, tracks).map { assetTrack, track in
            let input = AVMutableAudioMixInputParameters(track: assetTrack)
            let isMixed = hasMixedTrack && track.id == 0
            input.setVolume(isMixed || track.muted ? 0 : track.volume, at: .zero)
            return input
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        item.audioMix = mix
        for itemTrack in item.tracks where itemTrack.assetTrack?.mediaType == .audio {
            itemTrack.isEnabled = true
        }
    }

    func resetMix() {
        customMix = false
        for index in tracks.indices {
            tracks[index].volume = 1
            tracks[index].muted = false
        }
        guard let item = player.currentItem else { return }
        item.audioMix = nil
        for (index, itemTrack) in item.tracks.filter({ $0.assetTrack?.mediaType == .audio }).enumerated() {
            itemTrack.isEnabled = !hasMixedTrack || index == 0
        }
    }

    func export(to destination: URL) async -> Bool {
        exportProgress = 0
        message = nil
        defer { exportProgress = nil }
        do {
            try await Exporter.export(clip.url, ranges: edits?.map(\.range), preset: preset, volumes: volumes, to: destination) { [weak self] value in
                Task { @MainActor in self?.exportProgress = value }
            }
            Preferences.shared.exportPreset = preset
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func saveCopy() async {
        let base = clip.url.deletingPathExtension().lastPathComponent + " edit"
        var destination = clip.url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension("mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = clip.url.deletingLastPathComponent().appendingPathComponent("\(base) \(counter)").appendingPathExtension("mp4")
            counter += 1
        }
        guard await export(to: destination) else { return }
        if let copy = await ClipLibrary.shared.importFile(at: destination, title: destination.deletingPathExtension().lastPathComponent, appName: clip.appName, bundleID: clip.bundleID) {
            message = "Saved \(copy.title)"
        }
    }

    func saveAs() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = clip.url.deletingPathExtension().lastPathComponent + ".mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if await export(to: url) {
            message = "Exported to \(url.lastPathComponent)"
        }
    }

    func upload() async {
        message = nil
        if let link = await Uploads.shared.upload(clip, preset: preset, ranges: edits, volumes: volumes) {
            message = "Link copied: \(link.absoluteString)"
        } else if let failure = Uploads.shared.failures[clip.id] {
            message = failure
        }
    }

    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        currentTime = time
        guard isPlaying else { return }
        let kept = keptRanges
        if let next = kept.first(where: { $0.end > time + 0.02 }) {
            if time < next.start - 0.02 {
                seek(to: next.start)
                player.play()
                return
            }
        } else if let first = kept.first {
            seek(to: first.start)
            player.play()
            return
        }
        if player.rate == 0 && player.currentItem?.status == .readyToPlay && time >= duration - 0.05 {
            seek(to: kept.first?.start ?? trimStart)
            player.play()
        }
    }
}
