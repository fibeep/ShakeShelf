import AppKit

/// Joins several screenshots into one image — the thing you want when
/// pasting a multi-step flow into a chat, where a PDF would be overkill.
enum ImageStitch {
    enum Axis {
        case vertical
        case horizontal

        var title: String {
            switch self {
            case .vertical: return "Stitch Images Vertically"
            case .horizontal: return "Stitch Images Horizontally"
            }
        }
    }

    /// Images keep their native pixels: a narrower shot is centered on the
    /// cross axis rather than upscaled, since upscaling a screenshot to match
    /// its neighbours visibly softens the text.
    static func stitch(_ urls: [URL], axis: Axis, gap: CGFloat = 12) -> Data? {
        let images = urls.compactMap(loadCGImage)
        guard !images.isEmpty else { return nil }

        let widths = images.map { CGFloat($0.width) }
        let heights = images.map { CGFloat($0.height) }
        let totalGap = gap * CGFloat(images.count - 1)

        let canvasSize: CGSize
        switch axis {
        case .vertical:
            canvasSize = CGSize(width: widths.max() ?? 0, height: heights.reduce(0, +) + totalGap)
        case .horizontal:
            canvasSize = CGSize(width: widths.reduce(0, +) + totalGap, height: heights.max() ?? 0)
        }
        guard canvasSize.width >= 1, canvasSize.height >= 1 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(canvasSize.width.rounded()),
                height: Int(canvasSize.height.rounded()),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // Gaps stay transparent so the result sits on whatever background the
        // destination app uses, light or dark.
        context.clear(CGRect(origin: .zero, size: canvasSize))

        switch axis {
        case .vertical:
            // CGContext is bottom-left origin, but the first image belongs at
            // the top, so walk downwards from the top edge.
            var y = canvasSize.height
            for image in images {
                let height = CGFloat(image.height)
                let width = CGFloat(image.width)
                y -= height
                context.draw(image, in: CGRect(
                    x: ((canvasSize.width - width) / 2).rounded(),
                    y: y,
                    width: width,
                    height: height
                ))
                y -= gap
            }
        case .horizontal:
            var x: CGFloat = 0
            for image in images {
                let height = CGFloat(image.height)
                let width = CGFloat(image.width)
                context.draw(image, in: CGRect(
                    x: x,
                    y: ((canvasSize.height - height) / 2).rounded(),
                    width: width,
                    height: height
                ))
                x += width + gap
            }
        }

        guard let output = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
