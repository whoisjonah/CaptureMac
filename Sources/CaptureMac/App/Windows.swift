import AppKit
import SwiftUI

@MainActor
final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()

    private var library: NSWindow?
    private var settings: NSWindow?
    private var onboarding: NSWindow?
    private var editors: [Clip.ID: NSWindow] = [:]

    func showLibrary() {
        library = present(library, title: "CaptureMac", size: NSSize(width: 980, height: 640), autosave: "Library") {
            LibraryView()
        }
    }

    func showSettings() {
        settings = present(settings, title: "Settings", size: NSSize(width: 620, height: 520), resizable: false, autosave: "Settings") {
            SettingsView()
        }
    }

    func showOnboarding() {
        onboarding = present(onboarding, title: "Welcome to CaptureMac", size: NSSize(width: 480, height: 600), resizable: false, autosave: nil, hero: true) {
            OnboardingView { [weak self] in
                self?.onboarding?.close()
            }
        }
    }

    func showEditor(for clip: Clip) {
        editors[clip.id] = present(editors[clip.id], title: clip.title, size: NSSize(width: 1080, height: 700), autosave: "Editor") {
            EditorView(clipID: clip.id)
        }
    }

    func closeEditor(for id: Clip.ID) {
        editors[id]?.close()
    }

    private func present<Content: View>(
        _ existing: NSWindow?, title: String, size: NSSize, resizable: Bool = true,
        autosave: String?, hero: Bool = false, content: () -> Content
    ) -> NSWindow {
        if let existing {
            activate(existing)
            return existing
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content().tint(Brand.blue))
        if hero {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }
        window.setContentSize(size)
        window.delegate = self
        window.center()
        if let autosave { window.setFrameAutosaveName(autosave) }
        activate(window)
        return window
    }

    private func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === library { library = nil }
        if window === settings { settings = nil }
        if window === onboarding { onboarding = nil }
        editors = editors.filter { $0.value !== window }
        if library == nil && settings == nil && onboarding == nil && editors.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
