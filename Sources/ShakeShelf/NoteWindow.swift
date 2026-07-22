import AppKit

/// A scratch pad for text that never touched the clipboard or a drag: open
/// it, type or paste, save it to the shelf. Doubles as the editor for
/// snippets already on the shelf.
final class NoteWindowController: NSWindowController {
    /// Only one note editor at a time; without an owner it would deallocate
    /// immediately.
    private static var active: NoteWindowController?

    private let store: ShelfStore
    /// nil when composing something new.
    private let editing: ShelfItem?
    private let textView = NSTextView()
    private var saved = false

    static func presentNew(store: ShelfStore) {
        present(store: store, editing: nil)
    }

    static func presentEditor(for item: ShelfItem, store: ShelfStore) {
        guard item.kind == .text else {
            NSSound.beep()
            return
        }
        present(store: store, editing: item)
    }

    private static func present(store: ShelfStore, editing: ShelfItem?) {
        dispatchPrecondition(condition: .onQueue(.main))
        // A second ⌃⌥⌘N should focus the open note, not throw away what is
        // already typed in it.
        if let active, active.editing?.id == editing?.id {
            NSApp.activate(ignoringOtherApps: true)
            active.window?.makeKeyAndOrderFront(nil)
            active.focusEditor()
            return
        }
        active?.close()
        let controller = NoteWindowController(store: store, editing: editing)
        active = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusEditor()
    }

    private init(store: ShelfStore, editing: ShelfItem?) {
        self.store = store
        self.editing = editing

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = editing == nil ? "New Note" : "Edit Snippet"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ShakeShelfNoteWindow")

        super.init(window: window)
        window.delegate = self
        buildContent()
        if let editing {
            textView.string = editing.text ?? ""
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        let hint = NSTextField(labelWithString: "⌘↩ saves to the shelf · Esc closes")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hint)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        let saveButton = NSButton(
            title: editing == nil ? "Add to Shelf" : "Save",
            target: self,
            action: #selector(save(_:))
        )
        // ⌘↩ rather than ↩: Return has to keep inserting newlines.
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(saveButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -10),

            hint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            hint.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),

            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
    }

    private func focusEditor() {
        window?.makeFirstResponder(textView)
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    @objc private func save(_ sender: Any?) {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            close()
            return
        }
        saved = true

        if let editing {
            store.updateText(editing, to: text) { [weak self] error in
                guard let error else {
                    self?.close()
                    return
                }
                self?.saved = false
                let alert = NSAlert()
                alert.messageText = "Couldn't save the snippet"
                alert.informativeText = error
                alert.runModal()
            }
            return
        }

        store.importText(text) { [weak self] result in
            switch result {
            case .added, .duplicate:
                self?.close()
            case .failed(let reason):
                self?.saved = false
                let alert = NSAlert()
                alert.messageText = "Couldn't add the note"
                alert.informativeText = reason
                alert.runModal()
            }
        }
    }

    override func close() {
        super.close()
        if NoteWindowController.active === self {
            NoteWindowController.active = nil
        }
    }
}

extension NoteWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing with unsaved text would silently throw away typing.
        guard !saved, !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        if let editing, textView.string == editing.text { return true }

        let alert = NSAlert()
        alert.messageText = "Discard this note?"
        alert.informativeText = "The text hasn't been saved to the shelf."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        if NoteWindowController.active === self {
            NoteWindowController.active = nil
        }
    }
}
