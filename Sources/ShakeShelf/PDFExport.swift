import AppKit
import PDFKit

enum PDFExport {
    /// Longest page edge, in points. Letter's long edge — big enough that a
    /// screenshot stays legible, small enough that the page isn't absurd.
    private static let maxPageEdge: CGFloat = 792

    /// Each page takes the shape of its own image rather than being
    /// letterboxed onto a fixed paper size, so the PDF looks exactly like the
    /// screenshots it came from. Printers scale to fit anyway.
    static func pageRect(for image: CGImage) -> CGRect {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return CGRect(x: 0, y: 0, width: 612, height: 792) }
        // Never scale a small image up: below the cap, one pixel is one point.
        let scale = min(1, maxPageEdge / max(width, height))
        return CGRect(x: 0, y: 0, width: (width * scale).rounded(), height: (height * scale).rounded())
    }

    /// Renders one page per image, in the order given.
    static func makePDF(from imageURLs: [URL]) -> Data? {
        let images = imageURLs.compactMap(loadCGImage)
        guard !images.isEmpty else { return nil }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else { return nil }

        for image in images {
            var box = pageRect(for: image)
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// Merges a mixed list of PDFs and images into one document, in the order
    /// given. PDFs contribute all of their pages; images become one page each,
    /// sized by `pageRect` so they match the single-image export.
    static func merge(_ urls: [URL]) -> Data? {
        let merged = PDFDocument()
        for url in urls {
            let source: PDFDocument?
            if isPDF(url) {
                source = PDFDocument(url: url)
            } else if let data = makePDF(from: [url]) {
                source = PDFDocument(data: data)
            } else {
                source = nil
            }
            guard let source else {
                NSLog("ShakeShelf: skipping \(url.lastPathComponent) while merging — could not read it")
                continue
            }
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard merged.pageCount > 0 else { return nil }
        return merged.dataRepresentation()
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// First-page preview so PDF tiles show their contents instead of a
    /// generic document icon.
    static func thumbnail(for url: URL, maxDimension: CGFloat = 320) -> NSImage? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        return page.thumbnail(of: NSSize(width: maxDimension, height: maxDimension), for: .mediaBox)
    }

    static func pageCount(of url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    /// One single-page PDF per page, in order.
    static func splitPages(of url: URL) -> [Data] {
        guard let document = PDFDocument(url: url) else { return [] }
        var pages: [Data] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            if let data = single.dataRepresentation() {
                pages.append(data)
            }
        }
        return pages
    }

    /// Rasterizes each page, for pulling a figure out of a document.
    static func renderPagesAsPNG(of url: URL, scale: CGFloat = 2) -> [Data] {
        guard let document = PDFDocument(url: url) else { return [] }
        var images: [Data] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let rendered = page.thumbnail(of: size, for: .mediaBox)
            guard let tiff = rendered.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            images.append(png)
        }
        return images
    }
}

enum PDFActions {
    /// How many new tiles we will create without asking first.
    private static let confirmThreshold = 12

    static var all: [ShelfAction] {
        [
            ShelfAction(
                title: "Split into Pages",
                group: .transform,
                isEnabled: isMultiPagePDF,
                run: { item, context in
                    run(item, context, verb: "split") { PDFExport.splitPages(of: $0) }
                        .map { pages, base in
                            for (index, data) in pages.enumerated() {
                                context.store.importImageData(
                                    data,
                                    preferredExtension: "pdf",
                                    baseName: "\(base) page \(index + 1)"
                                )
                            }
                        }
                }
            ),
            ShelfAction(
                title: "Export Pages as PNG",
                group: .convert,
                isEnabled: isPDF,
                run: { item, context in
                    run(item, context, verb: "export") { PDFExport.renderPagesAsPNG(of: $0) }
                        .map { pages, base in
                            for (index, data) in pages.enumerated() {
                                let name = pages.count == 1 ? base : "\(base) page \(index + 1)"
                                context.store.importImageData(data, preferredExtension: "png", baseName: name)
                            }
                        }
                }
            ),
        ]
    }

    private static func isPDF(_ item: ShelfItem) -> Bool {
        item.kind == .file && item.fileURL.pathExtension.lowercased() == "pdf"
    }

    private static func isMultiPagePDF(_ item: ShelfItem) -> Bool {
        isPDF(item) && PDFExport.pageCount(of: item.fileURL) > 1
    }

    /// Shared confirm-then-work-in-background wrapper. Returns a tiny
    /// applicator so each action only describes what to do with the results.
    private static func run(
        _ item: ShelfItem,
        _ context: ShelfActionContext,
        verb: String,
        work: @escaping (URL) -> [Data]
    ) -> PageWorkResult {
        let url = item.fileURL
        let base = (item.filename as NSString).deletingPathExtension
        let count = PDFExport.pageCount(of: url)
        guard count > 0 else {
            context.reportFailure("could not read \(item.filename)")
            return PageWorkResult(context: context, url: url, base: base, work: nil)
        }
        if count > confirmThreshold {
            let alert = NSAlert()
            alert.messageText = "\(item.filename) has \(count) pages"
            alert.informativeText = "This will add \(count) new tiles to the shelf. Continue?"
            alert.addButton(withTitle: "\(verb.capitalized) \(count) Pages")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else {
                return PageWorkResult(context: context, url: url, base: base, work: nil)
            }
        }
        return PageWorkResult(context: context, url: url, base: base, work: work)
    }

    private struct PageWorkResult {
        let context: ShelfActionContext
        let url: URL
        let base: String
        let work: ((URL) -> [Data])?

        func map(_ apply: @escaping ([Data], String) -> Void) {
            guard let work else { return }
            let url = self.url
            let base = self.base
            let context = self.context
            context.inBackground({ work(url) }) { pages in
                guard !pages.isEmpty else {
                    context.reportFailure("no pages produced from \(url.lastPathComponent)")
                    return
                }
                apply(pages, base)
            }
        }
    }
}
