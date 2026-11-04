import AVKit
import SwiftUI

struct EditorView: View {
    let clipID: Clip.ID

    @State private var model: EditorModel?
    @State private var library = ClipLibrary.shared

    var body: some View {
        Group {
            if let model {
                EditorContent(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .task {
            guard model == nil, let clip = library.clip(clipID) else { return }
            let model = EditorModel(clip: clip)
            self.model = model
            await model.load()
        }
        .onDisappear { model?.teardown() }
    }
}

private struct EditorContent: View {
    @Bindable var model: EditorModel
    @State private var uploads = Uploads.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                PlayerSurface(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture { model.togglePlayback() }
                transport
                TrimTimeline(model: model)
                    .frame(height: 64)
            }
            .padding(16)

            Divider()

            inspector
                .frame(width: 280)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { model.togglePlayback(); return .handled }
        .onKeyPress("i") { model.setIn(); return .handled }
        .onKeyPress("o") { model.setOut(); return .handled }
        .onKeyPress("s") { model.split(); return .handled }
        .onKeyPress(.delete) { model.toggleRemoved(); return .handled }
        .onKeyPress(.leftArrow) { model.step(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.step(by: 1); return .handled }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button(action: model.togglePlayback) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 26)
            }
            .buttonStyle(.borderless)

            Text("\(Format.precise(model.currentTime)) / \(Format.precise(model.duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button("Set start") { model.setIn() }
                .help("I")
            Button("Set end") { model.setOut() }
                .help("O")
            Divider().frame(height: 16)
            Button {
                model.split()
            } label: {
                Label("Split", systemImage: "scissors")
            }
            .help("Split at the playhead (S)")
            if model.segments.count > 1 {
                let target = model.selectedSegment ?? model.segment(at: model.currentTime)
                let isRemoved = target.map { model.removed.contains($0) } ?? false
                Button {
                    model.toggleRemoved()
                } label: {
                    Label(isRemoved ? "Restore" : "Cut", systemImage: isRemoved ? "arrow.uturn.backward" : "trash")
                }
                .help(isRemoved ? "Put this part back (Delete)" : "Take this part out (Delete)")
            }
            if model.isEdited || !model.splits.isEmpty {
                Button("Reset") { model.resetEdits() }
            }
        }
        .controlSize(.small)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.clip.title).font(.headline).lineLimit(2)
                    Text("\(model.clip.appName), \(model.clip.width)×\(model.clip.height), \(Format.bytes(model.clip.size))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !model.tracks.isEmpty {
                    audioSection
                }

                exportSection
            }
            .padding(18)
        }
        .background(.background.secondary)
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Audio").font(.subheadline.weight(.semibold))
                Spacer()
                if model.customMix {
                    Button("Reset") { model.resetMix() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            ForEach($model.tracks) { $track in
                if !(model.hasMixedTrack && track.id == 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button {
                                track.muted.toggle()
                                model.updateMix()
                            } label: {
                                Image(systemName: track.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .frame(width: 18)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(track.muted ? .secondary : .primary)
                            Text(track.name).font(.callout)
                            Spacer()
                            Text("\(Int(track.volume * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $track.volume, in: 0...2) { editing in
                            if !editing { model.updateMix() }
                        }
                        .controlSize(.small)
                        .disabled(track.muted)
                    }
                }
            }
            if model.hasMixedTrack && !model.customMix {
                Text("Playing the mixed track. Change a source to remix it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.subheadline.weight(.semibold))

            Picker("Size", selection: $model.preset) {
                Text("Original").tag(ExportPreset.original)
                Section("Quality") {
                    ForEach(QualityPreset.allCases) { quality in
                        Text(quality.title).tag(ExportPreset.quality(quality))
                    }
                }
                Section("File size") {
                    ForEach(ExportPreset.sizes, id: \.self) { size in
                        Text("Under \(size) MB").tag(ExportPreset.targetSize(size))
                    }
                }
            }
            .labelsHidden()

            if let plan = model.plan {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Length").foregroundStyle(.secondary)
                        Text(Format.duration(model.editedDuration))
                    }
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text(plan.passthrough ? "Unchanged" : "\(plan.width)×\(plan.height), \(Int(plan.frameRate)) fps")
                    }
                    GridRow {
                        Text("Estimate").foregroundStyle(.secondary)
                        Text("About \(Format.bytes(plan.estimatedBytes(duration: model.editedDuration)))")
                    }
                }
                .font(.caption)
            }

            if let progress = model.exportProgress ?? uploads.progress[model.clip.id] {
                ProgressView(value: progress)
            }

            VStack(spacing: 8) {
                Button {
                    Task { await model.upload() }
                } label: {
                    Label("Upload and copy link", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

                HStack(spacing: 8) {
                    Button {
                        Task { await model.saveCopy() }
                    } label: {
                        Text("Save copy").frame(maxWidth: .infinity)
                    }
                    Button {
                        Task { await model.saveAs() }
                    } label: {
                        Text("Save as…").frame(maxWidth: .infinity)
                    }
                }
                .disabled(busy)
            }
            .controlSize(.large)

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var busy: Bool {
        model.exportProgress != nil || uploads.isUploading(model.clip)
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
