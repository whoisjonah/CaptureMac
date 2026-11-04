import SwiftUI

enum LibraryFilter: Hashable {
    case all
    case favorites
    case uploaded
    case recordings
    case app(String)
}

struct LibraryView: View {
    @State private var library = ClipLibrary.shared
    @State private var preferences = Preferences.shared
    @State private var filter: LibraryFilter? = .all
    @State private var search = ""
    @State private var selection: Clip.ID?
    @State private var renaming: Clip?

    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section {
                    Label("All clips", systemImage: "film.stack").tag(LibraryFilter.all)
                    Label("Recordings", systemImage: "record.circle").tag(LibraryFilter.recordings)
                    Label("Favorites", systemImage: "star").tag(LibraryFilter.favorites)
                    Label("Uploaded", systemImage: "link").tag(LibraryFilter.uploaded)
                }
                Section("Apps") {
                    ForEach(library.apps, id: \.name) { app in
                        HStack {
                            AppIcon(bundleID: app.bundleID).frame(width: 16, height: 16)
                            Text(app.name)
                            Spacer()
                            Text("\(app.count)").foregroundStyle(.secondary).font(.caption)
                        }
                        .tag(LibraryFilter.app(app.name))
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                CaptureMacWordmark(size: 17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            content
                .navigationTitle(title)
                .searchable(text: $search, placement: .toolbar, prompt: "Search clips")
                .toolbar {
                    ToolbarItem {
                        Slider(value: $preferences.thumbnailSize, in: 150...380)
                            .frame(width: 110)
                            .help("Thumbnail size")
                    }
                    ToolbarItem {
                        Button {
                            NSWorkspace.shared.open(preferences.clipsFolder)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Open clips folder")
                    }
                }
        }
        .sheet(item: $renaming) { clip in
            RenameSheet(clip: clip)
        }
    }

    private var title: String {
        switch filter ?? .all {
        case .all: "All clips"
        case .favorites: "Favorites"
        case .uploaded: "Uploaded"
        case .recordings: "Recordings"
        case .app(let name): name
        }
    }

    private var clips: [Clip] {
        library.clips.filter { clip in
            let matchesFilter: Bool = switch filter ?? .all {
            case .all: true
            case .favorites: clip.favorite
            case .uploaded: clip.shareURL != nil
            case .recordings: clip.isRecording
            case .app(let name): clip.appName == name
            }
            return matchesFilter && (search.isEmpty || clip.title.localizedCaseInsensitiveContains(search) || clip.appName.localizedCaseInsensitiveContains(search))
        }
    }

    @ViewBuilder
    private var content: some View {
        if clips.isEmpty {
            VStack(spacing: 16) {
                ViewfinderMark(frameColor: .secondary.opacity(0.5), dotColor: Brand.blue)
                    .frame(width: 64, height: 64)
                VStack(spacing: 6) {
                    Text(library.clips.isEmpty ? "No clips yet" : "Nothing here")
                        .font(.title2.weight(.semibold))
                    if library.clips.isEmpty, let shortcut = preferences.saveShortcut {
                        Text("Press \(shortcut.display) while you play to save the last \(Format.bufferLength(preferences.bufferSeconds)).")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.paper)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: preferences.thumbnailSize), spacing: 20)], spacing: 24) {
                    ForEach(clips) { clip in
                        ClipCard(clip: clip, selected: selection == clip.id)
                            .onTapGesture(count: 2) { Windows.shared.showEditor(for: clip) }
                            .simultaneousGesture(TapGesture().onEnded { selection = clip.id })
                            .contextMenu { menu(for: clip) }
                            .onDrag { NSItemProvider(contentsOf: clip.url) ?? NSItemProvider() }
                    }
                }
                .padding(24)
            }
            .background(Brand.paper)
        }
    }

    @ViewBuilder
    private func menu(for clip: Clip) -> some View {
        Button("Edit") { Windows.shared.showEditor(for: clip) }
        Button(clip.favorite ? "Remove from Favorites" : "Add to Favorites") {
            var updated = clip
            updated.favorite.toggle()
            library.update(updated)
        }
        Button("Rename") { renaming = clip }
        Divider()
        Button("Upload") { Task { await Uploads.shared.upload(clip) } }
            .disabled(Uploads.shared.isUploading(clip))
        if clip.shareURL != nil {
            Button("Copy Link") { library.copyLink(clip) }
        }
        Button("Copy Clip") { library.copyFile(clip) }
        Button("Save As…") { Actions.saveAs(clip) }
        Button("Show in Finder") { library.reveal(clip) }
        Divider()
        Button("Move to Trash", role: .destructive) { Actions.delete(clip) }
    }
}

struct ClipCard: View {
    let clip: Clip
    let selected: Bool

    @State private var uploads = Uploads.shared
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ClipThumbnail(clip: clip)
                .overlay(alignment: .bottomTrailing) {
                    Text(Format.duration(clip.duration))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        if clip.isRecording { badge("record.circle") }
                        if clip.favorite { badge("star.fill") }
                        if clip.shareURL != nil { badge("link") }
                    }
                    .padding(6)
                }
                .overlay {
                    if let progress = uploads.progress[clip.id] {
                        ZStack {
                            Color.black.opacity(0.45)
                            ProgressView(value: progress).progressViewStyle(.circular).tint(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Brand.blue : Color.primary.opacity(0.06), lineWidth: selected ? 3 : 1)
                }
                .scaleEffect(hovering ? 1.015 : 1)
                .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 8 : 3, y: 2)
                .animation(.easeOut(duration: 0.15), value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack {
                    Text(Format.relative(clip.createdAt))
                    Spacer()
                    Text(Format.bytes(clip.size))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(.black.opacity(0.55), in: Circle())
    }
}

struct AppIcon: View {
    let bundleID: String?

    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "display").foregroundStyle(.secondary)
        }
    }
}

struct RenameSheet: View {
    let clip: Clip
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(clip: Clip) {
        self.clip = clip
        _name = State(initialValue: clip.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename clip").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func save() {
        ClipLibrary.shared.rename(clip, to: name)
        dismiss()
    }
}
