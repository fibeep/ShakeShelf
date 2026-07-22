import AppKit

/// Borderless, non-activating floating panel: it never steals focus from the
/// app the user is working in, joins every Space (including full-screen apps),
/// and accepts drops even while our app is inactive.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ShelfWindowController: NSWindowController, ShelfStoreDelegate {
    private let store: ShelfStore
    private let rootView: ShelfRootView

    init(store: ShelfStore) {
        self.store = store
        self.rootView = ShelfRootView(store: store)

        let panel = ShelfPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 178),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = rootView

        super.init(window: panel)

        store.delegate = self
        rootView.onClose = { [weak self] in self?.hide() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isVisible: Bool { window?.isVisible ?? false }

    func presentNearMouse() {
        guard let window else { return }
        store.refresh()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + 24, y: mouse.y - window.frame.height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - window.frame.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - window.frame.height - 8)
        }
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func bringToFront() {
        // Also refresh here: the shelf is a floating panel that often just
        // stays up, so without this an externally edited snippet or a file
        // deleted in Finder would not be noticed until it was hidden.
        store.refresh()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            presentNearMouse()
        }
    }

    /// Adds the clipboard's contents and shows the shelf so the user sees the
    /// result. Returns false if the clipboard held nothing usable.
    @discardableResult
    func addClipboardContents() -> Bool {
        let added = rootView.addClipboardContents()
        if added, !isVisible { presentNearMouse() }
        return added
    }

    /// Opens the system loupe and adds the sampled color to the shelf.
    func pickColor() {
        rootView.pickColor()
    }

    func combineIntoPDF() {
        rootView.combineIntoPDF()
    }

    func newNote() {
        rootView.newNote()
    }

    func stitchImages(axis: ImageStitch.Axis) {
        rootView.stitchImages(axis: axis)
    }

    func diffSelectedSnippets() {
        rootView.diffSelectedSnippets()
    }

    /// Captures a screen region, then shows the shelf so the result is visible.
    func captureRegion() {
        RegionCapture.captureRegion(into: store) { [weak self] in
            guard let self else { return }
            if self.isVisible {
                self.bringToFront()
            } else {
                self.presentNearMouse()
            }
        }
    }

    func shelfStoreDidChange(_ store: ShelfStore) {
        rootView.reload()
    }
}
