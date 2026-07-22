import AppKit

protocol ShelfStoreDelegate: AnyObject {
    func shelfStoreDidChange(_ store: ShelfStore)
}

enum ImportResult {
    case added(ShelfItem)
    case duplicate(ShelfItem)
    /// Carries a reason so callers can explain the failure instead of
    /// leaving the user with a tile that never appeared.
    case failed(String)
}

/// Holds the shelf's items. Every item — image, file, or text snippet — is
/// backed by a file copied into the app's own storage directory, so items
/// survive app relaunches and stay available after the original is gone.
///
/// All state mutations happen on the main thread; all disk work (dedupe
/// scans, copies, thumbnail generation) runs on a serial background queue so
/// dropping a large file never blocks the UI or freezes the drop animation.
final class ShelfStore {
    weak var delegate: ShelfStoreDelegate?
    private(set) var items: [ShelfItem] = []

    let storageDir: URL

    private let fileQueue = DispatchQueue(label: "com.salomoncohen.shakeshelf.files", qos: .userInitiated)

    /// Files scheduled for deletion after a drag-out; persisted so they are
    /// neither resurrected nor leaked if the app quits before the timer fires.
    private static let pendingDeletionKey = "pendingDeletionFilenames"
    /// How long a dragged-out file stays on disk: the destination app may
    /// still be reading it (async uploads, attachment builders, Finder copies).
    private static let dragOutDeletionGrace: TimeInterval = 90
    /// Skip byte-comparison dedupe for anything bigger than this.
    private static let dedupeMaxBytes: Int64 = 64 * 1024 * 1024

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        storageDir = base.appendingPathComponent("ShakeShelf/Items", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        deleteTombstonedFiles()
        loadExisting()
    }

    private func loadExisting() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.addedToDirectoryDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        // Sort by when the file was added to the shelf, not its mtime —
        // copyItem preserves the source's dates, so mtime would reshuffle
        // imported files behind auto-added screenshots across relaunches.
        func addedDate(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
            return values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
        }
        items = urls.sorted { addedDate($0) < addedDate($1) }.map(ShelfItem.load(fileURL:))
    }

    // MARK: - Import

    func importFile(at sourceURL: URL, completion: ((ImportResult) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let fm = FileManager.default

        // Files already inside our storage folder: match known items, and
        // adopt strays the user copied in via "Show Items in Finder".
        if isInStorage(sourceURL) {
            let path = sourceURL.standardizedFileURL.path
            if let existing = items.first(where: { $0.fileURL.standardizedFileURL.path == path }) {
                completion?(.duplicate(existing))
                return
            }
            guard fm.fileExists(atPath: sourceURL.path) else {
                completion?(.failed("\(sourceURL.lastPathComponent) no longer exists."))
                return
            }
            loadAndAppend(url: sourceURL, completion: completion)
            return
        }

        guard fm.fileExists(atPath: sourceURL.path) else {
            completion?(.failed("\(sourceURL.lastPathComponent) could not be read. If it lives in a protected folder, allow access under System Settings \u{2192} Privacy & Security \u{2192} Files and Folders."))
            return
        }

        let knownURLs = items.map(\.fileURL)
        fileQueue.async { [weak self] in
            guard let self else { return }
            if let duplicateURL = Self.firstDuplicate(of: sourceURL, in: knownURLs) {
                DispatchQueue.main.async {
                    if let item = self.items.first(where: { $0.fileURL == duplicateURL }) {
                        completion?(.duplicate(item))
                    } else {
                        completion?(.failed("The matching item is no longer on the shelf."))
                    }
                }
                return
            }
            let dest = self.uniqueDestination(for: sourceURL.lastPathComponent)
            do {
                try fm.copyItem(at: sourceURL, to: dest)
            } catch {
                NSLog("ShakeShelf: failed to copy \(sourceURL.path): \(error)")
                DispatchQueue.main.async {
                    completion?(.failed("\(sourceURL.lastPathComponent) couldn't be copied to the shelf: \(error.localizedDescription)"))
                }
                return
            }
            let item = ShelfItem.load(fileURL: dest)
            DispatchQueue.main.async {
                self.items.append(item)
                self.notify()
                completion?(.added(item))
            }
        }
    }

    func importImageData(
        _ data: Data,
        preferredExtension ext: String,
        baseName: String? = nil,
        completion: ((ImportResult) -> Void)? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let base = baseName ?? "Image \(Self.timestampFormatter.string(from: Date()))"
        writeAndAppend(name: "\(base).\(ext)", write: { try data.write(to: $0) }, completion: completion)
    }

    /// Adds a text snippet, stored as a .txt file alongside the images.
    func importText(_ string: String, completion: ((ImportResult) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(.failed("There was no text to add."))
            return
        }
        // Beyond this size ShelfItem stops treating the file as an editable
        // snippet, which would silently turn the tile into a file attachment
        // and defeat the string-only dedupe. Refuse clearly instead.
        let byteCount = trimmed.utf8.count
        guard byteCount <= ShelfItem.maxTextBytes else {
            let megabytes = String(format: "%.1f", Double(byteCount) / 1_000_000)
            completion?(.failed(
                "That snippet is \(megabytes) MB, past the \(ShelfItem.maxTextBytes / 1_000_000) MB limit for text tiles. "
                + "Save it to a file and drop the file on the shelf instead."
            ))
            return
        }
        if let existing = items.first(where: { $0.kind == .text && $0.text == trimmed }) {
            completion?(.duplicate(existing))
            return
        }
        let name = Self.filename(forText: trimmed)
        writeAndAppend(name: name, write: { try trimmed.write(to: $0, atomically: true, encoding: .utf8) }, completion: completion)
    }

    /// Rewrites an existing snippet in place, keeping its position on the
    /// shelf. Calls back with an error message, or nil on success.
    func updateText(_ item: ShelfItem, to newText: String, completion: @escaping (String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.kind == .text else {
            completion("That item isn't a text snippet.")
            return
        }
        guard trimmed.utf8.count <= ShelfItem.maxTextBytes else {
            completion("That snippet is past the \(ShelfItem.maxTextBytes / 1_000_000) MB limit for text tiles.")
            return
        }
        let url = item.fileURL
        fileQueue.async { [weak self] in
            do {
                try trimmed.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("ShakeShelf: failed to update \(url.lastPathComponent): \(error)")
                DispatchQueue.main.async { completion(error.localizedDescription) }
                return
            }
            DispatchQueue.main.async {
                // Set the text directly rather than waiting for the mtime
                // check in refresh() to notice.
                item.applyText(trimmed)
                self?.notify()
                completion(nil)
            }
        }
    }

    /// Adds a color swatch, stored as a tiny file holding its sRGB hex.
    func importColor(_ color: NSColor, completion: ((ImportResult) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let hex = color.hexString
        if let existing = items.first(where: { $0.kind == .color && $0.text == hex }) {
            completion?(.duplicate(existing))
            return
        }
        let name = "Color \(hex.dropFirst()).\(ShelfItem.colorFileExtension)"
        writeAndAppend(name: name, write: { try hex.write(to: $0, atomically: true, encoding: .utf8) }, completion: completion)
    }

    /// Imports whatever a pasteboard holds — a file, an image, or text.
    /// Used for both drops and the "add from clipboard" action, so both paths
    /// behave identically. Returns false if there was nothing usable.
    /// Note the return value only reports whether the pasteboard held
    /// something we recognized — the import itself finishes later, so callers
    /// that care about success must use `completion`.
    @discardableResult
    func importContents(of pasteboard: NSPasteboard, completion: ((ImportResult) -> Void)? = nil) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            for url in urls {
                importFile(at: url, completion: completion)
            }
            return true
        }

        // A pasteboard often carries both an image and a string (copying from
        // Word or a browser). NSPasteboard lists types in the source app's
        // order of preference, so let the first one we recognize win rather
        // than always favouring one kind.
        for type in pasteboard.types ?? [] {
            if Self.bitmapPasteboardTypes.contains(type.rawValue) {
                if let image = NSImage(pasteboard: pasteboard),
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    importImageData(png, preferredExtension: "png", completion: completion)
                    return true
                }
            }
            if type == .string {
                if let string = pasteboard.string(forType: .string),
                   !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    importText(string, completion: completion)
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Removal

    /// Explicit removal (✕ button, context menu): delete the backing file now.
    func remove(_ item: ShelfItem) {
        dispatchPrecondition(condition: .onQueue(.main))
        items.removeAll { $0.id == item.id }
        let url = item.fileURL
        fileQueue.async { try? FileManager.default.removeItem(at: url) }
        notify()
    }

    /// The tile was dragged onto the Dock's Trash: the file should end up in
    /// the Trash (recoverable), not be hard-deleted.
    func removeToTrash(_ item: ShelfItem) {
        dispatchPrecondition(condition: .onQueue(.main))
        items.removeAll { $0.id == item.id }
        let url = item.fileURL
        fileQueue.async {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        }
        notify()
    }

    /// Drag-out removal: the entry leaves the shelf immediately, but the file
    /// stays at its path for a grace period because the destination app may
    /// still be reading it. A persisted tombstone ensures the file is cleaned
    /// up (and not re-listed) if the app quits before the timer fires.
    func removeAfterDragOut(_ item: ShelfItem) {
        dispatchPrecondition(condition: .onQueue(.main))
        items.removeAll { $0.id == item.id }
        notify()
        let url = item.fileURL
        let name = item.filename
        addTombstone(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragOutDeletionGrace) { [weak self] in
            guard let self else { return }
            self.fileQueue.async {
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { self.removeTombstone(name) }
            }
        }
    }

    func clear() {
        dispatchPrecondition(condition: .onQueue(.main))
        let urls = items.map(\.fileURL)
        items.removeAll()
        fileQueue.async {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
        notify()
    }

    /// Drops entries whose backing file was deleted behind the app's back and
    /// re-reads text snippets edited outside the app. The storage folder is
    /// user-visible via "Show Items in Finder", so both do happen.
    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        let fm = FileManager.default
        var changed = false

        let missingIDs = Set(items.filter { !fm.fileExists(atPath: $0.fileURL.path) }.map(\.id))
        if !missingIDs.isEmpty {
            items.removeAll { missingIDs.contains($0.id) }
            changed = true
        }
        for item in items where item.reloadTextIfNeeded() {
            changed = true
        }
        if changed { notify() }
    }

    // MARK: - Helpers

    private func loadAndAppend(url: URL, completion: ((ImportResult) -> Void)?) {
        fileQueue.async { [weak self] in
            let item = ShelfItem.load(fileURL: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.items.append(item)
                self.notify()
                completion?(.added(item))
            }
        }
    }

    private func writeAndAppend(name: String, write: @escaping (URL) throws -> Void, completion: ((ImportResult) -> Void)?) {
        fileQueue.async { [weak self] in
            guard let self else { return }
            let dest = self.uniqueDestination(for: name)
            do {
                try write(dest)
            } catch {
                NSLog("ShakeShelf: failed to write \(name): \(error)")
                DispatchQueue.main.async {
                    completion?(.failed("\(name) couldn't be saved to the shelf: \(error.localizedDescription)"))
                }
                return
            }
            let item = ShelfItem.load(fileURL: dest)
            DispatchQueue.main.async {
                self.items.append(item)
                self.notify()
                completion?(.added(item))
            }
        }
    }

    /// Deliberately narrower than `NSImage.imageTypes`, which also lists PDF,
    /// SVG and PICT. Apps like Preview and Keynote offer a PDF rendition of a
    /// text selection, and treating that as an image would rasterize a
    /// perfectly good snippet into a screenshot of itself.
    private static let bitmapPasteboardTypes: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.jpeg-2000",
        "public.tiff",
        "public.heic",
        "com.compuserve.gif",
        "com.microsoft.bmp",
        "com.apple.icns",
    ]

    private func isInStorage(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(storageDir.standardizedFileURL.path + "/")
    }

    private static func firstDuplicate(of url: URL, in candidates: [URL]) -> URL? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size <= dedupeMaxBytes else { return nil }
        for candidate in candidates {
            guard let candidateAttrs = try? fm.attributesOfItem(atPath: candidate.path),
                  let candidateSize = (candidateAttrs[.size] as? NSNumber)?.int64Value,
                  candidateSize == size else { continue }
            if fm.contentsEqual(atPath: url.path, andPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Names a snippet after its first line so the file is recognizable in
    /// Finder, falling back to a timestamp when that yields nothing usable.
    private static func filename(forText text: String) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let cleaned = firstLine.unicodeScalars
            .filter { allowed.contains($0) }
            .map(Character.init)
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespaces)

        // Clamp by encoded bytes, not characters: alphanumerics admits
        // combining marks, so a single character can carry unbounded scalars
        // and blow past the filesystem's 255-byte name limit.
        var base = ""
        for scalar in cleaned.unicodeScalars {
            if base.utf8.count + String(scalar).utf8.count > 120 { break }
            base.unicodeScalars.append(scalar)
        }
        base = base.trimmingCharacters(in: .whitespaces)

        if base.isEmpty {
            return "Text \(timestampFormatter.string(from: Date())).txt"
        }
        return "\(base).txt"
    }

    /// Only call on fileQueue: pairs an existence check with the copy/write
    /// that follows, and the serial queue makes that pairing race-free.
    private func uniqueDestination(for filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = storageDir.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = storageDir.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    // MARK: - Drag-out tombstones

    private func deleteTombstonedFiles() {
        let defaults = UserDefaults.standard
        let pending = defaults.stringArray(forKey: Self.pendingDeletionKey) ?? []
        guard !pending.isEmpty else { return }
        for name in pending {
            try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(name))
        }
        defaults.removeObject(forKey: Self.pendingDeletionKey)
    }

    private func addTombstone(_ name: String) {
        let defaults = UserDefaults.standard
        var pending = Set(defaults.stringArray(forKey: Self.pendingDeletionKey) ?? [])
        pending.insert(name)
        defaults.set(Array(pending), forKey: Self.pendingDeletionKey)
    }

    private func removeTombstone(_ name: String) {
        let defaults = UserDefaults.standard
        var pending = Set(defaults.stringArray(forKey: Self.pendingDeletionKey) ?? [])
        pending.remove(name)
        defaults.set(Array(pending), forKey: Self.pendingDeletionKey)
    }

    private func notify() {
        delegate?.shelfStoreDidChange(self)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
}
