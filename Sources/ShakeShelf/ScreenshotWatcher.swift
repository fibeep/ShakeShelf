import AppKit

/// Watches the folder macOS saves screenshots to and reports each new one.
///
/// This deliberately does not use Spotlight. macOS filters Spotlight results
/// by privacy permission, so an app without Desktop access gets no results for
/// the Desktop — and since the app only touched the Desktop after Spotlight
/// reported a screenshot, it never triggered the permission prompt, never
/// appeared in Files & Folders, and never got access. Watching the folder
/// directly breaks that loop: the first read of the folder is what makes macOS
/// ask for access.
///
/// Screenshots are recognised by the `kMDItemIsScreenCapture` extended
/// attribute that `screencapture` stamps on every file it writes, so renamed
/// or localised filenames ("Captura de pantalla…") are still caught. Only
/// screenshots saved to disk are seen; clipboard-only captures (⌃⇧⌘4) never
/// produce a file.
final class ScreenshotWatcher {
    var onScreenshot: ((URL) -> Void)?
    /// The screenshot folder couldn't be read, almost always because Desktop
    /// access was denied. Retrying continues in the background, so granting
    /// access later takes effect without a relaunch.
    var onAccessDenied: ((URL) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var watchedFolder: URL?
    private var enabled = false
    private var starting = false

    private static let retryInterval: TimeInterval = 5

    /// Re-evaluated on every (re)start, so a screenshot location changed in
    /// ⇧⌘5 → Options is picked up.
    private let folderProvider: () -> URL

    init(folderProvider: @escaping () -> URL = ScreenshotWatcher.screenshotFolder) {
        self.folderProvider = folderProvider
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        enabled = true
        guard source == nil, !starting else { return }
        starting = true

        let folder = folderProvider()
        // The first read of a protected folder blocks until the user answers
        // the permission prompt, so keep it off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try FileManager.default.contentsOfDirectory(atPath: folder.path) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.starting = false
                guard self.enabled else { return }
                switch result {
                case .success(let names):
                    self.beginWatching(folder, existing: names)
                case .failure(let error):
                    NSLog("ShakeShelf: cannot read screenshot folder \(folder.path): \(error)")
                    if Self.isPermissionError(error) {
                        self.onAccessDenied?(folder)
                    }
                    self.scheduleRetry()
                }
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        enabled = false
        source?.cancel()
        source = nil
        watchedFolder = nil
        known = []
    }

    // MARK: - Watching

    private func beginWatching(_ folder: URL, existing: [String]) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("ShakeShelf: cannot watch \(folder.path) (errno \(errno))")
            scheduleRetry()
            return
        }
        // Screenshots already on disk are left alone; only new ones are added.
        known = Set(existing)
        watchedFolder = folder

        // A directory's .write event fires whenever an entry is created,
        // removed, or renamed inside it.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // The folder itself went away or moved (or the screenshot
                // location changed); start over against the current location.
                self.restart()
            } else {
                self.scan()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        NSLog("ShakeShelf: watching \(folder.path) for screenshots")
    }

    private func restart() {
        source?.cancel()
        source = nil
        watchedFolder = nil
        known = []
        if enabled { start() }
    }

    private func scheduleRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
            guard let self, self.enabled, self.source == nil else { return }
            self.start()
        }
    }

    private func scan() {
        guard let folder = watchedFolder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let current = Set(names)
        let added = current.subtracting(known)
        known = current
        // screencapture writes to a hidden temporary name and renames it into
        // place, so the visible file is the one to look at.
        for name in added where !name.hasPrefix(".") {
            checkWhenReady(folder.appendingPathComponent(name), attemptsLeft: 5)
        }
    }

    /// The attribute can land a moment after the file appears, so look a few
    /// times before deciding a new file isn't a screenshot.
    private func checkWhenReady(_ url: URL, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, FileManager.default.fileExists(atPath: url.path) else { return }
            if Self.isScreenCapture(url) {
                self.onScreenshot?(url)
            } else if attemptsLeft > 1 {
                self.checkWhenReady(url, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    // MARK: - Helpers

    /// Where macOS saves screenshots: the location chosen in ⇧⌘5 → Options,
    /// or the Desktop when none has been set.
    static func screenshotFolder() -> URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = (location as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if !expanded.isEmpty,
               FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
    }

    /// True when `screencapture` marked the file as a screen capture. The
    /// attribute holds a binary property list containing a boolean.
    static func isScreenCapture(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(url.path, name, buffer.baseAddress, size, 0, 0)
        }
        guard read == size,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EPERM) || underlying.code == Int(EACCES) {
            return true
        }
        return false
    }
}
