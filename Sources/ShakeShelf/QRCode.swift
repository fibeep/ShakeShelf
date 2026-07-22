import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

enum QRCode {
    /// Comfortably inside the ~2.9 KB byte-mode ceiling; past this the
    /// generator returns nothing rather than explaining itself.
    static let maxPayloadBytes = 2000

    static func generate(from text: String, scale: CGFloat = 12) -> Data? {
        let payload = Data(text.utf8)
        guard !payload.isEmpty, payload.count <= maxPayloadBytes else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // The generator emits one pixel per module; scale up with no
        // interpolation so the result stays crisp and scannable.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        // Pad with a quiet zone — scanners need it and a flush-cropped code
        // often fails to read.
        let quietZone = scale * 2
        let size = CGSize(
            width: scaled.extent.width + quietZone * 2,
            height: scaled.extent.height + quietZone * 2
        )
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(
                data: nil,
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        canvas.setFillColor(NSColor.white.cgColor)
        canvas.fill(CGRect(origin: .zero, size: size))
        canvas.interpolationQuality = .none
        canvas.draw(cgImage, in: CGRect(
            x: quietZone, y: quietZone,
            width: scaled.extent.width, height: scaled.extent.height
        ))

        guard let final = canvas.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, final, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Reads any barcodes present in an image — QR codes on a slide, a
    /// wifi code in a screenshot, a shipping barcode.
    static func decode(from url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let request = VNDetectBarcodesRequest()
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            NSLog("ShakeShelf: barcode detection failed: \(error)")
            return []
        }
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }
}
