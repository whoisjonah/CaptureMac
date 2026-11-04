import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

enum PopupAction: Int, CaseIterable {
    case edit, copy, saveAs, upload, reveal, delete, dismiss

    var title: String {
        switch self {
        case .edit: "Edit"
        case .copy: "Copy clip"
        case .saveAs: "Save as"
        case .upload: "Upload"
        case .reveal: "Show in Finder"
        case .delete: "Delete"
        case .dismiss: "Dismiss"
        }
    }

    var shortcut: Shortcut {
        let key: (code: Int, label: String)
        switch self {
        case .edit: key = (kVK_ANSI_E, "E")
        case .copy: key = (kVK_ANSI_C, "C")
        case .saveAs: key = (kVK_ANSI_A, "A")
        case .upload: key = (kVK_ANSI_U, "U")
        case .reveal: key = (kVK_ANSI_F, "F")
        case .delete: key = (kVK_ANSI_D, "D")
        case .dismiss: key = (kVK_ANSI_W, "W")
        }
        return Shortcut(keyCode: UInt32(key.code), modifiers: UInt32(optionKey | shiftKey), key: key.label)
    }

    var label: String { "\(title)  \(shortcut.display)" }
}

@MainActor
@Observable
final class PopupFeedback {
    static let shared = PopupFeedback()
    var text: String?
}

@MainActor
final class ClipPopup {
    static let shared = ClipPopup()

    private var panel: PopupPanel?
    private var dismissTask: Task<Void, Never>?
    private var hovering = false
    private(set) var clipID: Clip.ID?

    func show(_ clip: Clip) {
        clipID = clip.id
        PopupFeedback.shared.text = nil
        bindKeys()
        present(
            ClipPopupView(clipID: clip.id, onHover: { [weak self] in self?.hovered($0) }),
            size: NSSize(width: 252, height: 206))
    }

    func showError(_ message: String) {
        clipID = nil
        unbindKeys()
        present(
            PopupErrorView(message: message, onClose: { [weak self] in self?.close() }),
            size: NSSize(width: 252, height: 72))
    }

    func dismiss(_ clip: Clip) {
        if clipID == clip.id { close() }
    }

    func perform(_ action: PopupAction) {
        guard let id = clipID, let clip = ClipLibrary.shared.clip(id) else { return }
        switch action {
        case .edit:
            close()
            Windows.shared.showEditor(for: clip)
        case .copy:
            ClipLibrary.shared.copyFile(clip)
            PopupFeedback.shared.text = "Copied"
        case .saveAs:
            Actions.saveAs(clip)
        case .upload:
            if clip.shareURL != nil {
                ClipLibrary.shared.copyLink(clip)
                PopupFeedback.shared.text = "Link copied"
            } else {
                Task { await Uploads.shared.upload(clip) }
            }
        case .reveal:
            ClipLibrary.shared.reveal(clip)
        case .delete:
            Actions.delete(clip)
        case .dismiss:
            close()
        }
    }

    private func bindKeys() {
        let preferences = Preferences.shared
        let taken = [preferences.saveShortcut, preferences.toggleShortcut, preferences.recordShortcut].compactMap { $0 }
        for action in PopupAction.allCases where !taken.contains(action.shortcut) {
            Hotkeys.shared.bind(UInt32(100 + action.rawValue), to: action.shortcut) { [weak self] in
                Task { @MainActor in self?.perform(action) }
            }
        }
    }

    private func unbindKeys() {
        for action in PopupAction.allCases {
            Hotkeys.shared.unbind(UInt32(100 + action.rawValue))
        }
    }

    func close() {
        dismissTask?.cancel()
        unbindKeys()
        guard let panel else { return }
        self.panel = nil
        clipID = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func present<Content: View>(_ content: Content, size: NSSize) {
        let panel = self.panel ?? PopupPanel(size: size)
        panel.contentView = NSHostingView(rootView: content.tint(Brand.blue).ignoresSafeArea())
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        if self.panel == nil {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
        self.panel = panel
        scheduleDismiss()
    }

    private func hovered(_ inside: Bool) {
        hovering = inside
        if inside { dismissTask?.cancel() } else { scheduleDismiss() }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        let seconds = Preferences.shared.popupSeconds
        guard seconds > 0 else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.hovering else { return }
            if let id = self.clipID, Uploads.shared.progress[id] != nil {
                self.scheduleDismiss()
                return
            }
            self.close()
        }
    }

    private func origin(for size: NSSize) -> NSPoint {
        let screen =
            NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        let margin: CGFloat = 18
        switch Preferences.shared.popupCorner {
        case .topLeft: return NSPoint(x: frame.minX + margin, y: frame.maxY - size.height - margin)
        case .topRight: return NSPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin)
        case .bottomLeft: return NSPoint(x: frame.minX + margin, y: frame.minY + margin)
        case .bottomRight: return NSPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
        }
    }
}

final class PopupPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = true
    }

    override var canBecomeKey: Bool { true }
}

struct ClipPopupView: View {
    let clipID: Clip.ID
    let onHover: (Bool) -> Void

    @State private var library = ClipLibrary.shared
    @State private var uploads = Uploads.shared
    @State private var thumbnail: NSImage?
    @State private var hoveringThumbnail = false
    @State private var feedback = PopupFeedback.shared
    @State private var hint: String?

    var body: some View {
        if let clip = library.clip(clipID) {
            VStack(spacing: 0) {
                header
                preview(clip)
                toolbar(clip)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .onHover(perform: onHover)
            .task(id: clip.id) { thumbnail = await Thumbnails.shared.image(for: clip) }
            .onChange(of: clip.shareURL) { _, link in
                guard link != nil else { return }
                withAnimation { feedback.text = "Link copied" }
            }
        }
    }

    private var header: some View {
        ZStack {
            WindowDragArea()
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 28, height: 4)
            HStack {
                Button {
                    ClipPopup.shared.perform(.dismiss)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 22)
    }

    private func preview(_ clip: Clip) -> some View {
        ZStack {
            Rectangle().fill(.black)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
            }
            if let label = hint ?? (hoveringThumbnail ? PopupAction.edit.label : nil) {
                Text(label)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity)
                    .id(label)
            }
            VStack {
                Spacer()
                HStack {
                    if let text = feedback.text {
                        Label(text, systemImage: text == "Copied" ? "doc.on.doc" : "link")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                    }
                    Spacer()
                    Text(Format.duration(clip.duration))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(6)
            }
        }
        .frame(height: 136)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hoveringThumbnail = inside } }
        .onTapGesture { ClipPopup.shared.perform(.edit) }
        .onDrag { NSItemProvider(contentsOf: clip.url) ?? NSItemProvider() }
    }

    private func toolbar(_ clip: Clip) -> some View {
        HStack(spacing: 2) {
            PopupButton(symbol: "pencil", label: PopupAction.edit.label, hint: $hint) {
                ClipPopup.shared.perform(.edit)
            }
            .keyboardShortcut(.defaultAction)
            PopupButton(symbol: "doc.on.doc", label: PopupAction.copy.label, hint: $hint) {
                ClipPopup.shared.perform(.copy)
            }
            .keyboardShortcut("c")
            PopupButton(symbol: "square.and.arrow.down", label: PopupAction.saveAs.label, hint: $hint) {
                ClipPopup.shared.perform(.saveAs)
            }
            .keyboardShortcut("s")
            uploadButton(clip)
            PopupButton(symbol: "folder", label: PopupAction.reveal.label, hint: $hint) {
                ClipPopup.shared.perform(.reveal)
            }
            PopupButton(symbol: "trash", label: PopupAction.delete.label, hint: $hint) {
                ClipPopup.shared.perform(.delete)
            }
            .keyboardShortcut(.delete)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    @ViewBuilder
    private func uploadButton(_ clip: Clip) -> some View {
        if let progress = uploads.progress[clip.id] {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 30)
        } else if clip.shareURL != nil {
            PopupButton(symbol: "link", label: "Copy link  \(PopupAction.upload.shortcut.display)", hint: $hint) {
                ClipPopup.shared.perform(.upload)
            }
        } else {
            PopupButton(
                symbol: uploads.failures[clip.id] == nil ? "icloud.and.arrow.up" : "exclamationmark.icloud",
                label: uploads.failures[clip.id] ?? PopupAction.upload.label, hint: $hint
            ) {
                ClipPopup.shared.perform(.upload)
            }
            .keyboardShortcut("u")
        }
    }
}

struct PopupButton: View {
    let symbol: String
    let label: String
    @Binding var hint: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    hovering ? Color.primary.opacity(0.1) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            withAnimation(.easeOut(duration: 0.12)) {
                if inside {
                    hint = label
                } else if hint == label {
                    hint = nil
                }
            }
        }
    }
}

struct PopupErrorView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
