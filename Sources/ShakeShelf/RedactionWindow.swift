import AppKit

/// Lets you drag boxes over the parts of a screenshot that shouldn't leave
/// your machine — API keys, customer names, internal URLs — and writes out a
/// flattened copy with those regions destroyed.
final class RedactionWindowController: NSWindowController {
    /// Held for the lifetime of the editor; an NSWindowController with no
    /// other owner would be deallocated immediately.
    private static var active: RedactionWindowController?

    private let item: ShelfItem
    private let store: ShelfStore
    private let canvas: RedactionCanvas
    private let replaceCheckbox = NSButton(checkboxWithTitle: "Replace original", target: nil, action: nil)

    static func present(for item: ShelfItem, store: ShelfStore) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let image = NSImage(contentsOf: item.fileURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            NSSound.beep()
            NSLog("ShakeShelf: could not open \(item.filename) for redaction")
            return
        }
        active?.close()
        let controller = RedactionWindowController(item: item, store: store, cgImage: cgImage)
        active = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(item: ShelfItem, store: ShelfStore, cgImage: CGImage) {
        self.item = item
        self.store = store
        self.canvas = RedactionCanvas(cgImage: cgImage)

        // Fit the image on screen while keeping room for the toolbar.
        let maxSize = NSSize(width: 1000, height: 720)
        let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
        let scale = min(1, min(maxSize.width / imageSize.width, maxSize.height / imageSize.height))
        let contentSize = NSSize(
            width: max(480, imageSize.width * scale),
            height: max(320, imageSize.height * scale) + Self.toolbarHeight
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Redact \(item.filename)"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let toolbarHeight: CGFloat = 52

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        canvas.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(canvas)

        let styleControl = NSSegmentedControl(
            labels: ["Black Bar", "Pixelate"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(styleChanged(_:))
        )
        styleControl.selectedSegment = 0
        styleControl.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(styleControl)

        let hint = NSTextField(labelWithString: "Drag over anything that should be hidden. ⌘Z undoes.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hint)

        replaceCheckbox.toolTip = "Delete the unredacted original from the shelf after applying"
        replaceCheckbox.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(replaceCheckbox)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        let applyButton = NSButton(title: "Apply", target: self, action: #selector(apply(_:)))
        applyButton.keyEquivalent = "\r"
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(applyButton)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: contentView.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.toolbarHeight),

            styleControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            styleControl.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),

            replaceCheckbox.leadingAnchor.constraint(equalTo: styleControl.trailingAnchor, constant: 12),
            replaceCheckbox.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),

            hint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: styleControl.topAnchor, constant: -4),

            applyButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            applyButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: applyButton.centerYAnchor),
        ])
    }

    @objc private func styleChanged(_ sender: NSSegmentedControl) {
        canvas.style = sender.selectedSegment == 0 ? .solid : .pixelate
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    @objc private func apply(_ sender: Any?) {
        guard !canvas.redactions.isEmpty else {
            close()
            return
        }
        guard let data = canvas.renderRedactedPNG() else {
            NSSound.beep()
            NSLog("ShakeShelf: redaction render failed for \(item.filename)")
            return
        }
        let base = (item.filename as NSString).deletingPathExtension
        let shouldReplace = replaceCheckbox.state == .on
        let original = item

        store.importImageData(data, preferredExtension: "png", baseName: "\(base) redacted") { [store] result in
            // Only remove the unredacted original once its replacement is safely
            // written, so a failure can never lose the sole copy.
            if shouldReplace, case .added = result {
                store.remove(original)
            }
        }
        close()
    }

    override func close() {
        super.close()
        if RedactionWindowController.active === self {
            RedactionWindowController.active = nil
        }
    }
}

extension RedactionWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if RedactionWindowController.active === self {
            RedactionWindowController.active = nil
        }
    }
}

/// Draws the image aspect-fit and collects redaction rectangles.
/// Everything is kept in bottom-left-origin coordinates — view space and
/// CGContext space agree, so no flipping is needed anywhere.
final class RedactionCanvas: NSView {
    enum Style {
        case solid
        case pixelate
    }

    private let cgImage: CGImage
    private(set) var redactions: [CGRect] = [] // image pixel coordinates
    var style: Style = .solid

    private var dragOrigin: NSPoint?
    private var dragCurrent: NSPoint?

    init(cgImage: CGImage) {
        self.cgImage = cgImage
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    private var imageSize: NSSize {
        NSSize(width: cgImage.width, height: cgImage.height)
    }

    /// Where the image is drawn inside the view, preserving aspect ratio.
    private var imageFrame: NSRect {
        let available = bounds.insetBy(dx: 12, dy: 12)
        guard imageSize.width > 0, imageSize.height > 0, available.width > 0, available.height > 0 else { return bounds }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func toImageRect(_ viewRect: NSRect) -> CGRect {
        let frame = imageFrame
        guard frame.width > 0 else { return .zero }
        let scale = imageSize.width / frame.width
        return CGRect(
            x: (viewRect.minX - frame.minX) * scale,
            y: (viewRect.minY - frame.minY) * scale,
            width: viewRect.width * scale,
            height: viewRect.height * scale
        ).intersection(CGRect(origin: .zero, size: imageSize))
    }

    private func toViewRect(_ imageRect: CGRect) -> NSRect {
        let frame = imageFrame
        guard imageSize.width > 0 else { return .zero }
        let scale = frame.width / imageSize.width
        return NSRect(
            x: frame.minX + imageRect.minX * scale,
            y: frame.minY + imageRect.minY * scale,
            width: imageRect.width * scale,
            height: imageRect.height * scale
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = imageFrame
        context.draw(cgImage, in: frame)

        NSColor.black.setFill()
        for redaction in redactions {
            let rect = toViewRect(redaction)
            if style == .pixelate {
                NSColor.black.withAlphaComponent(0.55).setFill()
                rect.fill()
                NSColor.white.withAlphaComponent(0.9).setStroke()
                NSBezierPath(rect: rect).stroke()
                NSColor.black.setFill()
            } else {
                rect.fill()
            }
        }

        if let rect = currentDragRect() {
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
            rect.fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: rect).stroke()
        }
    }

    private func currentDragRect() -> NSRect? {
        guard let origin = dragOrigin, let current = dragCurrent else { return nil }
        let rect = NSRect(
            x: min(origin.x, current.x),
            y: min(origin.y, current.y),
            width: abs(current.x - origin.x),
            height: abs(current.y - origin.y)
        )
        return rect.intersection(imageFrame)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragCurrent = dragOrigin
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            dragCurrent = nil
            needsDisplay = true
        }
        guard let rect = currentDragRect(), rect.width > 3, rect.height > 3 else { return }
        let imageRect = toImageRect(rect)
        guard imageRect.width >= 1, imageRect.height >= 1 else { return }
        redactions.append(imageRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if !redactions.isEmpty {
                redactions.removeLast()
                needsDisplay = true
            }
            return
        }
        super.keyDown(with: event)
    }

    /// Flattens the redactions into the image at full resolution. The hidden
    /// pixels are overwritten, not covered by a layer, so nothing recoverable
    /// survives in the output file.
    func renderRedactedPNG() -> Data? {
        let width = cgImage.width
        let height = cgImage.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(cgImage, in: fullRect)

        for redaction in redactions {
            let rect = redaction.integral.intersection(fullRect)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            switch style {
            case .solid:
                context.setFillColor(NSColor.black.cgColor)
                context.fill(rect)
            case .pixelate:
                if let blocks = pixelatedRegion(rect) {
                    context.interpolationQuality = .none
                    context.draw(blocks, in: rect)
                    context.interpolationQuality = .default
                } else {
                    context.setFillColor(NSColor.black.cgColor)
                    context.fill(rect)
                }
            }
        }

        guard let output = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Renders just this region into a tiny bitmap; drawing it back with
    /// interpolation disabled produces genuine blocks rather than a blur.
    private func pixelatedRegion(_ rect: CGRect) -> CGImage? {
        let blockCount: CGFloat = 10
        let smallWidth = max(1, Int((rect.width / max(rect.width / blockCount, 4)).rounded()))
        let smallHeight = max(1, Int((rect.height / max(rect.height / blockCount, 4)).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let small = CGContext(
                data: nil,
                width: smallWidth, height: smallHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // Map the region onto the whole small context, then draw the full
        // image through that transform.
        let scaleX = CGFloat(smallWidth) / rect.width
        let scaleY = CGFloat(smallHeight) / rect.height
        small.scaleBy(x: scaleX, y: scaleY)
        small.translateBy(x: -rect.minX, y: -rect.minY)
        small.interpolationQuality = .medium
        small.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return small.makeImage()
    }
}
