import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            VideoSettingsView()
                .tabItem { Label("Video", systemImage: "video") }
            AudioSettings()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            ClipSettings()
                .tabItem { Label("Clips", systemImage: "film.stack") }
            UploadSettings()
                .tabItem { Label("Upload", systemImage: "icloud.and.arrow.up") }
        }
        .frame(width: 620, height: 520)
    }
}

private struct GeneralSettings: View {
    @State private var preferences = Preferences.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var updater = Updater.shared

    private let lengths = [15, 30, 45, 60, 90, 120, 180, 300, 600]

    var body: some View {
        Form {
            Section {
                Picker("Replay length", selection: $preferences.bufferSeconds) {
                    ForEach(lengths, id: \.self) { seconds in
                        Text(Format.bufferLength(seconds)).tag(seconds)
                    }
                }
                LabeledContent("Memory use") {
                    Text("Up to \(Format.bytes(estimatedMemory))")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Shortcuts") {
                LabeledContent("Save clip") {
                    ShortcutRecorder(shortcut: $preferences.saveShortcut)
                }
                LabeledContent("Start or stop recording") {
                    ShortcutRecorder(shortcut: $preferences.recordShortcut)
                }
                LabeledContent("Turn replay buffer on or off") {
                    ShortcutRecorder(shortcut: $preferences.toggleShortcut)
                }
            }

            Section {
                Toggle("Turn on the replay buffer when CaptureMac opens", isOn: $preferences.startOnLaunch)
                Toggle("Open CaptureMac at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $preferences.checksForUpdates)
                    .onChange(of: preferences.checksForUpdates) { _, enabled in
                        if enabled { updater.start() } else { updater.stop() }
                    }
                HStack {
                    if let version = updater.availableVersion {
                        Button("Update to \(version)") { updater.install() }
                    } else {
                        Button("Check now") { Task { await updater.check() } }
                            .disabled(updater.state == .checking || updater.state == .installing)
                    }
                    if updater.state == .checking || updater.state == .installing {
                        ProgressView().controlSize(.small)
                    }
                    switch updater.state {
                    case .upToDate:
                        Label("Up to date", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    case .failed(let message):
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    default:
                        EmptyView()
                    }
                    Spacer()
                    Text("Version \(updater.currentVersion)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.saveShortcut) { Actions.bindHotkeys() }
        .onChange(of: preferences.toggleShortcut) { Actions.bindHotkeys() }
        .onChange(of: preferences.recordShortcut) { Actions.bindHotkeys() }
    }

    private var estimatedMemory: Int64 {
        let height = preferences.resolution.maxHeight ?? 1600
        let bitrate = preferences.bitrate(width: height * 16 / 9, height: height)
        let video = Double(bitrate) / 8 * Double(preferences.bufferSeconds)
        let sources =
            (preferences.systemAudio == .off ? 0 : preferences.systemAudio == .split ? 2 : 1)
            + (preferences.microphoneEnabled ? 1 : 0)
        let audio = Double(sources) * PCM.sampleRate * 8 * Double(preferences.bufferSeconds)
        return Int64(video + audio)
    }
}

private struct VideoSettingsView: View {
    @State private var preferences = Preferences.shared
    @State private var hovered: PerformancePreset?
    @State private var hoveringAutomatic = false
    @State private var automaticNote: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(PerformancePreset.allCases) { preset in
                            PresetCard(
                                title: preset.title,
                                symbol: preset.symbol,
                                selected: PerformancePreset.matching(preferences) == preset
                            ) {
                                preset.apply(to: preferences)
                                automaticNote = nil
                            }
                            .onHover { hovered = $0 ? preset : (hovered == preset ? nil : hovered) }
                        }
                        PresetCard(title: "Automatic", symbol: "wand.and.sparkles", selected: false) {
                            let preset = PerformancePreset.recommended
                            preset.apply(to: preferences)
                            automaticNote =
                                "Picked \(preset.title) for \(Hardware.chip) with \(Hardware.memory) of memory"
                        }
                        .onHover { hoveringAutomatic = $0 }
                    }
                    Group {
                        if hoveringAutomatic {
                            Text("Picks a preset based on this Mac's chip, memory and display")
                        } else if let preset = hovered ?? PerformancePreset.matching(preferences) {
                            Text("\(preset.summary). \(preset.detail).")
                        } else {
                            Text("Custom settings")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(nil, value: hovered)
                    if let automaticNote {
                        Label(automaticNote, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Brand.blue)
                    }
                }
            } header: {
                Text("Performance")
            }

            Section {
                Picker("Frame rate", selection: $preferences.frameRate) {
                    ForEach([30, 60, 120], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Resolution", selection: $preferences.resolution) {
                    ForEach(Resolution.allCases) { Text($0.title).tag($0) }
                }
                Picker("Quality", selection: $preferences.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                }
                if preferences.quality == .custom {
                    LabeledContent("Bitrate") {
                        HStack {
                            Slider(value: $preferences.customBitrate, in: 4...100, step: 1)
                            Text("\(Int(preferences.customBitrate)) Mbps")
                                .monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
                Picker("Codec", selection: $preferences.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(
                    preferences.codec == .hevc
                        ? "HEVC makes smaller files, but some sites and older devices can't play it."
                        : "H.264 plays everywhere, including Discord embeds."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show the mouse pointer", isOn: $preferences.showsCursor)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PresetCard: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 22)
                Text(title).font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(selected ? Brand.blue : .primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Brand.blue.opacity(0.12) : Color.primary.opacity(hovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Brand.blue : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct AudioSettings: View {
    @State private var preferences = Preferences.shared
    @State private var devices = InputDevice.all()

    var body: some View {
        Form {
            Section("System audio") {
                Picker("Record", selection: $preferences.systemAudio) {
                    ForEach(SystemAudioMode.allCases) { Text($0.title).tag($0) }
                }
                if preferences.systemAudio != .off {
                    volume(preferences.systemAudio == .split ? "Game volume" : "Volume", value: $preferences.gameVolume)
                }
                if preferences.systemAudio == .split {
                    volume("Other apps volume", value: $preferences.otherVolume)
                }
            }

            Section("Microphone") {
                Toggle("Record microphone", isOn: $preferences.microphoneEnabled)
                if preferences.microphoneEnabled {
                    Picker("Device", selection: $preferences.microphoneUID) {
                        Text("System default").tag(String?.none)
                        ForEach(devices) { device in
                            Text(device.name).tag(String?.some(device.uid))
                        }
                    }
                    volume("Volume", value: $preferences.microphoneVolume)
                }
            }

            Section {
                Picker("Tracks", selection: $preferences.trackLayout) {
                    ForEach(TrackLayout.allCases) { Text($0.title).tag($0) }
                }
                Picker("Bitrate", selection: $preferences.audioBitrate) {
                    ForEach([128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                }
            } header: {
                Text("Clip tracks")
            } footer: {
                Text("Separate tracks let you mute or rebalance a source later in the editor or in another video app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = InputDevice.all() }
    }

    private func volume(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0...2)
                Text("\(Int(value.wrappedValue * 100))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

private struct ClipSettings: View {
    @State private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Save clips to") {
                    HStack {
                        Text(
                            preferences.clipsFolder.path(percentEncoded: false).replacingOccurrences(
                                of: NSHomeDirectory(), with: "~")
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder(for: \.clipsFolder) }
                    }
                }
                Toggle("Put each app's clips in its own folder", isOn: $preferences.groupByApp)
                Toggle("Ask before moving clips to the Trash", isOn: $preferences.confirmsDelete)
            }

            Section {
                Toggle("Show the clip popup", isOn: $preferences.showPopup)
                if preferences.showPopup {
                    Picker("Position", selection: $preferences.popupCorner) {
                        ForEach(ScreenCorner.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Hide after", selection: $preferences.popupSeconds) {
                        ForEach([4.0, 6.0, 10.0, 20.0], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                        Text("Never").tag(0.0)
                    }
                }
                Toggle("Copy it to the clipboard", isOn: $preferences.copiesClip)
                Toggle("Save a copy to another folder", isOn: $preferences.savesCopy)
                if preferences.savesCopy {
                    LabeledContent("Folder") {
                        HStack {
                            Text(
                                preferences.copyFolder.path(percentEncoded: false).replacingOccurrences(
                                    of: NSHomeDirectory(), with: "~")
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            Button("Choose…") { chooseFolder(for: \.copyFolder) }
                        }
                    }
                }
                Toggle("Upload to R2 and copy the link", isOn: $preferences.autoUpload)
                    .disabled(!preferences.r2.isComplete)
                Toggle("Play a sound", isOn: $preferences.playsSound)
            } header: {
                Text("After saving a clip")
            } footer: {
                if preferences.copiesClip && preferences.autoUpload {
                    Text("The link replaces the clip on the clipboard once the upload finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !preferences.r2.isComplete {
                    Text("Set up R2 in the Upload tab to upload clips automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder(for keyPath: ReferenceWritableKeyPath<Preferences, URL>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences[keyPath: keyPath]
        if panel.runModal() == .OK, let url = panel.url {
            preferences[keyPath: keyPath] = url
        }
    }

}

private struct UploadSettings: View {
    @State private var preferences = Preferences.shared
    @State private var secret = Keychain.read(R2Client.secretAccount) ?? ""
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                TextField("Account ID", text: $preferences.r2.accountID)
                TextField("Bucket", text: $preferences.r2.bucket)
                TextField("Access key ID", text: $preferences.r2.accessKeyID)
                SecureField("Secret access key", text: $secret)
                    .onChange(of: secret) { _, value in Keychain.write(value, for: R2Client.secretAccount) }
                TextField("Folder", text: $preferences.r2.folder)
                TextField("Public URL", text: $preferences.r2.publicURL, prompt: Text("https://clips.example.com"))
            } header: {
                Text("Cloudflare R2")
            } footer: {
                Text(
                    "Create an API token with Object Read & Write access to the bucket. The public URL is your bucket's custom domain or its r2.dev address."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Upload as", selection: $preferences.uploadPreset) {
                    Text("Original").tag(ExportPreset.original)
                    ForEach(QualityPreset.allCases) { Text($0.title).tag(ExportPreset.quality($0)) }
                    ForEach(ExportPreset.sizes, id: \.self) { Text("Under \($0) MB").tag(ExportPreset.targetSize($0)) }
                }
            }

            Section {
                HStack {
                    Button("Test connection", action: test)
                        .disabled(testing || !preferences.r2.isComplete || secret.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                            .font(.callout)
                    }
                    Spacer()
                    if let helpURL = URL(string: "https://github.com/whoisjonah/CaptureMac?tab=readme-ov-file#uploading-to-r2") {
                        Link("Need help?", destination: helpURL)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        testing = true
        result = nil
        Task {
            do {
                try await R2Client(settings: preferences.r2).test()
                result = (true, "Connected")
            } catch {
                result = (false, error.localizedDescription)
            }
            testing = false
        }
    }
}
