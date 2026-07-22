import AppKit

/// Screenshots and recordings straight onto the shelf, skipping the
/// screenshot-then-drag-then-shake dance.
///
/// Shells out to the system's own `screencapture` rather than using
/// ScreenCaptureKit: it reuses the familiar crosshair/stop UI, needs no extra
/// framework, and behaves exactly like ⇧⌘3 / ⇧⌘4 / ⇧⌘5.
enum ScreenCapture {
    enum Mode {
        case fullScreen // whole screen, immediately
        case region     // interactive selection or window
        case video      // record until the user clicks stop in the menu bar

        var fileExtension: String { self == .video ? "mov" : "png" }

        /// Non-interactive captures fire the moment they launch, so the shelf
        /// must already be gone from the composited screen. Interactive
        /// selection gives the user time to aim, so no wait is needed.
        var needsSettleDelay: Bool { self == .fullScreen || self == .video }

        var arguments: [String] {
            switch self {
            case .fullScreen: return []
            case .region: return ["-i"]
            case .video: return ["-v"]
            }
        }

        var permissionVerb: String {
            self == .video ? "record the screen" : "capture the screen"
        }
    }

    private static var inProgress = false

    /// - Parameters:
    ///   - willStart: hide the shelf (runs before the capture launches).
    ///   - didFinish: `captured` is true only when a file was produced and
    ///     imported; false on cancel or failure. Used to restore the shelf.
    static func capture(
        _ mode: Mode,
        into store: ShelfStore,
        willStart: @escaping () -> Void,
        didFinish: @escaping (_ captured: Bool) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        // A second trigger while a capture (or a long recording) is running
        // would stack two sessions.
        guard !inProgress else { return }
        inProgress = true

        willStart()

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ShakeShelf-capture-\(UUID().uuidString).\(mode.fileExtension)")

        func launch() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = mode.arguments + [destination.path]
            process.terminationHandler = { proc in
                let status = proc.terminationStatus
                DispatchQueue.main.async {
                    inProgress = false
                    let fm = FileManager.default
                    guard fm.fileExists(atPath: destination.path) else {
                        // No file means either a clean cancel (Esc → exit 0)
                        // or a failure. The most common failure is a missing
                        // Screen Recording permission, which exits non-zero.
                        if status != 0 { showPermissionHint(for: mode) }
                        didFinish(false)
                        return
                    }
                    store.importFile(at: destination) { result in
                        try? fm.removeItem(at: destination)
                        switch result {
                        case .added, .duplicate:
                            didFinish(true)
                        case .failed(let reason):
                            let alert = NSAlert()
                            alert.messageText = "Couldn't add the capture"
                            alert.informativeText = reason
                            NSApp.activate(ignoringOtherApps: true)
                            alert.runModal()
                            didFinish(false)
                        }
                    }
                }
            }
            do {
                try process.run()
            } catch {
                inProgress = false
                NSSound.beep()
                NSLog("ShakeShelf: could not start screencapture: \(error)")
                didFinish(false)
            }
        }

        if mode.needsSettleDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: launch)
        } else {
            launch()
        }
    }

    private static func showPermissionHint(for mode: Mode) {
        let alert = NSAlert()
        alert.messageText = "ShakeShelf needs permission to \(mode.permissionVerb)"
        alert.informativeText = "macOS blocks screen capture until you allow it under "
            + "System Settings → Privacy & Security → Screen Recording. Turn on ShakeShelf there, then try again."
        alert.addButton(withTitle: "Open Screen Recording Settings")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
