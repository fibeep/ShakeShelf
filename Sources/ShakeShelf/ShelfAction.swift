import AppKit

/// What an action needs to do its work: the store to add results to, and a
/// view to hang sheets and pickers off.
struct ShelfActionContext {
    let store: ShelfStore
    weak var sourceView: NSView?

    /// Runs slow work (image encoding, OCR, hashing) off the main thread and
    /// delivers the result back on it.
    func inBackground<T>(_ work: @escaping () -> T, then finish: @escaping (T) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work()
            DispatchQueue.main.async { finish(value) }
        }
    }

    func reportFailure(_ message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        NSSound.beep()
        NSLog("ShakeShelf: \(message)")
    }

    /// Adds a transform's output as a new snippet, keeping the original.
    /// Explains itself when the result is identical to something already on
    /// the shelf, which otherwise looks like the action silently failed.
    func addResultText(_ text: String) {
        store.importText(text) { result in
            switch result {
            case .added:
                break
            case .duplicate:
                self.showMessage(
                    "Already on the shelf",
                    "The result is identical to a snippet you already have, so nothing was added."
                )
            case .failed(let reason):
                self.showMessage("Couldn't add the result", reason)
            }
        }
    }

    /// For outcomes the user explicitly asked for and deserves an answer to
    /// ("no text found"), where a beep alone would look like a bug.
    func showMessage(_ title: String, _ body: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// One entry in a tile's context menu. Features contribute actions rather
/// than editing the menu directly, so adding a tool means adding a value here.
struct ShelfAction {
    /// Menu sections, rendered in this order and separated by dividers.
    enum Group: Int, CaseIterable {
        case open
        case transform
        case convert
        case copy
    }

    let title: String
    let group: Group
    /// Actions sharing a submenu title are nested under it, keeping long
    /// format lists out of the top-level menu.
    let submenu: String?
    /// Which items this action makes sense for.
    let isEnabled: (ShelfItem) -> Bool
    let run: (ShelfItem, ShelfActionContext) -> Void

    init(
        title: String,
        group: Group,
        submenu: String? = nil,
        kinds: Set<ShelfItem.Kind>,
        run: @escaping (ShelfItem, ShelfActionContext) -> Void
    ) {
        self.title = title
        self.group = group
        self.submenu = submenu
        self.isEnabled = { kinds.contains($0.kind) }
        self.run = run
    }

    init(
        title: String,
        group: Group,
        submenu: String? = nil,
        isEnabled: @escaping (ShelfItem) -> Bool,
        run: @escaping (ShelfItem, ShelfActionContext) -> Void
    ) {
        self.title = title
        self.group = group
        self.submenu = submenu
        self.isEnabled = isEnabled
        self.run = run
    }
}

enum ShelfActions {
    /// Every action the app offers. Each feature owns its own list.
    static var all: [ShelfAction] {
        builtin + ColorActions.all + TextActions.all + ImageActions.all + PDFActions.all
    }

    static func actions(for item: ShelfItem) -> [ShelfAction] {
        all.filter { $0.isEnabled(item) }
    }

    // MARK: - Built-ins

    private static var builtin: [ShelfAction] {
        [
            ShelfAction(
                title: "Open",
                group: .open,
                isEnabled: { $0.kind != .text && $0.kind != .color },
                run: { item, _ in NSWorkspace.shared.open(item.fileURL) }
            ),
            ShelfAction(
                title: "Open in TextEdit",
                group: .open,
                kinds: [.text],
                run: { item, _ in NSWorkspace.shared.open(item.fileURL) }
            ),
            ShelfAction(
                title: "Reveal in Finder",
                group: .open,
                isEnabled: { _ in true },
                run: { item, _ in NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
            ),
            ShelfAction(
                title: "Copy",
                group: .copy,
                isEnabled: { $0.kind != .color },
                run: { item, _ in
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if item.kind == .text, let text = item.text {
                        pasteboard.setString(text, forType: .string)
                        return
                    }
                    var objects: [NSPasteboardWriting] = [item.fileURL as NSURL]
                    if let image = NSImage(contentsOf: item.fileURL) {
                        objects.append(image)
                    }
                    pasteboard.writeObjects(objects)
                }
            ),
            ShelfAction(
                title: "Save As…",
                group: .copy,
                isEnabled: { _ in true },
                run: { item, context in
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = item.filename
                    panel.canCreateDirectories = true
                    NSApp.activate(ignoringOtherApps: true)
                    guard panel.runModal() == .OK, let destination = panel.url else { return }
                    let fm = FileManager.default
                    do {
                        // The panel already got the user's confirmation to
                        // replace, but copyItem refuses to overwrite.
                        if fm.fileExists(atPath: destination.path) {
                            try fm.removeItem(at: destination)
                        }
                        try fm.copyItem(at: item.fileURL, to: destination)
                    } catch {
                        context.showMessage(
                            "Couldn't save the file",
                            "\(destination.lastPathComponent) couldn't be written: \(error.localizedDescription)"
                        )
                    }
                }
            ),
            ShelfAction(
                title: "Share…",
                group: .copy,
                isEnabled: { _ in true },
                run: { item, context in
                    guard let view = context.sourceView else { return }
                    let items: [Any] = item.kind == .text && item.text != nil
                        ? [item.text!]
                        : [item.fileURL]
                    let picker = NSSharingServicePicker(items: items)
                    picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
                }
            ),
        ]
    }
}

/// Helpers shared by the action implementations.
enum ShelfActionSupport {
    /// Asks for a single line of input (a width, a divider, ...) without
    /// requiring the non-activating shelf panel to become key.
    static func prompt(title: String, message: String, defaultValue: String) -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
