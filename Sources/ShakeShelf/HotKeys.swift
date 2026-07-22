import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut.
///
/// Uses Carbon's RegisterEventHotKey rather than a global NSEvent monitor
/// because the Carbon API needs no Accessibility permission — a global key
/// monitor would make a menu-bar utility demand the scariest prompt in
/// System Settings just to open a panel.
struct HotKeyCombo: Equatable, Codable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    /// Rendered at capture time from the live keyboard layout.
    let display: String

    static func from(event: NSEvent) -> HotKeyCombo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        // Shift alone is not enough: a shortcut without ⌘/⌥/⌃ would swallow
        // ordinary typing in every app on the system.
        let hasRealModifier = flags.contains(.command)
            || flags.contains(.option)
            || flags.contains(.control)
        guard hasRealModifier else { return nil }

        let symbols = (flags.contains(.control) ? "⌃" : "")
            + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "")
        guard let keyName = keyName(for: event) else { return nil }
        return HotKeyCombo(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbon,
            display: symbols + keyName
        )
    }

    private static func keyName(for event: NSEvent) -> String? {
        if let special = specialKeyNames[Int(event.keyCode)] { return special }
        // charactersIgnoringModifiers reflects the user's actual layout, so a
        // French or Dvorak keyboard shows the key they really pressed.
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
        let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
    ]
}

enum HotKeyAction: String, CaseIterable, Codable {
    case toggleShelf
    case newNote
    case captureRegion

    var title: String {
        switch self {
        case .toggleShelf: return "Show or hide the shelf"
        case .newNote: return "New note"
        case .captureRegion: return "Capture a screen region"
        }
    }

    var identifier: UInt32 {
        switch self {
        case .toggleShelf: return 1
        case .newNote: return 2
        case .captureRegion: return 3
        }
    }

    var defaultCombo: HotKeyCombo {
        switch self {
        case .toggleShelf:
            return HotKeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: Self.controlOptionCommand, display: "⌃⌥⌘S")
        case .newNote:
            return HotKeyCombo(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: Self.controlOptionCommand, display: "⌃⌥⌘N")
        case .captureRegion:
            return HotKeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: Self.controlOptionCommand, display: "⌃⌥⌘4")
        }
    }

    private static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)
}

final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private let signature: OSType = 0x53534846 // 'SSHF'

    private init() {}

    @discardableResult
    func register(_ action: HotKeyAction, combo: HotKeyCombo, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(action)

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: action.identifier)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("ShakeShelf: could not register \(combo.display) (status \(status))")
            return false
        }
        refs[action.identifier] = ref
        handlers[action.identifier] = handler
        return true
    }

    func unregister(_ action: HotKeyAction) {
        if let ref = refs[action.identifier] {
            UnregisterEventHotKey(ref)
            refs[action.identifier] = nil
        }
        handlers[action.identifier] = nil
    }

    /// Suspends every shortcut, so recording a new one can't fire the old one.
    func unregisterAll() {
        HotKeyAction.allCases.forEach(unregister)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // The callback must be a capture-free C function pointer, so it goes
        // through the shared instance rather than closing over self.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                HotKeyCenter.shared.fire(hotKeyID.id)
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
        handlerInstalled = true
    }

    fileprivate func fire(_ identifier: UInt32) {
        guard let handler = handlers[identifier] else { return }
        DispatchQueue.main.async(execute: handler)
    }
}
