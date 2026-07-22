import AppKit

enum ShelfItemRemovalKind {
    case discard // ✕ button / context menu — delete the file now
    case trash   // dragged onto the Dock's Trash — file goes to the Trash
    case dragOut // remove-after-drag preference — defer the file deletion
}

/// The shelf owns selection and drag composition; a tile only reports what
/// the user did to it.
protocol ShelfTileDelegate: AnyObject {
    func tile(_ tile: ShelfItemView, wasClickedWith event: NSEvent)
    /// The items a drag starting from this tile should carry — the whole
    /// selection when the tile is part of one, otherwise just itself.
    func itemsForDrag(startingFrom item: ShelfItem) -> [ShelfItem]
    func selectedItems() -> [ShelfItem]
    func remove(_ item: ShelfItem, kind: ShelfItemRemovalKind)
}

/// One tile on the shelf. Acts as a drag source so the item can be dragged
/// into any other app: images and files travel as file URLs, text snippets
/// travel as plain text so they paste straight into a message.
final class ShelfItemView: NSView, NSDraggingSource {
    let item: ShelfItem
    var onRemove: ((ShelfItem, ShelfItemRemovalKind) -> Void)?
    /// Set by the shelf so tile actions can add their results back.
    weak var store: ShelfStore?
    weak var delegate: ShelfTileDelegate?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Captured when a drag begins so the remove-after-drag preference can
    /// apply to every item that travelled, not just the tile that started it.
    private var draggedItems: [ShelfItem] = []

    private let bodyView: NSView
    private let nameLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var mouseDownEvent: NSEvent?
    private var trackingArea: NSTrackingArea?
    private var hovered = false {
        didSet {
            closeButton.isHidden = !hovered
            needsDisplay = true
        }
    }

    init(item: ShelfItem) {
        self.item = item
        switch item.kind {
        case .text:
            self.bodyView = ShelfItemView.makeTextBody(item.text ?? "")
        case .color:
            self.bodyView = ShelfItemView.makeColorBody(item.color ?? .clear)
        case .image, .file:
            self.bodyView = ShelfItemView.makeImageBody(item.thumbnail)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        switch item.kind {
        case .text: toolTip = String((item.text ?? "").prefix(500))
        case .color: toolTip = item.color?.hexString
        case .image, .file: toolTip = item.filename
        }

        bodyView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyView)

        switch item.kind {
        case .text: nameLabel.stringValue = "Text"
        case .color: nameLabel.stringValue = "Color"
        case .image, .file: nameLabel.stringValue = item.filename
        }
        nameLabel.font = .systemFont(ofSize: 10)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove item")
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(removeTapped)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            bodyView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            bodyView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            bodyView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bodyView.bottomAnchor.constraint(equalTo: nameLabel.topAnchor, constant: -3),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            nameLabel.heightAnchor.constraint(equalToConstant: 14),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func makeImageBody(_ thumbnail: NSImage?) -> NSView {
        let imageView = NSImageView()
        imageView.image = thumbnail
        imageView.imageScaling = .scaleProportionallyDown
        imageView.isEditable = false
        imageView.unregisterDraggedTypes()
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return imageView
    }

    /// Redraws its background when the system switches light/dark.
    private final class TextBodyView: NSView {
        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.cornerRadius = 6
            layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    /// A solid swatch with its hex overlaid — the hex travels with the drag
    /// image, so you can read it while dragging into a color well.
    private final class ColorBodyView: NSView {
        let color: NSColor

        init(color: NSColor) {
            self.color = color
            super.init(frame: .zero)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.cornerRadius = 6
            layer?.backgroundColor = color.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    private static func makeColorBody(_ color: NSColor) -> NSView {
        let container = ColorBodyView(color: color)

        let label = NSTextField(labelWithString: color.hexString)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = color.prefersLightForeground ? .white : .black
        label.alignment = .center
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -2),
        ])
        return container
    }

    private static func makeTextBody(_ text: String) -> NSView {
        let container = TextBodyView()
        container.wantsLayer = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .labelColor
        label.isSelectable = false
        label.isEditable = false
        label.drawsBackground = false
        label.maximumNumberOfLines = 6
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            label.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -5),
        ])
        return container
    }

    // The panel is movable-by-background; without this, pressing a tile would
    // move the whole shelf instead of starting the item drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovered ? 0.12 : 0.06).cgColor
        layer?.borderWidth = isSelected ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    // Route all clicks (except the close button) to this view so drags start here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === closeButton || hit.isDescendant(of: closeButton) { return hit }
        return self
    }

    // MARK: - Drag out

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        delegate?.tile(self, wasClickedWith: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let start = convert(down.locationInWindow, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) > 5 else { return }
        mouseDownEvent = nil

        let items = delegate?.itemsForDrag(startingFrom: item) ?? [item]
        draggedItems = items

        // Fan the drag images out slightly so a multi-item drag reads as a
        // stack rather than a single tile.
        let draggingItems = items.enumerated().map { index, item -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: ShelfPasteboard.writer(for: item))
            let offset = CGFloat(index) * 6
            let frame = bodyView.frame.offsetBy(dx: offset, dy: -offset)
            draggingItem.setDraggingFrame(frame, contents: ShelfPasteboard.dragImage(for: item, snapshotting: item.id == self.item.id ? bodyView : nil))
            return draggingItem
        }
        beginDraggingSession(with: draggingItems, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            NSWorkspace.shared.open(item.fileURL)
        }
        mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return [.copy, .delete] // .delete lets the Dock's Trash accept the drag
        default:
            return [] // no drops back onto our own shelf
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let items = draggedItems.isEmpty ? [item] : draggedItems
        draggedItems = []
        if operation.contains(.delete) {
            items.forEach { onRemove?($0, .trash) }
            return
        }
        if Prefs.removeAfterDragOut, operation != [] {
            items.forEach { onRemove?($0, .dragOut) }
        }
    }

    // MARK: - Context menu

    private final class ActionMenuItem: NSMenuItem {
        var handler: (() -> Void)?
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        guard let store else {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        let context = ShelfActionContext(store: store, sourceView: self)
        let actions = ShelfActions.actions(for: item)

        for group in ShelfAction.Group.allCases {
            let inGroup = actions.filter { $0.group == group }
            guard !inGroup.isEmpty else { continue }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            var submenus: [String: NSMenu] = [:]
            for action in inGroup {
                let menuItem = ActionMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.handler = { action.run(self.item, context) }
                guard let submenuTitle = action.submenu else {
                    menu.addItem(menuItem)
                    continue
                }
                if let existing = submenus[submenuTitle] {
                    existing.addItem(menuItem)
                } else {
                    let submenu = NSMenu()
                    submenu.addItem(menuItem)
                    submenus[submenuTitle] = submenu
                    let parent = NSMenuItem(title: submenuTitle, action: nil, keyEquivalent: "")
                    parent.submenu = submenu
                    menu.addItem(parent)
                }
            }
        }

        menu.addItem(.separator())
        let selected = delegate?.selectedItems() ?? []
        if selected.count > 1, selected.contains(where: { $0.id == item.id }) {
            let removeSelected = ActionMenuItem(title: "Remove \(selected.count) Selected Items", action: #selector(runAction(_:)), keyEquivalent: "")
            removeSelected.target = self
            removeSelected.handler = { [weak self] in
                guard let self else { return }
                selected.forEach { self.delegate?.remove($0, kind: .discard) }
            }
            menu.addItem(removeSelected)
        } else {
            menu.addItem(withTitle: "Remove from Shelf", action: #selector(removeTapped), keyEquivalent: "").target = self
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        (sender as? ActionMenuItem)?.handler?()
    }

    @objc private func removeTapped() {
        onRemove?(item, .discard)
    }
}
