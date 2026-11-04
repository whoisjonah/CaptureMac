import AppKit
import CoreMedia
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class Uploads {
    static let shared = Uploads()

    private(set) var progress: [Clip.ID: Double] = [:]
    private(set) var failures: [Clip.ID: String] = [:]

    func isUploading(_ clip: Clip) -> Bool {
        progress[clip.id] != nil
    }

    @discardableResult
    func upload(_ clip: Clip, preset: ExportPreset? = nil, ranges: [TrimRange]? = nil, volumes: [Float]? = nil) async -> URL? {
        guard progress[clip.id] == nil else { return nil }
        progress[clip.id] = 0
        failures[clip.id] = nil
        defer { progress[clip.id] = nil }

        let preferences = Preferences.shared
        let preset = preset ?? preferences.uploadPreset
        var file = clip.url
        var temporary: URL?

        do {
            let client = try R2Client(settings: preferences.r2)
            let needsExport = preset != .original || ranges != nil || volumes != nil
            if needsExport {
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
                let id = clip.id
                try await Exporter.export(clip.url, ranges: ranges?.map(\.range), preset: preset, volumes: volumes, to: output) { value in
                    Task { @MainActor in Uploads.shared.progress[id] = value * 0.5 }
                }
                file = output
                temporary = output
            }
            let base = needsExport ? 0.5 : 0.0
            let id = clip.id
            let link = try await client.upload(file, key: R2Client.makeKey(for: file, folder: preferences.r2.folder)) { value in
                Task { @MainActor in Uploads.shared.progress[id] = base + value * (1 - base) }
            }
            if let temporary { try? FileManager.default.removeItem(at: temporary) }

            if var updated = ClipLibrary.shared.clip(clip.id) {
                updated.shareURL = link
                ClipLibrary.shared.update(updated)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            return link
        } catch {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            failures[clip.id] = error.localizedDescription
            return nil
        }
    }
}

struct TrimRange: Equatable {
    var start: Double
    var end: Double

    var range: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }
}

@MainActor
enum Actions {
    static func bindHotkeys() {
        let preferences = Preferences.shared
        Hotkeys.shared.bind(1, to: preferences.saveShortcut) { Task { @MainActor in saveClip() } }
        Hotkeys.shared.bind(2, to: preferences.toggleShortcut) { Task { @MainActor in Recorder.shared.toggle() } }
        Hotkeys.shared.bind(3, to: preferences.recordShortcut) { Task { @MainActor in Recorder.shared.toggleSession() } }
    }

    static func unbindHotkeys() {
        Hotkeys.shared.unbind(1)
        Hotkeys.shared.unbind(2)
        Hotkeys.shared.unbind(3)
    }

    static func saveClip() {
        let recorder = Recorder.shared
        guard recorder.replayEnabled, recorder.status == .buffering else {
            ClipPopup.shared.showError("replay buffer's off")
            return
        }
        guard !recorder.isSaving else { return }
        Task {
            do {
                _ = try await recorder.saveClip()
            } catch {
                ClipPopup.shared.showError(error.localizedDescription)
            }
        }
    }

    static func clipSaved(_ clip: Clip) {
        let preferences = Preferences.shared
        if preferences.playsSound {
            NSSound(named: "Pop")?.play()
        }
        if preferences.savesCopy {
            let destination = preferences.copyFolder.appendingPathComponent(clip.url.lastPathComponent)
            try? FileManager.default.createDirectory(at: preferences.copyFolder, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: clip.url, to: destination)
        }
        if preferences.copiesClip {
            ClipLibrary.shared.copyFile(clip)
        }
        if preferences.showPopup {
            ClipPopup.shared.show(clip)
        }
        if preferences.autoUpload && preferences.r2.isComplete {
            Task { await Uploads.shared.upload(clip) }
        }
    }

    static func saveAs(_ clip: Clip) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = clip.url.lastPathComponent
        panel.allowedContentTypes = [.mpeg4Movie]
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: clip.url, to: destination)
    }

    static func delete(_ clip: Clip) {
        let preferences = Preferences.shared
        if preferences.confirmsDelete {
            let alert = NSAlert()
            alert.messageText = "Move \u{201C}\(clip.title)\u{201D} to the Trash?"
            alert.informativeText = clip.shareURL == nil ? "You can still get it back from the Trash." : "You can still get it back from the Trash, and its link keeps working."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            NSApp.activate()
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                preferences.confirmsDelete = false
            }
            guard response == .alertFirstButtonReturn else { return }
        }
        ClipPopup.shared.dismiss(clip)
        Windows.shared.closeEditor(for: clip.id)
        ClipLibrary.shared.delete(clip)
    }
}
