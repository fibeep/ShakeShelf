import AppKit
import UniformTypeIdentifiers
import Vision

enum ImageActions {
    static var all: [ShelfAction] {
        var actions: [ShelfAction] = [
            ShelfAction(title: "Extract Text (OCR)", group: .transform, kinds: [.image]) { item, context in
                let url = item.fileURL
                context.inBackground({ TextRecognition.recognizeText(in: url) }) { text in
                    guard let text, !text.isEmpty else {
                        context.showMessage(
                            "No text found",
                            "ShakeShelf couldn't recognize any text in \(url.lastPathComponent)."
                        )
                        return
                    }
                    context.store.importText(text)
                }
            },

            ShelfAction(title: "Redact…", group: .transform, kinds: [.image]) { item, context in
                RedactionWindowController.present(for: item, store: context.store)
            },

            ShelfAction(title: "Resize to Width…", group: .transform, kinds: [.image]) { item, context in
                guard let size = ImageExport.pixelSize(of: item.fileURL) else {
                    context.reportFailure("could not read \(item.filename)")
                    return
                }
                guard let input = ShelfActionSupport.prompt(
                    title: "Resize \(item.filename)",
                    message: "Currently \(size.width) × \(size.height) px. New width in pixels:",
                    defaultValue: "\(size.width / 2)"
                ) else { return }
                guard let width = Int(input), width > 0, width <= 20000 else {
                    context.showMessage("Invalid width", "Enter a whole number of pixels between 1 and 20000.")
                    return
                }
                let url = item.fileURL
                let base = (item.filename as NSString).deletingPathExtension
                context.inBackground({ ImageExport.resized(url, toWidth: width) }) { data in
                    guard let data else {
                        context.reportFailure("could not resize \(url.lastPathComponent)")
                        return
                    }
                    context.store.importImageData(data, preferredExtension: "png", baseName: "\(base) \(width)w")
                }
            },

            ShelfAction(title: "Halve Size (2x → 1x)", group: .transform, kinds: [.image]) { item, context in
                guard let size = ImageExport.pixelSize(of: item.fileURL), size.width > 1 else {
                    context.reportFailure("could not read \(item.filename)")
                    return
                }
                let url = item.fileURL
                let base = (item.filename as NSString).deletingPathExtension
                context.inBackground({ ImageExport.resized(url, toWidth: size.width / 2) }) { data in
                    guard let data else {
                        context.reportFailure("could not resize \(url.lastPathComponent)")
                        return
                    }
                    context.store.importImageData(data, preferredExtension: "png", baseName: "\(base) 1x")
                }
            },

            ShelfAction(title: "PDF", group: .convert, submenu: "Convert to", kinds: [.image]) { item, context in
                let url = item.fileURL
                let base = (item.filename as NSString).deletingPathExtension
                context.inBackground({ PDFExport.makePDF(from: [url]) }) { data in
                    guard let data else {
                        context.reportFailure("could not build a PDF from \(url.lastPathComponent)")
                        return
                    }
                    context.store.importImageData(data, preferredExtension: "pdf", baseName: base)
                }
            },

            ShelfAction(title: "Read QR / Barcode", group: .transform, kinds: [.image]) { item, context in
                let url = item.fileURL
                context.inBackground({ QRCode.decode(from: url) }) { payloads in
                    guard !payloads.isEmpty else {
                        context.showMessage(
                            "No code found",
                            "ShakeShelf couldn't find a QR code or barcode in \(url.lastPathComponent)."
                        )
                        return
                    }
                    context.addResultText(payloads.joined(separator: "\n"))
                }
            },

            ShelfAction(title: "Copy as Base64 Data URI", group: .copy, kinds: [.image]) { item, context in
                let url = item.fileURL
                context.inBackground({ ImageExport.dataURI(for: url) }) { uri in
                    guard let uri else {
                        context.reportFailure("could not encode \(url.lastPathComponent)")
                        return
                    }
                    ShelfActionSupport.copyToPasteboard(uri)
                }
            },
        ]

        for format in ImageExport.Format.allCases {
            actions.append(ShelfAction(
                title: format.title,
                group: .convert,
                submenu: "Convert to",
                isEnabled: { item in
                    // No point offering a conversion to the format it already is.
                    item.kind == .image && item.fileURL.pathExtension.lowercased() != format.fileExtension
                },
                run: { item, context in
                    let url = item.fileURL
                    let base = (item.filename as NSString).deletingPathExtension
                    context.inBackground({ ImageExport.convert(url, to: format) }) { data in
                        guard let data else {
                            context.reportFailure("could not convert \(url.lastPathComponent) to \(format.title)")
                            return
                        }
                        context.store.importImageData(data, preferredExtension: format.fileExtension, baseName: base)
                    }
                }
            ))
        }

        return actions
    }
}

enum ImageExport {
    enum Format: CaseIterable {
        case png, jpeg, heic

        var title: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            }
        }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            }
        }

        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            }
        }
    }

    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    static func convert(_ url: URL, to format: Format) -> Data? {
        guard let image = loadCGImage(url) else { return nil }
        return encode(image, as: format)
    }

    static func resized(_ url: URL, toWidth width: Int) -> Data? {
        guard let image = loadCGImage(url), width > 0 else { return nil }
        let scale = CGFloat(width) / CGFloat(image.width)
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return encode(scaled, as: .png)
    }

    static func dataURI(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mimeType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
            .preferredMIMEType ?? "application/octet-stream"
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private static func encode(_ image: CGImage, as format: Format) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.utType.identifier as CFString, 1, nil
        ) else { return nil }
        // Ignored by PNG; used by JPEG and HEIC.
        let options = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

enum TextRecognition {
    /// On-device text recognition via Vision. Language correction is off:
    /// it "fixes" identifiers, hashes and file paths, which is exactly the
    /// text you most want out of a screenshot.
    static func recognizeText(in url: URL) -> String? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("ShakeShelf: OCR failed for \(url.lastPathComponent): \(error)")
            return nil
        }
        guard let observations = request.results else { return nil }

        // Vision returns observations in reading order; keep line breaks so
        // terminal output and code stay legible.
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
