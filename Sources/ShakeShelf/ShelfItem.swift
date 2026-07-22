import AppKit
import ImageIO
import UniformTypeIdentifiers

final class ShelfItem: NSObject {
    enum Kind {
        case image
        case text
        case color
        case file
    }

    /// Colors are stored as a tiny file holding an sRGB hex string, so they
    /// persist and sort alongside everything else on the shelf.
    static let colorFileExtension = "shakecolor"

    /// Plain-text files larger than this are treated as generic files rather
    /// than text snippets, so the shelf never loads a huge log into memory.
    static let maxTextBytes = 1_000_000

    let id = UUID()
    let fileURL: URL
    let kind: Kind
    /// Image and generic-file tiles; nil for text snippets.
    let thumbnail: NSImage?
    /// Text snippets only.
    private(set) var text: String?
    private(set) var textModified: Date?
    /// Color swatches only.
    let color: NSColor?

    private init(fileURL: URL, kind: Kind, thumbnail: NSImage?, text: String?, textModified: Date?, color: NSColor? = nil) {
        self.fileURL = fileURL
        self.kind = kind
        self.thumbnail = thumbnail
        self.text = text
        self.textModified = textModified
        self.color = color
        super.init()
    }

    var filename: String { fileURL.lastPathComponent }

    /// Reads the file and builds the tile's content. Does disk I/O — call it
    /// off the main thread.
    static func load(fileURL: URL) -> ShelfItem {
        switch kind(of: fileURL) {
        case .color:
            let hex = (try? String(contentsOf: fileURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let color = NSColor(hexString: hex) else {
                return ShelfItem(fileURL: fileURL, kind: .file, thumbnail: fileIcon(for: fileURL), text: nil, textModified: nil)
            }
            return ShelfItem(fileURL: fileURL, kind: .color, thumbnail: nil, text: hex, textModified: nil, color: color)
        case .image:
            return ShelfItem(fileURL: fileURL, kind: .image, thumbnail: makeThumbnail(for: fileURL), text: nil, textModified: nil)
        case .text:
            if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                return ShelfItem(fileURL: fileURL, kind: .text, thumbnail: nil, text: text, textModified: modificationDate(of: fileURL))
            }
            return ShelfItem(fileURL: fileURL, kind: .file, thumbnail: fileIcon(for: fileURL), text: nil, textModified: nil)
        case .file:
            return ShelfItem(fileURL: fileURL, kind: .file, thumbnail: fileIcon(for: fileURL), text: nil, textModified: nil)
        }
    }

    /// Records text this app just wrote, so the tile updates without waiting
    /// for the modification-date check in `reloadTextIfNeeded`.
    func applyText(_ newText: String) {
        guard kind == .text else { return }
        text = newText
        textModified = Self.modificationDate(of: fileURL)
    }

    /// Re-reads a text snippet whose file changed on disk (e.g. the user
    /// opened it in TextEdit). Returns true if the preview changed.
    @discardableResult
    func reloadTextIfNeeded() -> Bool {
        guard kind == .text else { return false }
        let current = Self.modificationDate(of: fileURL)
        guard current != textModified else { return false }
        guard let updated = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        text = updated
        textModified = current
        return true
    }

    // MARK: - Loading helpers

    private static func kind(of url: URL) -> Kind {
        if url.pathExtension == colorFileExtension { return .color }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .plainText), fileSize(of: url) <= Int64(maxTextBytes) { return .text }
        return .file
    }

    private static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func fileIcon(for url: URL) -> NSImage {
        // PDFs get a real first-page preview; a generic document icon would
        // make every exported PDF on the shelf look identical.
        if url.pathExtension.lowercased() == "pdf", let preview = PDFExport.thumbnail(for: url) {
            return preview
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 128, height: 128)
        return icon
    }

    /// A real downsampled bitmap via ImageIO — unlike an NSImage drawing
    /// handler, this does not retain the full-resolution image in memory.
    static func makeThumbnail(for url: URL, maxDimension: CGFloat = 320) -> NSImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension * 2), // retina-quality
        ]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            let size = NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2)
            return NSImage(cgImage: cgImage, size: size)
        }
        return fileIcon(for: url)
    }
}
