import AppKit
import Carbon.HIToolbox

/// Click a field, press the combination you want. Escape cancels, Delete
/// clears the shortcut entirely.
final class ShortcutRecorderView: NSView {
    var combo: HotKeyCombo? {
        didSet { needsDisplay = true }
    }
    var onChange: ((HotKeyCombo?) -> Void)?

    private var recording = false {
        didSet {
            needsDisplay = true
            // While recording, the app's own shortcuts must not fire — the
            // user is very likely to press the one they're replacing.
            if recording {
                HotKeyCenter.shared.unregisterAll()
            } else {
                onRecordingEnded?()
            }
        }
    }
    var onRecordingEnded: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        rounded.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        rounded.lineWidth = recording ? 2 : 1
        rounded.stroke()

        let text: String
        let color: NSColor
        if recording {
            text = "Press keys…"
            color = .controlAccentColor
        } else if let combo {
            text = combo.display
            color = .labelColor
        } else {
            text = "Click to set"
            color = .tertiaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .medium : .regular),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    // Command-key combinations are dispatched as key equivalents before
    // keyDown, so ⌘S would trigger a menu item instead of being captured.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    private func capture(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            recording = false
            return
        case kVK_Delete, kVK_ForwardDelete:
            // Only clears when pressed alone; ⌘⌫ is a legitimate shortcut.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.isEmpty {
                recording = false
                combo = nil
                onChange?(nil)
                return
            }
        default:
            break
        }

        guard let captured = HotKeyCombo.from(event: event) else {
            NSSound.beep()
            return
        }
        recording = false
        combo = captured
        onChange?(captured)
    }
}

final class ShortcutsWindowController: NSWindowController {
    private static var active: ShortcutsWindowController?

    private var onChange: () -> Void

    static func present(onChange: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let active {
            NSApp.activate(ignoringOtherApps: true)
            active.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ShortcutsWindowController(onChange: onChange)
        active = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let grid = NSGridView()
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false

        for action in HotKeyAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            label.alignment = .right

            let recorder = ShortcutRecorderView()
            recorder.combo = Prefs.hotKey(for: action)
            recorder.onChange = { [weak self] combo in
                Prefs.setHotKey(combo, for: action)
                self?.onChange()
            }
            // Re-arm the other shortcuts after a recording ends, whether it
            // was completed or cancelled.
            recorder.onRecordingEnded = { [weak self] in
                self?.onChange()
            }
            recorder.translatesAutoresizingMaskIntoConstraints = false
            recorder.widthAnchor.constraint(equalToConstant: 170).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 26).isActive = true

            grid.addRow(with: [label, recorder])
        }

        let hint = NSTextField(wrappingLabelWithString:
            "Click a field and press the keys you want. Escape cancels, Delete clears. "
            + "Shortcuts need ⌘, ⌥ or ⌃ so they don't swallow ordinary typing.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(grid)
        contentView.addSubview(hint)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            hint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            hint.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
        ])
    }

    override func close() {
        super.close()
        if ShortcutsWindowController.active === self {
            ShortcutsWindowController.active = nil
        }
    }
}

extension ShortcutsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if ShortcutsWindowController.active === self {
            ShortcutsWindowController.active = nil
        }
        onChange()
    }
}
