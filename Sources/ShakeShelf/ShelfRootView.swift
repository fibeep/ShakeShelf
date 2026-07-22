import AppKit

/// The shelf panel's content: a blurred rounded card with a header row and a
/// horizontally scrolling strip of items. The whole card is a drop target.
///
/// Accepted drops, in priority order:
///  1. File promises (the macOS screenshot floating thumbnail, browser images,
///     Photos, Mail attachments) — received to a temp folder, then imported.
///  2. Concrete file URLs (Finder).
///  3. Raw image data on the pasteboard — saved as a PNG.
///  4. Plain text — saved as a .txt snippet.
final class ShelfRootView: NSView {
    private let store: ShelfStore
    var onClose: (() -> Void)?
    var onCapture: ((ScreenCapture.Mode) -> Void)?

    private let effectView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "ShakeShelf")
    private let countLabel = NSTextField(labelWithString: "")
    private let captureButton = NSButton()
    private let noteButton = NSButton()
    private let eyedropperButton = NSButton()
    private let pasteButton = NSButton()
    private let clearButton = NSButton()
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let emptyLabel: NSTextField
    private var previousCount = 0

    private var isDropTarget = false {
        didSet { needsDisplay = true }
    }

    private var selectedIDs: Set<UUID> = []
    private var itemViews: [ShelfItemView] = []
    /// Anchor for ⇧-click range selection.
    private var selectionAnchor: UUID?

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(store: ShelfStore) {
        self.store = store
        emptyLabel = NSTextField(wrappingLabelWithString: "Drop images, files, or selected text here.\nTake a screenshot, drag its thumbnail, and shake the mouse to summon this shelf.")
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 178))
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true

        var types: [NSPasteboard.PasteboardType] = [.fileURL, .tiff, .png, .string]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)

        buildUI()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderWidth = isDropTarget ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    // MARK: - UI

    private func buildUI() {
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        captureButton.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Capture screen")
        captureButton.isBordered = false
        captureButton.contentTintColor = .secondaryLabelColor
        captureButton.target = self
        captureButton.action = #selector(captureTapped)
        captureButton.toolTip = "Take a screenshot or record the screen (the shelf hides itself first)"
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captureButton)

        noteButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New note")
        noteButton.isBordered = false
        noteButton.contentTintColor = .secondaryLabelColor
        noteButton.target = self
        noteButton.action = #selector(newNoteTapped)
        noteButton.toolTip = "Write a note and save it to the shelf"
        noteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noteButton)

        eyedropperButton.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "Pick a color")
        eyedropperButton.isBordered = false
        eyedropperButton.contentTintColor = .secondaryLabelColor
        eyedropperButton.target = self
        eyedropperButton.action = #selector(pickColorTapped)
        eyedropperButton.toolTip = "Pick a color from anywhere on screen"
        eyedropperButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(eyedropperButton)

        pasteButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add clipboard contents")
        pasteButton.isBordered = false
        pasteButton.contentTintColor = .secondaryLabelColor
        pasteButton.target = self
        pasteButton.action = #selector(pasteTapped)
        pasteButton.toolTip = "Add whatever is on the clipboard (text or image)"
        pasteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pasteButton)

        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear shelf")
        clearButton.isBordered = false
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.toolTip = "Remove all items"
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Hide shelf")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Hide the shelf (items are kept)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.alignment = .height
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.isSelectable = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        let clipView = scrollView.contentView
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            clearButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),

            pasteButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pasteButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),

            eyedropperButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            eyedropperButton.trailingAnchor.constraint(equalTo: pasteButton.leadingAnchor, constant: -8),

            noteButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            noteButton.trailingAnchor.constraint(equalTo: eyedropperButton.leadingAnchor, constant: -8),

            captureButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            captureButton.trailingAnchor.constraint(equalTo: noteButton.leadingAnchor, constant: -8),
            captureButton.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 8),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stackView.topAnchor.constraint(equalTo: clipView.topAnchor),
            stackView.heightAnchor.constraint(equalTo: clipView.heightAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
        ])
    }

    func reload() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        itemViews.removeAll()
        // Drop selections for items that are no longer on the shelf.
        let liveIDs = Set(store.items.map(\.id))
        selectedIDs.formIntersection(liveIDs)
        if let anchor = selectionAnchor, !liveIDs.contains(anchor) { selectionAnchor = nil }

        for item in store.items {
            let itemView = ShelfItemView(item: item)
            itemView.store = store
            itemView.delegate = self
            itemView.isSelected = selectedIDs.contains(item.id)
            itemView.onRemove = { [weak self] item, kind in
                self?.remove(item, kind: kind)
            }
            stackView.addArrangedSubview(itemView)
            itemView.widthAnchor.constraint(equalToConstant: 116).isActive = true
            itemViews.append(itemView)
        }
        emptyLabel.isHidden = !store.items.isEmpty
        updateCountLabel()
        let count = store.items.count

        let grew = count > previousCount
        previousCount = count
        if grew {
            DispatchQueue.main.async { [weak self] in
                self?.scrollToEnd()
            }
        }
    }

    private func scrollToEnd() {
        layoutSubtreeIfNeeded()
        guard let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let x = max(0, documentView.frame.maxX - clipView.bounds.width)
        clipView.scroll(to: NSPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func updateCountLabel() {
        let count = store.items.count
        guard count > 0 else {
            countLabel.stringValue = ""
            return
        }
        let base = "\(count) item\(count == 1 ? "" : "s")"
        countLabel.stringValue = selectedIDs.isEmpty ? base : "\(base) · \(selectedIDs.count) selected"
    }

    // MARK: - Selection

    private func applySelectionToTiles() {
        for view in itemViews {
            view.isSelected = selectedIDs.contains(view.item.id)
        }
        updateCountLabel()
    }

    private func clearSelection() {
        guard !selectedIDs.isEmpty else { return }
        selectedIDs.removeAll()
        selectionAnchor = nil
        applySelectionToTiles()
    }

    /// Clicking the shelf background drops the selection, matching Finder.
    override func mouseDown(with event: NSEvent) {
        clearSelection()
        super.mouseDown(with: event)
    }

    @objc private func clearTapped() {
        store.clear()
    }

    @objc private func pasteTapped() {
        addClipboardContents()
    }

    @objc private func pickColorTapped() {
        pickColor()
    }

    @objc private func newNoteTapped() {
        newNote()
    }

    @objc private func captureTapped() {
        let menu = NSMenu()
        let full = menu.addItem(withTitle: "Capture Full Screen", action: #selector(captureFullScreen), keyEquivalent: "")
        full.target = self
        let region = menu.addItem(withTitle: "Capture Selection…", action: #selector(captureSelection), keyEquivalent: "")
        region.target = self
        menu.addItem(.separator())
        let video = menu.addItem(withTitle: "Record Screen…", action: #selector(captureVideo), keyEquivalent: "")
        video.target = self
        // Drop the menu just below the button.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: captureButton.bounds.height + 4), in: captureButton)
    }

    @objc private func captureFullScreen() { onCapture?(.fullScreen) }
    @objc private func captureSelection() { onCapture?(.region) }
    @objc private func captureVideo() { onCapture?(.video) }

    /// Diffs exactly two selected text snippets, oldest first so the result
    /// reads as "what changed since".
    func diffSelectedSnippets() {
        let snippets = store.items.filter { selectedIDs.contains($0.id) && $0.kind == .text }
        guard snippets.count == 2 else {
            let alert = NSAlert()
            alert.messageText = "Select two text snippets"
            alert.informativeText = snippets.count < 2
                ? "⌘-click to select exactly two text tiles, then run this again."
                : "\(snippets.count) text tiles are selected. Diffing compares exactly two."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let old = snippets[0]
        let new = snippets[1]
        let result = TextDiff.diff(
            old: old.text ?? "",
            new: new.text ?? "",
            oldLabel: old.filename,
            newLabel: new.filename
        )
        guard !result.isIdentical else {
            let alert = NSAlert()
            alert.messageText = "The snippets are identical"
            alert.informativeText = "There is nothing to show — every line matches."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        store.importText(result.text) { outcome in
            if case .failed(let reason) = outcome {
                let alert = NSAlert()
                alert.messageText = "Couldn't save the diff"
                alert.informativeText = reason
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    func newNote() {
        NoteWindowController.presentNew(store: store)
    }

    /// The files an "operate on many" command should use: the selected ones
    /// if there is a selection, otherwise everything on the shelf.
    private func filesForBatchOperation(
        commandDescription: String,
        noun: String,
        matching isEligible: (ShelfItem) -> Bool
    ) -> [URL]? {
        let candidates = selectedIDs.isEmpty
            ? store.items
            : store.items.filter { selectedIDs.contains($0.id) }
        let urls = candidates.filter(isEligible).map(\.fileURL)
        guard !urls.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to \(commandDescription)"
            alert.informativeText = selectedIDs.isEmpty
                ? "Add some \(noun) to the shelf first — they are used in the order shown."
                : "None of the selected tiles are \(noun). Select the ones you want, or deselect everything to use them all."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return nil
        }
        return urls
    }

    private func addGeneratedFile(
        _ make: @escaping () -> Data?,
        extension fileExtension: String,
        baseName: String,
        failureDescription: String
    ) {
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let data = make()
            DispatchQueue.main.async {
                guard let data else {
                    NSSound.beep()
                    NSLog("ShakeShelf: \(failureDescription)")
                    return
                }
                store.importImageData(data, preferredExtension: fileExtension, baseName: baseName) { result in
                    if case .failed(let reason) = result {
                        let alert = NSAlert()
                        alert.messageText = "Couldn't save the result"
                        alert.informativeText = reason
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                }
            }
        }
    }

    /// Combines images and PDFs, in shelf order, into one document. PDFs
    /// contribute all of their pages, so this merges PDFs as well as building
    /// one from screenshots — or any mix of the two.
    func combineIntoPDF() {
        guard let urls = filesForBatchOperation(
            commandDescription: "combine",
            noun: "images or PDFs",
            matching: { $0.kind == .image || PDFExport.isPDF($0.fileURL) }
        ) else { return }
        guard urls.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Select at least two files"
            alert.informativeText = "Combining joins several images and PDFs into one document. "
                + "To turn a single image into a PDF, right-click it and choose Convert to → PDF."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let pdfCount = urls.filter(PDFExport.isPDF).count
        let baseName = pdfCount == urls.count
            ? "Merged \(urls.count) PDFs"
            : "Combined \(urls.count) files"
        addGeneratedFile(
            { PDFExport.merge(urls) },
            extension: "pdf",
            baseName: baseName,
            failureDescription: "combining \(urls.count) files into a PDF failed"
        )
    }

    /// Joins image tiles into a single tall (or wide) image.
    func stitchImages(axis: ImageStitch.Axis) {
        guard let imageURLs = filesForBatchOperation(
            commandDescription: "stitch",
            noun: "images",
            matching: { $0.kind == .image }
        ) else { return }
        guard imageURLs.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Select at least two images"
            alert.informativeText = "Stitching joins several screenshots into one. ⌘-click to select more than one tile."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        addGeneratedFile(
            { ImageStitch.stitch(imageURLs, axis: axis) },
            extension: "png",
            baseName: "Stitched \(imageURLs.count) images",
            failureDescription: "stitching \(imageURLs.count) images failed"
        )
    }

    func pickColor() {
        ColorSampling.pickFromScreen(into: store)
    }

    /// Adds whatever is on the general clipboard. This is also how
    /// clipboard-only screenshots (⌃⇧⌘4) reach the shelf, since those never
    /// produce a file for the watcher to see.
    @discardableResult
    func addClipboardContents() -> Bool {
        // importContents returns as soon as it recognizes the content; the
        // write happens later, so failures have to surface from the callback
        // or they are invisible.
        let imported = store.importContents(of: .general) { result in
            if case .failed(let reason) = result {
                let alert = NSAlert()
                alert.messageText = "Couldn't add that to the shelf"
                alert.informativeText = reason
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        if !imported { NSSound.beep() }
        return imported
    }

    override func keyDown(with event: NSEvent) {
        // ⌘V, for the times the panel happens to be key.
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
            addClipboardContents()
            return
        }
        super.keyDown(with: event)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    // MARK: - Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource is ShelfItemView { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let pasteboard = sender.draggingPasteboard

        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            receivePromises(receivers)
            return true
        }

        return store.importContents(of: pasteboard)
    }

    private func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        let fm = FileManager.default
        // One temp directory per receiver so identically named promised files
        // from different drag items cannot collide.
        for receiver in receivers {
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ShakeShelf-incoming-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                NSLog("ShakeShelf: could not create temp dir: \(error)")
                continue
            }
            receiver.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: Self.promiseQueue) { [weak self] url, error in
                DispatchQueue.main.async {
                    func cleanUp() {
                        try? fm.removeItem(at: url)
                        if let remaining = try? fm.contentsOfDirectory(atPath: tempDir.path), remaining.isEmpty {
                            try? fm.removeItem(at: tempDir)
                        }
                    }
                    guard let self else {
                        cleanUp()
                        return
                    }
                    if let error {
                        NSLog("ShakeShelf: file promise failed: \(error)")
                        cleanUp()
                        return
                    }
                    self.store.importFile(at: url) { _ in cleanUp() }
                }
            }
        }
    }

    /// Removes leftover promise temp directories from previous runs. Only
    /// called at launch, when no drop can be in flight.
    ///
    /// (Static so the app delegate can call it before any shelf exists.)
    static func cleanupStaleIncomingDirs() {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("ShakeShelf-incoming-") {
            try? fm.removeItem(at: entry)
        }
    }
}

extension ShelfRootView: ShelfTileDelegate {
    func tile(_ tile: ShelfItemView, wasClickedWith event: NSEvent) {
        let id = tile.item.id
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
                selectionAnchor = id
            }
        } else if modifiers.contains(.shift), let anchor = selectionAnchor,
                  let from = store.items.firstIndex(where: { $0.id == anchor }),
                  let to = store.items.firstIndex(where: { $0.id == id }) {
            let range = from <= to ? from...to : to...from
            selectedIDs.formUnion(store.items[range].map(\.id))
        } else {
            // A plain click on an already-selected tile keeps the selection so
            // it can be dragged out as a group.
            if !selectedIDs.contains(id) {
                selectedIDs = [id]
            }
            selectionAnchor = id
        }
        applySelectionToTiles()
    }

    func itemsForDrag(startingFrom item: ShelfItem) -> [ShelfItem] {
        guard selectedIDs.contains(item.id), selectedIDs.count > 1 else { return [item] }
        return store.items.filter { selectedIDs.contains($0.id) }
    }

    func selectedItems() -> [ShelfItem] {
        store.items.filter { selectedIDs.contains($0.id) }
    }

    func remove(_ item: ShelfItem, kind: ShelfItemRemovalKind) {
        selectedIDs.remove(item.id)
        switch kind {
        case .discard: store.remove(item)
        case .trash: store.removeToTrash(item)
        case .dragOut: store.removeAfterDragOut(item)
        }
    }
}
