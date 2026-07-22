import AppKit

/// Detects a horizontal "shake" gesture performed while the user is dragging
/// something droppable (e.g. the floating screenshot thumbnail).
///
/// Global NSEvent monitors for mouse events do not require accessibility
/// permissions, and left-mouse-dragged events are delivered during
/// drag-and-drop sessions owned by other apps.
///
/// Two gates prevent false positives:
///  - Strokes must alternate direction (pixel jitter during a straight drag
///    merges into the previous stroke instead of counting again).
///  - The trigger requires a real drag-and-drop session carrying content the
///    shelf accepts — plain button-held movement (selecting text, scrubbing a
///    slider, drawing a stroke) never writes to the drag pasteboard, so it
///    cannot summon the shelf.
///
/// Note that since the shelf gained text snippets, dragging *already
/// selected* text counts as acceptable content. Repositioning a selection
/// with a wiggly path can therefore summon the shelf; that is the cost of
/// supporting "drag text here" at all.
final class ShakeDetector {
    var onShake: (() -> Void)?

    private var globalDragMonitor: Any?
    private var globalClickMonitor: Any?
    private var localMonitor: Any?

    private var lastX: CGFloat?
    private var runDirection = 0 // -1 left, +1 right, 0 unknown
    private var runDistance: CGFloat = 0
    private var runCounted = false
    private var strokes: [(time: TimeInterval, direction: Int)] = []
    private var lastTriggerTime: TimeInterval = 0
    private var dragBaselineChangeCount = NSPasteboard(name: .drag).changeCount

    /// Minimum horizontal travel (in points) for a run to count as a stroke.
    private let strokeDistance: CGFloat = 25
    /// R-L-R-L = two quick shakes. Strokes are counted as soon as they cross
    /// strokeDistance, so the gesture triggers mid-stroke, not one stroke late.
    private let requiredStrokes = 4
    private let windowSeconds: TimeInterval = 1.2
    private let cooldownSeconds: TimeInterval = 1.5

    /// Types the shelf can accept; shaking during e.g. a text-selection drag
    /// should not summon it.
    private static let relevantDragTypes: Set<String> = {
        var types: Set<String> = [
            NSPasteboard.PasteboardType.fileURL.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.string.rawValue,
        ]
        for type in NSFilePromiseReceiver.readableDraggedTypes {
            types.insert(type)
        }
        return types
    }()

    func start() {
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            self?.handleDragMovement(event)
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] _ in
            self?.reset()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            if event.type == .leftMouseDragged {
                self?.handleDragMovement(event)
            } else {
                self?.reset()
            }
            return event
        }
        reset()
    }

    func stop() {
        for monitor in [globalDragMonitor, globalClickMonitor, localMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalDragMonitor = nil
        globalClickMonitor = nil
        localMonitor = nil
    }

    deinit { stop() }

    private func handleDragMovement(_ event: NSEvent) {
        // Use the event's own position, not the live cursor: if the main
        // thread stalls, backlogged events would all read the same current
        // location and every reversal during the stall would be lost.
        let x = screenX(of: event)
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastX = x }
        guard let last = lastX else { return }
        let dx = x - last
        guard dx != 0 else { return }
        let direction = dx > 0 ? 1 : -1

        if direction != runDirection {
            runDirection = direction
            runDistance = 0
            runCounted = false
        }
        runDistance += abs(dx)
        guard !runCounted, runDistance >= strokeDistance else { return }
        runCounted = true

        // A continuation of the previous direction after pixel-level jitter
        // merges into the previous stroke instead of counting again, so
        // counted strokes always alternate direction.
        if let lastStroke = strokes.last, lastStroke.direction == direction {
            strokes[strokes.count - 1].time = now
        } else {
            strokes.append((time: now, direction: direction))
        }
        strokes.removeAll { now - $0.time > windowSeconds }

        guard strokes.count >= requiredStrokes,
              now - lastTriggerTime > cooldownSeconds,
              dragSessionHasRelevantContent() else { return }
        lastTriggerTime = now
        strokes.removeAll()
        DispatchQueue.main.async { [weak self] in
            self?.onShake?()
        }
    }

    /// A real drag-and-drop session writes to the drag pasteboard, bumping its
    /// changeCount past the baseline recorded at mouse-down. Require that,
    /// plus content of a type the shelf accepts.
    private func dragSessionHasRelevantContent() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragBaselineChangeCount else { return false }
        guard let types = pasteboard.types else { return false }
        return types.contains { Self.relevantDragTypes.contains($0.rawValue) }
    }

    private func screenX(of event: NSEvent) -> CGFloat {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow).x
        }
        return event.locationInWindow.x
    }

    private func reset() {
        lastX = nil
        runDirection = 0
        runDistance = 0
        runCounted = false
        strokes.removeAll()
        dragBaselineChangeCount = NSPasteboard(name: .drag).changeCount
    }
}
