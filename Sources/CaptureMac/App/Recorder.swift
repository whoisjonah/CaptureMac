import AVFoundation
import AppKit
import Observation
import ScreenCaptureKit

enum AudioRole: String, CaseIterable {
    case game, other, system, microphone

    var title: String {
        switch self {
        case .game: "Game"
        case .other: "Other apps"
        case .system: "System"
        case .microphone: "Microphone"
        }
    }
}

@MainActor
@Observable
final class Recorder {
    enum Status: Equatable {
        case stopped
        case starting
        case buffering
        case waiting(String)
        case failed(String)
    }

    static let shared = Recorder()

    private(set) var status: Status = .stopped
    private(set) var sources = ShareableSources()
    private(set) var bufferedSeconds: Double = 0
    private(set) var memoryBytes = 0
    private(set) var levels: [AudioRole: Float] = [:]
    private(set) var capturedApp: AppIdentity?
    private(set) var isSaving = false
    private(set) var audioError: String?
    private(set) var sessionStartedAt: Date?
    private(set) var sessionOnly = false

    @ObservationIgnored var onClipSaved: ((Clip) -> Void)?

    @ObservationIgnored private let preferences = Preferences.shared
    @ObservationIgnored private let videoRing = VideoRing(seconds: 60)
    @ObservationIgnored private let screen: ScreenRecorder
    @ObservationIgnored private var processTaps: [AudioRole: ProcessTap] = [:]
    @ObservationIgnored private var microphone: Microphone?
    @ObservationIgnored private var activeTarget: ResolvedTarget?
    @ObservationIgnored private var appliedSettings: VideoSettings?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var sourceWatchTask: Task<Void, Never>?
    @ObservationIgnored private var preferenceRestartTask: Task<Void, Never>?
    @ObservationIgnored private var sessionWriter: SessionWriter?
    @ObservationIgnored private var recordingApp: (name: String, bundleID: String?)?

    var isRunning: Bool {
        switch status {
        case .stopped, .failed: false
        default: true
        }
    }

    private init() {
        screen = ScreenRecorder(ring: videoRing)
        screen.onStop = { [weak self] _ in
            self?.videoStopped()
        }
        observePreferences()
    }

    var isRecordingSession: Bool { sessionStartedAt != nil }

    var replayEnabled: Bool { isRunning && !sessionOnly }

    private var bufferLength: Double {
        sessionOnly ? 15 : Double(preferences.bufferSeconds)
    }

    func toggle() {
        if isRecordingSession {
            if sessionOnly { return }
            sessionOnly = true
            videoRing.seconds = bufferLength
            return
        }
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func toggleSession() {
        Task {
            if isRecordingSession {
                await stopSession()
            } else {
                await startSession()
            }
        }
    }

    func startSession() async {
        guard !isRecordingSession else { return }
        if !isRunning {
            sessionOnly = true
            status = .starting
            await startCapture()
        }
        guard status == .buffering else {
            if sessionOnly {
                await stopCapture()
            }
            return
        }

        let appName = clipAppName()
        let bundleID = capturedApp?.bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do {
            let url = try clipURL(appName: appName, suffix: "Recording")
            let writer = try SessionWriter(
                url: url, sources: audioSources(), layout: preferences.trackLayout,
                audioBitrate: preferences.audioBitrate)
            sessionWriter = writer
            recordingApp = (appName, bundleID)
            videoRing.sink = { writer.append($0) }
            sessionStartedAt = .now
        } catch {
            audioError = error.localizedDescription
            if sessionOnly {
                await stopCapture()
            }
        }
    }

    func stopSession() async {
        guard let sessionWriter, let app = recordingApp else { return }
        videoRing.sink = nil
        self.sessionWriter = nil
        recordingApp = nil
        sessionStartedAt = nil

        let duration = await sessionWriter.finish()
        if sessionOnly {
            await stopCapture()
        }
        guard let duration else {
            ClipPopup.shared.showError("recording didn't save :(")
            return
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: sessionWriter.url.path)[.size] as? Int64) ?? 0
        let dimensions = sessionWriter.size
        var clip = Clip(
            path: sessionWriter.url.path,
            title: sessionWriter.url.deletingPathExtension().lastPathComponent,
            appName: app.name,
            bundleID: app.bundleID,
            createdAt: .now,
            duration: duration,
            size: size,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            audioTracks: sessionWriter.trackNames
        )
        clip.recording = true
        ClipLibrary.shared.add(clip)
        onClipSaved?(clip)
    }

    func start() {
        guard !isRunning else { return }
        status = .starting
        Task { await startCapture() }
    }

    func stop() {
        Task { await stopCapture() }
    }

    private func stopCapture() async {
        if isRecordingSession {
            sessionOnly = false
            await stopSession()
        }
        sessionOnly = false
        sourceWatchTask?.cancel()
        sourceWatchTask = nil
        meterTimer?.invalidate()
        meterTimer = nil
        status = .stopped
        activeTarget = nil
        appliedSettings = nil
        processTaps.removeAll()
        microphone = nil
        levels = [:]
        await screen.stop()
        videoRing.reset()
        bufferedSeconds = 0
        memoryBytes = 0
    }

    func refreshSources() async {
        if let refreshedSources = try? await ShareableSources.load() {
            sources = refreshedSources
        }
    }

    private func startCapture() async {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            status = .failed("needs screen recording permission")
            return
        }
        do {
            sources = try await ShareableSources.load()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        videoRing.seconds = bufferLength
        if let target = sources.resolve(preferences.target) {
            do {
                try await connect(to: target)
            } catch {
                status = .failed(error.localizedDescription)
                return
            }
        } else {
            status = .waiting("Waiting for \(preferences.target.title)")
        }
        startMeters()
        startWatching()
    }

    private func connect(to target: ResolvedTarget) async throws {
        let settings = videoSettings(for: target.pixelSize)
        videoRing.byteLimit = max(Int(Double(settings.bitrate) / 8 * bufferLength * 1.5), 256_000_000)
        try await screen.start(target, settings: settings)
        activeTarget = target
        appliedSettings = settings
        capturedApp = target.app
        configureAudio()
        status = .buffering
    }

    private func videoSettings(for pixelSize: CGSize) -> VideoSettings {
        var width = pixelSize.width
        var height = pixelSize.height
        if let maxHeight = preferences.resolution.maxHeight {
            let maxWidth = Double(maxHeight) * 16 / 9
            let scale = min(1, Double(maxHeight) / min(width, height), maxWidth / max(width, height))
            width *= scale
            height *= scale
        }
        let evenWidth = max(2, Int(width) & ~1)
        let evenHeight = max(2, Int(height) & ~1)
        return VideoSettings(
            width: evenWidth,
            height: evenHeight,
            frameRate: preferences.frameRate,
            bitrate: preferences.bitrate(width: evenWidth, height: evenHeight),
            quality: preferences.quality.constantQuality,
            codec: preferences.codec,
            showsCursor: preferences.showsCursor
        )
    }

    private func configureAudio() {
        let seconds = max(bufferLength, 15)
        var wanted: [AudioRole: TapScope] = [:]
        switch (preferences.systemAudio, capturedApp) {
        case (.off, _):
            break
        case (.everything, _), (.appOnly, nil), (.split, nil):
            wanted[.system] = .everything
        case (.appOnly, let app?):
            wanted[.game] = .app(app)
        case (.split, let app?):
            wanted[.game] = .app(app)
            wanted[.other] = .everythingExcept(app)
        }

        for role in processTaps.keys where wanted[role] == nil {
            processTaps[role] = nil
        }
        audioError = nil
        for (role, scope) in wanted {
            if let tap = processTaps[role] {
                tap.update(scope: scope)
                continue
            }
            do {
                let tap = try ProcessTap(scope: scope, seconds: seconds)
                tap.onFormatChange = { [weak self] in
                    self?.processTaps[role] = nil
                    self?.configureAudio()
                }
                processTaps[role] = tap
            } catch {
                audioError = "no system audio, \(error.localizedDescription)"
            }
        }

        if preferences.microphoneEnabled {
            if microphone == nil && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                startMicrophone(seconds: seconds)
            } else if microphone == nil {
                Task {
                    guard await Microphone.requestAccess() else {
                        audioError = "no mic access, allow it in system settings > privacy"
                        return
                    }
                    startMicrophone(seconds: seconds)
                }
            }
        } else {
            microphone = nil
        }
    }

    private func startMicrophone(seconds: Double) {
        guard isRunning, microphone == nil else { return }
        do {
            let microphone = try Microphone(uid: preferences.microphoneUID, seconds: seconds)
            microphone.onFormatChange = { [weak self] in
                self?.microphone = nil
                self?.startMicrophone(seconds: seconds)
            }
            self.microphone = microphone
        } catch {
            audioError = "mic didn't start, \(error.localizedDescription)"
        }
    }

    private func videoStopped() {
        guard isRunning else { return }
        activeTarget = nil
        status = .waiting("Waiting for \(preferences.target.title)")
    }

    private func startWatching() {
        sourceWatchTask?.cancel()
        sourceWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.reacquire()
                self?.retryAudio()
            }
        }
    }

    private func reacquire() async {
        guard isRunning, status != .starting else { return }
        if case .display = preferences.target, activeTarget != nil { return }
        guard let refreshedSources = try? await ShareableSources.load() else { return }
        sources = refreshedSources
        guard let target = refreshedSources.resolve(preferences.target) else {
            if activeTarget != nil, case .app = preferences.target {
                await screen.stop()
                videoStopped()
            }
            return
        }
        let sameWindow = target.windowID == activeTarget?.windowID && activeTarget != nil
        let settings = videoSettings(for: target.pixelSize)
        if sameWindow && settings == appliedSettings { return }
        if sameWindow, let applied = appliedSettings, abs(applied.width - settings.width) < 64,
            abs(applied.height - settings.height) < 64
        {
            return
        }
        try? await connect(to: target)
    }

    private func retryAudio() {
        guard status == .buffering, audioError != nil else { return }
        configureAudio()
    }

    private func startMeters() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeters() }
        }
    }

    private func updateMeters() {
        var next: [AudioRole: Float] = [:]
        for (role, tap) in processTaps {
            next[role] = max(tap.meter.take(), (levels[role] ?? 0) * 0.82)
        }
        if let microphone {
            next[.microphone] = max(microphone.meter.take(), (levels[.microphone] ?? 0) * 0.82)
        }
        levels = next
        bufferedSeconds = min(videoRing.bufferedSeconds, bufferLength)
        memoryBytes =
            videoRing.bytes + (processTaps.count + (microphone == nil ? 0 : 1))
            * Int(max(bufferLength, 15) * PCM.sampleRate * 8)
    }

    private func observePreferences() {
        withObservationTracking {
            _ = preferences.target
            _ = preferences.frameRate
            _ = preferences.resolution
            _ = preferences.quality
            _ = preferences.customBitrate
            _ = preferences.codec
            _ = preferences.showsCursor
            _ = preferences.systemAudio
            _ = preferences.microphoneEnabled
            _ = preferences.microphoneUID
            _ = preferences.bufferSeconds
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observePreferences()
                self?.scheduleRestart()
            }
        }
    }

    private func scheduleRestart() {
        guard isRunning, !isRecordingSession else { return }
        preferenceRestartTask?.cancel()
        preferenceRestartTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await stopCapture()
            start()
        }
    }

    func saveClip() async throws -> Clip {
        guard !isSaving else { throw ClipWriterError(errorDescription: "still saving the last one") }
        isSaving = true
        defer { isSaving = false }

        let length = bufferLength
        let now = HostClock.now
        let frames = videoRing.frames(from: now - length, to: now)
        guard let first = frames.first, let last = frames.last else {
            throw ClipWriterError(errorDescription: "nothing to save yet")
        }
        let start = first.time
        let end = max(last.time + 1 / Double(preferences.frameRate), min(now, last.time + 0.5))

        let sources = audioSources()

        let layout = preferences.trackLayout
        let bitrate = preferences.audioBitrate
        let appName = clipAppName()
        let bundleID = capturedApp?.bundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let url = try clipURL(appName: appName)
        let width = Int(first.sample.formatDescription?.dimensions.width ?? 0)
        let height = Int(first.sample.formatDescription?.dimensions.height ?? 0)

        let tracks = await Task.detached(priority: .userInitiated) {
            let frames = Int(((end - start) * PCM.sampleRate).rounded())
            let decoded = sources.map { source in
                let raw = source.1.read(from: start, to: end)
                let resampled = PCM.resample(raw, from: source.1.sampleRate)
                return (source.0, PCM.fit(PCM.scaled(resampled, by: source.2), frames: frames))
            }
            return Self.tracks(from: decoded, layout: layout)
        }.value

        try await ClipWriter.write(video: frames, end: end, audio: tracks, audioBitrate: bitrate, to: url)

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let clip = Clip(
            path: url.path,
            title: url.deletingPathExtension().lastPathComponent,
            appName: appName,
            bundleID: bundleID,
            createdAt: .now,
            duration: end - start,
            size: size,
            width: width,
            height: height,
            audioTracks: tracks.map(\.name)
        )
        ClipLibrary.shared.add(clip)
        onClipSaved?(clip)
        return clip
    }

    private func audioSources() -> [(AudioRole, AudioRing, Float)] {
        var sources: [(AudioRole, AudioRing, Float)] = []
        for role in [AudioRole.game, .system, .other] {
            if let tap = processTaps[role] {
                let gain = role == .other ? preferences.otherVolume : preferences.gameVolume
                sources.append((role, tap.ring, Float(gain)))
            }
        }
        if let microphone {
            sources.append((.microphone, microphone.ring, Float(preferences.microphoneVolume)))
        }
        return sources
    }

    nonisolated static func tracks(from sources: [(AudioRole, [Float])], layout: TrackLayout) -> [AudioTrack] {
        guard !sources.isEmpty else { return [] }
        let separate = sources.map { AudioTrack(name: $0.0.title, samples: $0.1, enabled: false) }
        let mixed = AudioTrack(name: "Mixed", samples: PCM.mix(sources.map(\.1)), enabled: true)
        if sources.count == 1 {
            return [AudioTrack(name: separate[0].name, samples: separate[0].samples, enabled: true)]
        }
        switch layout {
        case .mixed:
            return [mixed]
        case .mixedAndSeparate:
            return [mixed] + separate
        case .separate:
            return separate.map { AudioTrack(name: $0.name, samples: $0.samples, enabled: true) }
        }
    }

    private func clipAppName() -> String {
        if let capturedApp { return capturedApp.name }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            let name = frontmost.localizedName
        {
            return name
        }
        return "Desktop"
    }

    private func clipURL(appName: String, suffix: String? = nil) throws -> URL {
        var folder = preferences.clipsFolder
        if preferences.groupByApp {
            folder.appendPathComponent(ClipLibrary.safeName(appName), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = ["\(ClipLibrary.safeName(appName)) \(formatter.string(from: .now))", suffix].compactMap { $0 }
            .joined(separator: " ")
        var url = folder.appendingPathComponent(base).appendingPathExtension("mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension("mp4")
            counter += 1
        }
        return url
    }
}
