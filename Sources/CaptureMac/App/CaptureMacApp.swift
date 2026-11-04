import AppKit
import SwiftUI

@main
struct CaptureMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var recorder = Recorder.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(nsImage: Brand.menuBarImage(menuBarState))
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarState: Brand.MenuBarState {
        if recorder.isRecordingSession { return .recording }
        return recorder.status == .buffering ? .buffering : .idle
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            Actions.bindHotkeys()
            Updater.shared.start()
            Recorder.shared.onClipSaved = { clip in
                Actions.clipSaved(clip)
            }
            let preferences = Preferences.shared
            if !preferences.onboarded || !CGPreflightScreenCaptureAccess() {
                Windows.shared.showOnboarding()
            } else if preferences.startOnLaunch {
                Recorder.shared.start()
            }
        }
    }

    private let launched = Date()

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, Date().timeIntervalSince(launched) > 2 else { return true }
        MainActor.assumeIsolated { Windows.shared.showLibrary() }
        return false
    }
}
