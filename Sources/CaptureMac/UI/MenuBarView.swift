import ScreenCaptureKit
import SwiftUI

struct MenuBarView: View {
    @State private var recorder = Recorder.shared
    @State private var preferences = Preferences.shared
    @State private var library = ClipLibrary.shared
    @State private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let version = updater.availableVersion {
                update(version)
            }
            statusCard
            SourcePicker()
            if !recorder.levels.isEmpty {
                meters
            }
            actions
            if !library.clips.isEmpty {
                recent
            }
        }
        .padding(14)
        .frame(width: 320)
        .tint(Brand.blue)
        .task { await recorder.refreshSources() }
    }

    private var header: some View {
        HStack {
            CaptureMacWordmark(size: 17)
            Spacer()
            IconButton(symbol: "rectangle.stack", help: "Library") { Windows.shared.showLibrary() }
            IconButton(symbol: "gearshape", help: "Settings") { Windows.shared.showSettings() }
            IconButton(symbol: "power", help: "Quit CaptureMac") { NSApp.terminate(nil) }
        }
        .padding(.bottom, 2)
    }

    private func update(_ version: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Brand.blue)
            Text("CaptureMac \(version) is out")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Update") { updater.install() }
                .controlSize(.small)
                .disabled(recorder.isRecordingSession)
        }
        .padding(12)
        .background(Card())
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatusDot(color: statusColor, pulsing: recorder.isRecordingSession || recorder.status == .buffering)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.system(.headline, design: .rounded))
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("Replay buffer", isOn: Binding(get: { recorder.replayEnabled }, set: { _ in recorder.toggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(recorder.isRecordingSession && recorder.sessionOnly)
            }
            if recorder.replayEnabled && recorder.status == .buffering {
                ProgressView(value: min(recorder.bufferedSeconds / Double(preferences.bufferSeconds), 1))
                    .progressViewStyle(.linear)
                    .tint(Brand.blue)
            }
        }
        .padding(12)
        .background(Card())
    }

    private var statusColor: Color {
        if recorder.isRecordingSession { return Brand.record }
        switch recorder.status {
        case .buffering: return Brand.blue
        case .starting, .waiting: return .orange
        case .stopped: return .secondary
        case .failed: return .yellow
        }
    }

    private var statusTitle: String {
        if recorder.isRecordingSession { return "Recording" }
        switch recorder.status {
        case .buffering: return "Replay buffer on"
        case .starting: return "Starting"
        case .waiting: return "Waiting"
        case .stopped: return "Ready"
        case .failed: return "Couldn't start"
        }
    }

    private var statusDetail: String {
        if let started = recorder.sessionStartedAt {
            return recorder.sessionOnly ? "Started at \(started.formatted(date: .omitted, time: .shortened))" : "The replay buffer keeps running too"
        }
        switch recorder.status {
        case .buffering:
            return "\(Int(recorder.bufferedSeconds))s of \(Format.bufferLength(preferences.bufferSeconds)) kept, \(Format.bytes(Int64(recorder.memoryBytes))) in memory"
        case .waiting(let message), .failed(let message):
            return message
        case .starting:
            return "Setting up capture"
        case .stopped:
            return Brand.slogan
        }
    }

    private var meters: some View {
        VStack(spacing: 7) {
            ForEach(AudioRole.allCases.filter { recorder.levels[$0] != nil }, id: \.self) { role in
                HStack(spacing: 10) {
                    Image(systemName: role == .microphone ? "mic.fill" : "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(role.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    LevelMeterView(level: recorder.levels[role] ?? 0)
                }
            }
            if let error = recorder.audioError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Actions.saveClip()
            } label: {
                VStack(spacing: 3) {
                    if recorder.isSaving {
                        ProgressView().controlSize(.small).frame(height: 18)
                    } else {
                        Image(systemName: "film.stack.fill").font(.system(size: 16, weight: .semibold))
                    }
                    Text("Save clip").font(.callout.weight(.semibold))
                    Text(preferences.saveShortcut?.display ?? " ")
                        .font(.caption2)
                        .opacity(0.75)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(ActionButtonStyle(fill: Brand.blue))
            .disabled(!recorder.replayEnabled || recorder.status != .buffering || recorder.isSaving)

            Button {
                recorder.toggleSession()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: recorder.isRecordingSession ? "stop.fill" : "record.circle")
                        .font(.system(size: 16, weight: .semibold))
                    if let started = recorder.sessionStartedAt {
                        Text(timerInterval: started...Date.distantFuture, countsDown: false)
                            .font(.callout.weight(.semibold).monospacedDigit())
                    } else {
                        Text("Record").font(.callout.weight(.semibold))
                    }
                    Text(preferences.recordShortcut?.display ?? " ")
                        .font(.caption2)
                        .opacity(0.75)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(ActionButtonStyle(
                fill: recorder.isRecordingSession ? Brand.record : Color.primary.opacity(0.08),
                foreground: recorder.isRecordingSession ? .white : .primary
            ))
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Show all") { Windows.shared.showLibrary() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Brand.blue)
            }
            HStack(spacing: 8) {
                ForEach(library.clips.prefix(3)) { clip in
                    Button {
                        Windows.shared.showEditor(for: clip)
                    } label: {
                        ClipThumbnail(clip: clip, cornerRadius: 8)
                    }
                    .buttonStyle(.plain)
                    .help(clip.title)
                }
                ForEach(0..<max(0, 3 - library.clips.count), id: \.self) { _ in
                    Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                }
            }
        }
    }
}

struct Card: View {
    var cornerRadius: CGFloat = 14

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

struct StatusDot: View {
    let color: Color
    let pulsing: Bool

    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 22, height: 22)
                .scaleEffect(pulsing && expanded ? 1 : 0.6)
                .opacity(pulsing ? (expanded ? 0 : 1) : 0)
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { expanded = true }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct ActionButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color = .white

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(fill.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LevelMeterView: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            let decibels = 20 * log10(max(level, 0.0001))
            let fraction = CGFloat(max(0, min(1, (decibels + 60) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(fraction > 0.92 ? Brand.record : Brand.blue)
                    .frame(width: proxy.size.width * fraction)
                    .animation(.linear(duration: 0.06), value: fraction)
            }
        }
        .frame(height: 6)
    }
}

struct SourcePicker: View {
    @State private var recorder = Recorder.shared
    @State private var preferences = Preferences.shared

    var body: some View {
        Menu {
            Section("Displays") {
                ForEach(recorder.sources.displays, id: \.displayID) { display in
                    pick(.display(display.displayID), title: CaptureTarget.display(display.displayID).title, detail: "\(display.width)×\(display.height)")
                }
            }
            Section("Apps") {
                ForEach(recorder.sources.apps, id: \.processID) { app in
                    pick(.app(bundleID: app.bundleIdentifier, name: app.applicationName), title: app.applicationName, detail: nil)
                }
            }
            Menu("Windows") {
                ForEach(recorder.sources.windows.filter { $0.isOnScreen && !($0.title ?? "").isEmpty }, id: \.windowID) { window in
                    let app = window.owningApplication
                    pick(
                        .window(title: window.title ?? "", bundleID: app?.bundleIdentifier ?? "", name: app?.applicationName ?? ""),
                        title: window.title ?? "",
                        detail: app?.applicationName
                    )
                }
            }
        } label: {
            HStack(spacing: 10) {
                SourceIcon(target: preferences.target)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preferences.target.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Card(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var kind: String {
        switch preferences.target {
        case .display: "Entire display"
        case .app: "App, follows its main window"
        case .window: "Single window"
        }
    }

    private func pick(_ target: CaptureTarget, title: String, detail: String?) -> some View {
        Button {
            preferences.target = target
        } label: {
            if preferences.target == target {
                Label(detail.map { "\(title)  \($0)" } ?? title, systemImage: "checkmark")
            } else {
                Text(detail.map { "\(title)  \($0)" } ?? title)
            }
        }
    }
}

struct SourceIcon: View {
    let target: CaptureTarget

    var body: some View {
        if let bundleID = target.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        } else {
            Image(systemName: target.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Brand.blue)
                .frame(width: 28, height: 28)
                .background(Brand.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

struct ClipThumbnail: View {
    let clip: Clip
    var cornerRadius: CGFloat = 10

    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.85))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ViewfinderMark(frameColor: .white.opacity(0.25), dotColor: .white.opacity(0.25))
                        .padding(18)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: clip.id) { image = await Thumbnails.shared.image(for: clip) }
    }
}
