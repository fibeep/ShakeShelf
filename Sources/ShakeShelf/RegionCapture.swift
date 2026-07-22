import AppKit

/// Grabs a screen region straight onto the shelf, skipping the
/// screenshot-then-drag-then-shake dance for the most common case.
///
/// Shells out to the system's own `screencapture` rather than using
/// ScreenCaptureKit: it reuses the familiar crosshair UI, needs no extra
/// framework, and behaves exactly like ⇧⌘4 because it *is* ⇧⌘4.
enum RegionCapture {
    private static var inProgress = false

    static func captureRegion(into store: ShelfStore, onCaptured: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        // A second trigger while the crosshair is already up would stack two
        // capture sessions on top of each other.
        guard !inProgress else { return }
        inProgress = true

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ShakeShelf-capture-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive selection, -o omits the window shadow when the user
        // switches to window mode with Space.
        process.arguments = ["-i", "-o", destination.path]

        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                inProgress = false
                let fm = FileManager.default
                // Cancelling with Esc exits cleanly but writes no file.
                guard fm.fileExists(atPath: destination.path) else { return }
                store.importFile(at: destination) { result in
                    try? fm.removeItem(at: destination)
                    if case .failed(let reason) = result {
                        let alert = NSAlert()
                        alert.messageText = "Couldn't add the capture"
                        alert.informativeText = reason
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                        return
                    }
                    onCaptured?()
                }
            }
        }

        do {
            try process.run()
        } catch {
            inProgress = false
            NSSound.beep()
            NSLog("ShakeShelf: could not start screencapture: \(error)")
        }
    }
}
