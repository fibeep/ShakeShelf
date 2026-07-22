import AppKit

/// How each kind of shelf item presents itself to other apps during a drag.
enum ShelfPasteboard {
    static func writer(for item: ShelfItem) -> NSPasteboardWriting {
        // Text snippets are written as plain text only: a file URL would make
        // rich targets like Slack or Mail attach a .txt instead of inserting
        // the text, which is the opposite of what the shelf is for.
        if item.kind == .text, let text = item.text {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(text, forType: .string)
            return pasteboardItem
        }
        // Colors carry both the archived NSColor (so color wells in Xcode,
        // Sketch and the system picker accept the drop) and the hex string
        // (so text fields get something useful). Neither target misreads the
        // other, unlike the file-URL case above.
        if item.kind == .color, let color = item.color {
            let pasteboardItem = NSPasteboardItem()
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
                pasteboardItem.setData(data, forType: .color)
            }
            pasteboardItem.setString(color.hexString, forType: .string)
            return pasteboardItem
        }
        return item.fileURL as NSURL
    }

    /// Text and color tiles have no thumbnail, so the tile itself is
    /// snapshotted when it is available (only the tile that started the drag
    /// can be; others fall back to a rendered stand-in).
    static func dragImage(for item: ShelfItem, snapshotting view: NSView?) -> NSImage? {
        if item.kind != .text && item.kind != .color { return item.thumbnail }
        if let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
            return image
        }
        return standInImage(for: item)
    }

    private static func standInImage(for item: ShelfItem) -> NSImage {
        let size = NSSize(width: 104, height: 104)
        return NSImage(size: size, flipped: false) { rect in
            if item.kind == .color, let color = item.color {
                color.setFill()
                rect.fill()
            } else {
                NSColor.textBackgroundColor.setFill()
                rect.fill()
                let text = String((item.text ?? "").prefix(120)) as NSString
                text.draw(
                    in: rect.insetBy(dx: 6, dy: 6),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
            }
            return true
        }
    }
}
