import AppKit

enum ColorActions {
    static var all: [ShelfAction] {
        var actions: [ShelfAction] = []

        // One "Copy as" entry per developer format, filled in from the item.
        for label in formatLabels {
            actions.append(ShelfAction(title: label, group: .copy, submenu: "Copy as", kinds: [.color]) { item, context in
                guard let color = item.color,
                      let format = color.developerFormats.first(where: { $0.label == label }) else {
                    context.reportFailure("no \(label) representation for color")
                    return
                }
                ShelfActionSupport.copyToPasteboard(format.value)
            })
        }

        actions.append(ShelfAction(title: "Extract Colors", group: .transform, kinds: [.image]) { item, context in
            ColorSampling.extractPalette(from: item, in: context)
        })

        return actions
    }

    /// Kept in sync with NSColor.developerFormats — the labels are the join key.
    private static let formatLabels = [
        "Hex", "CSS rgb()", "CSS hsl()", "SwiftUI Color", "UIColor", "NSColor",
    ]
}

enum ColorSampling {
    /// Held for the duration of a sample so the sampler is not deallocated
    /// mid-interaction.
    private static var activeSampler: NSColorSampler?

    /// Shows the system loupe. Deliberately uses NSColorSampler rather than a
    /// hand-rolled screen grab: it needs no Screen Recording permission.
    static func pickFromScreen(into store: ShelfStore, completion: ((NSColor?) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let sampler = NSColorSampler()
        activeSampler = sampler
        NSApp.activate(ignoringOtherApps: true)
        sampler.show { color in
            activeSampler = nil
            guard let color else {
                completion?(nil)
                return
            }
            store.importColor(color)
            completion?(color)
        }
    }

    /// Samples a grid of pixels and keeps the most common visually distinct
    /// colors — enough to lift a palette out of a screenshot or mockup.
    static func extractPalette(from item: ShelfItem, in context: ShelfActionContext) {
        let url = item.fileURL
        context.inBackground({ dominantColors(in: url, maxCount: 5) }) { colors in
            guard !colors.isEmpty else {
                context.reportFailure("could not read colors from \(url.lastPathComponent)")
                return
            }
            for color in colors {
                context.store.importColor(color)
            }
        }
    }

    private static func dominantColors(in url: URL, maxCount: Int) -> [NSColor] {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        // Downsample to a small grid; we only need color frequency, not detail.
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmapContext = CGContext(
                data: &pixels,
                width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return [] }
        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Bucket into a coarse 32-level-per-channel histogram.
        var histogram: [Int: Int] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[index + 3] > 200 else { continue } // skip transparent
            let r = Int(pixels[index]) / 8
            let g = Int(pixels[index + 1]) / 8
            let b = Int(pixels[index + 2]) / 8
            histogram[(r << 10) | (g << 5) | b, default: 0] += 1
        }

        let ranked = histogram.sorted { $0.value > $1.value }
        var picked: [NSColor] = []
        for (bucket, _) in ranked {
            let r = CGFloat((bucket >> 10) & 0x1F) * 8 / 255
            let g = CGFloat((bucket >> 5) & 0x1F) * 8 / 255
            let b = CGFloat(bucket & 0x1F) * 8 / 255
            let candidate = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            let tooSimilar = picked.contains { existing in
                guard let a = existing.srgbComponents, let c = candidate.srgbComponents else { return false }
                return abs(a.r - c.r) + abs(a.g - c.g) + abs(a.b - c.b) < 48
            }
            if !tooSimilar { picked.append(candidate) }
            if picked.count == maxCount { break }
        }
        return picked
    }
}
