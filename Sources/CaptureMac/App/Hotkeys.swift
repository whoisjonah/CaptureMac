import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let defaultSave = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey), key: "S")
    static let defaultToggle = Shortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | shiftKey), key: "B")
    static let defaultRecord = Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey), key: "R")

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }

        let keyCode = Int(event.keyCode)
        let name = Self.specialKeys[keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let isFunctionKey = Self.functionKeys.contains(keyCode)
        guard !name.isEmpty, modifiers != 0 || isFunctionKey else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers, key: name)
    }

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    ]

    private static let specialKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
}

final class Hotkeys {
    static let shared = Hotkeys()

    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            hotkeys.actions[hotKeyID.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func bind(_ id: UInt32, to shortcut: Shortcut?, action: @escaping () -> Void) {
        unbind(id)
        guard let shortcut else { return }
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x434D_4143), id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return }
        registered[id] = reference
        actions[id] = action
    }

    func unbind(_ id: UInt32) {
        if let reference = registered.removeValue(forKey: id) {
            UnregisterEventHotKey(reference)
        }
        actions[id] = nil
    }
}
