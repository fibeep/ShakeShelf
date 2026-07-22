import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ShelfStore()
    private var shelf: ShelfWindowController!
    private let shakeDetector = ShakeDetector()
    private let screenshotWatcher = ScreenshotWatcher()
    private var statusItem: NSStatusItem!

    private var showShelfItem: NSMenuItem!
    private var autoAddItem: NSMenuItem!
    private var removeAfterDragItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    private var didShowAutoAddFailureHint = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShelfRootView.cleanupStaleIncomingDirs()
        shelf = ShelfWindowController(store: store)
        setupStatusItem()

        shakeDetector.onShake = { [weak self] in
            guard let self else { return }
            if self.shelf.isVisible {
                self.shelf.bringToFront()
            } else {
                self.shelf.presentNearMouse()
            }
        }
        shakeDetector.start()
        registerHotKeys()

        // The watcher always runs; the preference is checked per event so the
        // menu toggle takes effect immediately.
        screenshotWatcher.onScreenshot = { [weak self] url in
            guard let self, Prefs.autoAddScreenshots else { return }
            self.store.importFile(at: url) { [weak self] result in
                guard let self else { return }
                switch result {
                case .added:
                    if !self.shelf.isVisible {
                        self.shelf.presentNearMouse()
                    }
                case .duplicate:
                    break
                case .failed(let reason):
                    NSLog("ShakeShelf: auto-add failed: \(reason)")
                    self.showAutoAddFailureHintOnce()
                }
            }
        }
        screenshotWatcher.start()

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "hasLaunchedBefore") {
            defaults.set(true, forKey: "hasLaunchedBefore")
            shelf.presentNearMouse()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "ShakeShelf")

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        showShelfItem = menu.addItem(withTitle: "Show Shelf", action: #selector(toggleShelf), keyEquivalent: "")
        showShelfItem.target = self
        let pasteItem = menu.addItem(withTitle: "Add Clipboard to Shelf", action: #selector(addClipboard), keyEquivalent: "")
        pasteItem.target = self
        let pickColorItem = menu.addItem(withTitle: "Pick Color from Screen…", action: #selector(pickColor), keyEquivalent: "")
        pickColorItem.target = self
        let captureFullItem = menu.addItem(withTitle: "Capture Full Screen", action: #selector(captureFullScreen), keyEquivalent: "")
        captureFullItem.target = self
        let captureSelectionItem = menu.addItem(withTitle: "Capture Selection…", action: #selector(captureSelection), keyEquivalent: "")
        captureSelectionItem.target = self
        let recordItem = menu.addItem(withTitle: "Record Screen…", action: #selector(recordScreen), keyEquivalent: "")
        recordItem.target = self
        let noteItem = menu.addItem(withTitle: "New Note…", action: #selector(newNote), keyEquivalent: "")
        noteItem.target = self
        let combinePDFItem = menu.addItem(withTitle: "Combine into One PDF", action: #selector(combineIntoPDF), keyEquivalent: "")
        combinePDFItem.target = self
        let stitchVerticalItem = menu.addItem(withTitle: "Stitch Images Vertically", action: #selector(stitchVertically), keyEquivalent: "")
        stitchVerticalItem.target = self
        let stitchHorizontalItem = menu.addItem(withTitle: "Stitch Images Horizontally", action: #selector(stitchHorizontally), keyEquivalent: "")
        stitchHorizontalItem.target = self
        let diffItem = menu.addItem(withTitle: "Diff Selected Snippets", action: #selector(diffSelectedSnippets), keyEquivalent: "")
        diffItem.target = self
        menu.addItem(.separator())

        autoAddItem = menu.addItem(withTitle: "Auto-Add New Screenshots", action: #selector(toggleAutoAdd), keyEquivalent: "")
        autoAddItem.target = self
        removeAfterDragItem = menu.addItem(withTitle: "Remove Items After Dragging Out", action: #selector(toggleRemoveAfterDrag), keyEquivalent: "")
        removeAfterDragItem.target = self
        launchAtLoginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        let shortcutsItem = menu.addItem(withTitle: "Keyboard Shortcuts…", action: #selector(configureShortcuts), keyEquivalent: "")
        shortcutsItem.target = self
        menu.addItem(.separator())

        let revealItem = menu.addItem(withTitle: "Show Items in Finder", action: #selector(revealStorage), keyEquivalent: "")
        revealItem.target = self
        let clearItem = menu.addItem(withTitle: "Clear Shelf", action: #selector(clearShelf), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(.separator())

        let quitItem = menu.addItem(withTitle: "Quit ShakeShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        showShelfItem.title = shelf.isVisible ? "Hide Shelf" : "Show Shelf"
        autoAddItem.state = Prefs.autoAddScreenshots ? .on : .off
        removeAfterDragItem.state = Prefs.removeAfterDragOut ? .on : .off
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func toggleShelf() {
        shelf.toggle()
    }

    @objc private func addClipboard() {
        shelf.addClipboardContents()
    }

    @objc private func pickColor() {
        shelf.pickColor()
    }

    @objc private func combineIntoPDF() {
        shelf.combineIntoPDF()
    }

    @objc private func newNote() {
        shelf.newNote()
    }

    @objc private func captureFullScreen() {
        shelf.capture(.fullScreen)
    }

    @objc private func captureSelection() {
        shelf.capture(.region)
    }

    @objc private func recordScreen() {
        shelf.capture(.video)
    }

    @objc private func stitchVertically() {
        shelf.stitchImages(axis: .vertical)
    }

    @objc private func stitchHorizontally() {
        shelf.stitchImages(axis: .horizontal)
    }

    @objc private func diffSelectedSnippets() {
        shelf.diffSelectedSnippets()
    }

    // MARK: - Preferences

    @objc private func toggleAutoAdd() {
        Prefs.autoAddScreenshots.toggle()
    }

    @objc private func toggleRemoveAfterDrag() {
        Prefs.removeAfterDragOut.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("ShakeShelf: launch-at-login toggle failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "macOS reported: \(error.localizedDescription)\n\nTip: this works most reliably when ShakeShelf.app is in /Applications."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Global shortcuts

    private func registerHotKeys() {
        for action in HotKeyAction.allCases {
            guard let combo = Prefs.hotKey(for: action) else {
                HotKeyCenter.shared.unregister(action)
                continue
            }
            let registered = HotKeyCenter.shared.register(action, combo: combo) { [weak self] in
                guard let self else { return }
                switch action {
                case .toggleShelf: self.shelf.toggle()
                case .newNote: self.shelf.newNote()
                case .captureRegion: self.shelf.captureRegion()
                }
            }
            if !registered {
                NSLog("ShakeShelf: \(combo.display) could not be registered")
            }
        }
    }

    @objc private func configureShortcuts() {
        ShortcutsWindowController.present { [weak self] in
            self?.registerHotKeys()
        }
    }

    /// Auto-add failing usually means macOS denied access to the screenshots
    /// folder. Surface it once per launch instead of failing silently forever.
    private func showAutoAddFailureHintOnce() {
        guard !didShowAutoAddFailureHint else { return }
        didShowAutoAddFailureHint = true
        let alert = NSAlert()
        alert.messageText = "ShakeShelf couldn't add your screenshot"
        alert.informativeText = "This usually means ShakeShelf doesn't have permission to read the folder where screenshots are saved (Desktop by default). Allow access under System Settings → Privacy & Security → Files and Folders, then take another screenshot. You can still drag screenshots onto the shelf yourself."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([store.storageDir])
    }

    @objc private func clearShelf() {
        store.clear()
    }
}
