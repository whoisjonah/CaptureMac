import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "Type shortcut" : shortcut?.display ?? "None")
                    .font(.callout)
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)

            if shortcut != nil && !recording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        Actions.unbindHotkeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            if let recorded = Shortcut(event: event) {
                shortcut = recorded
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            Actions.bindHotkeys()
        }
    }
}
