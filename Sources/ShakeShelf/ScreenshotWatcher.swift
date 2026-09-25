import AppKit

/// Watches Spotlight metadata for newly created screen captures
/// (files with kMDItemIsScreenCapture == 1, e.g. saved by ⇧⌘3 / ⇧⌘4).
///
/// Only screenshots saved to disk are detected; captures that go straight
/// to the clipboard (⌃⇧⌘4) never produce a file.
final class ScreenshotWatcher: NSObject {
    var onScreenshot: ((URL) -> Void)?

    private let query = NSMetadataQuery()

    override init() {
        super.init()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = Self.searchScopes()
        query.operationQueue = .main
        query.notificationBatchingInterval = 0.2
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
    }

    func start() {
        DispatchQueue.main.async { [query] in
            query.start()
        }
    }

    /// The home folder covers the default Desktop location and Documents /
    /// Downloads. If the user has pointed macOS at a custom screenshot folder
    /// outside home (`defaults read com.apple.screencapture location`), add it
    /// so those screenshots are still caught.
    private static func searchScopes() -> [Any] {
        var scopes: [Any] = [NSMetadataQueryUserHomeScope]
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = (location as NSString).expandingTildeInPath
            if !expanded.isEmpty {
                scopes.append(URL(fileURLWithPath: expanded, isDirectory: true))
            }
        }
        return scopes
    }

    func stop() {
        query.stop()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func queryDidUpdate(_ note: Notification) {
        guard let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem],
              !added.isEmpty else { return }
        for mdItem in added {
            guard let path = mdItem.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            // Give screencapture a moment to finish writing the file.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.onScreenshot?(url)
            }
        }
    }
}
