import AppKit
import CryptoKit

/// Transforms that turn one snippet into another. Every one of these adds a
/// new tile rather than editing in place, so the original is never lost.
enum TextActions {
    static var all: [ShelfAction] {
        [editAction, qrCodeAction] + transforms.map { transform in
            ShelfAction(
                title: transform.title,
                group: .transform,
                submenu: transform.submenu,
                isEnabled: { item in
                    guard item.kind == .text, let text = item.text else { return false }
                    return transform.appliesTo(text)
                },
                run: { item, context in
                    guard let text = item.text else { return }
                    switch transform.apply(text) {
                    case .success(let output):
                        context.addResultText(output)
                    case .failure(let reason):
                        context.showMessage("Couldn't \(transform.title.lowercased())", reason)
                    }
                }
            )
        }
    }

    private static var editAction: ShelfAction {
        ShelfAction(title: "Edit…", group: .open, kinds: [.text]) { item, context in
            NoteWindowController.presentEditor(for: item, store: context.store)
        }
    }

    /// Turning a URL or a wifi password into a QR code is the fastest way to
    /// get it onto a phone, so this produces an image tile rather than text.
    private static var qrCodeAction: ShelfAction {
        ShelfAction(
            title: "Generate QR Code",
            group: .convert,
            isEnabled: { item in
                guard item.kind == .text, let text = item.text else { return false }
                return !text.isEmpty && text.utf8.count <= QRCode.maxPayloadBytes
            },
            run: { item, context in
                guard let text = item.text else { return }
                context.inBackground({ QRCode.generate(from: text) }) { data in
                    guard let data else {
                        context.showMessage(
                            "Couldn't generate a QR code",
                            "The snippet is too long to encode. QR codes hold about \(QRCode.maxPayloadBytes) bytes."
                        )
                        return
                    }
                    context.store.importImageData(data, preferredExtension: "png", baseName: "QR Code")
                }
            }
        )
    }

    // MARK: - Transform table

    private struct Transform {
        let title: String
        let submenu: String
        var appliesTo: (String) -> Bool = { _ in true }
        let apply: (String) -> TransformOutcome
    }

    private enum TransformOutcome {
        case success(String)
        case failure(String)
    }

    private static var transforms: [Transform] {
        [
            // The Data entries stay visible for every snippet rather than
            // being gated on the content looking right. Hiding them made the
            // feature undiscoverable, and each one explains itself clearly
            // when the input doesn't fit.
            Transform(title: "Format JSON", submenu: "Data", apply: formatJSON),
            Transform(title: "Minify JSON", submenu: "Data", apply: minifyJSON),
            Transform(title: "JSON → CSV", submenu: "Data") { text in
                do {
                    return .success(try CSVJSON.jsonToCSV(text))
                } catch let error as CSVJSON.ConversionError {
                    return .failure(error.description)
                } catch {
                    return .failure(error.localizedDescription)
                }
            },
            Transform(title: "CSV → JSON", submenu: "Data") { text in
                do {
                    return .success(try CSVJSON.csvToJSON(text))
                } catch let error as CSVJSON.ConversionError {
                    return .failure(error.description)
                } catch {
                    return .failure(error.localizedDescription)
                }
            },

            Transform(title: "Base64 Encode", submenu: "Encode") { .success(Data($0.utf8).base64EncodedString()) },
            Transform(title: "Base64 Decode", submenu: "Encode") { text in
                guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let decoded = String(data: data, encoding: .utf8) else {
                    return .failure("This snippet isn't valid Base64 text.")
                }
                return .success(decoded)
            },
            Transform(title: "URL Encode", submenu: "Encode") { text in
                guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                    return .failure("The snippet couldn't be percent-encoded.")
                }
                return .success(encoded)
            },
            Transform(title: "URL Decode", submenu: "Encode") { text in
                guard let decoded = text.removingPercentEncoding else {
                    return .failure("The snippet isn't valid percent-encoded text.")
                }
                return .success(decoded)
            },
            Transform(title: "Decode JWT", submenu: "Encode", appliesTo: looksLikeJWT, apply: decodeJWT),

            Transform(title: "MD5", submenu: "Hash") { text in
                .success(Insecure.MD5.hash(data: Data(text.utf8)).hexString)
            },
            Transform(title: "SHA-1", submenu: "Hash") { text in
                .success(Insecure.SHA1.hash(data: Data(text.utf8)).hexString)
            },
            Transform(title: "SHA-256", submenu: "Hash") { text in
                .success(SHA256.hash(data: Data(text.utf8)).hexString)
            },

            Transform(title: "UPPERCASE", submenu: "Text") { .success($0.uppercased()) },
            Transform(title: "lowercase", submenu: "Text") { .success($0.lowercased()) },
            Transform(title: "Sort Lines", submenu: "Text", appliesTo: isMultiline) { text in
                .success(text.components(separatedBy: .newlines).sorted().joined(separator: "\n"))
            },
            Transform(title: "Remove Duplicate Lines", submenu: "Text", appliesTo: isMultiline) { text in
                var seen = Set<String>()
                let unique = text.components(separatedBy: .newlines).filter { seen.insert($0).inserted }
                return .success(unique.joined(separator: "\n"))
            },
            Transform(title: "Trim Trailing Whitespace", submenu: "Text") { text in
                let trimmed = text.components(separatedBy: .newlines)
                    .map { line -> String in
                        var line = line
                        while let last = line.last, last.isWhitespace { line.removeLast() }
                        return line
                    }
                return .success(trimmed.joined(separator: "\n"))
            },

            Transform(title: "Unix Timestamp → Date", submenu: "Convert", appliesTo: looksLikeTimestamp) { text in
                let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = Double(raw) else {
                    return .failure("This snippet isn't a Unix timestamp.")
                }
                // 13-digit values are milliseconds.
                let seconds = raw.count >= 12 ? value / 1000 : value
                let date = Date(timeIntervalSince1970: seconds)
                let formatter = ISO8601DateFormatter()
                formatter.timeZone = TimeZone(identifier: "UTC")
                let local = DateFormatter()
                local.dateStyle = .full
                local.timeStyle = .medium
                return .success("\(formatter.string(from: date))\n\(local.string(from: date))")
            },
        ]
    }

    // MARK: - Applicability

    private static func looksLikeJWT(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ".")
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty }
    }

    private static func looksLikeTimestamp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (9...13).contains(trimmed.count) && trimmed.allSatisfy(\.isNumber)
    }

    private static func isMultiline(_ text: String) -> Bool {
        text.contains("\n")
    }

    // MARK: - JSON

    private static func formatJSON(_ text: String) -> TransformOutcome {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .failure("This snippet isn't valid JSON.")
        }
        // Keys are sorted because JSONSerialization does not preserve the
        // original order — unsorted output would look shuffled at random.
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let string = String(data: pretty, encoding: .utf8) else {
            return .failure("The JSON couldn't be re-formatted.")
        }
        return .success(string)
    }

    private static func minifyJSON(_ text: String) -> TransformOutcome {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let minified = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let string = String(data: minified, encoding: .utf8) else {
            return .failure("This snippet isn't valid JSON.")
        }
        return .success(string)
    }

    private static func decodeJWT(_ text: String) -> TransformOutcome {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ".")
        guard parts.count == 3 else { return .failure("A JWT needs three dot-separated parts.") }

        func decodeSegment(_ segment: String) -> String? {
            // JWTs use base64url and drop the padding.
            var normalized = segment
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let remainder = normalized.count % 4
            if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
            guard let data = Data(base64Encoded: normalized),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let pretty = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                  ) else { return nil }
            return String(data: pretty, encoding: .utf8)
        }

        guard let header = decodeSegment(parts[0]), let payload = decodeSegment(parts[1]) else {
            return .failure("The header or payload isn't valid base64url-encoded JSON.")
        }
        // The signature stays opaque: verifying it needs the signing key.
        return .success("HEADER\n\(header)\n\nPAYLOAD\n\(payload)\n\nSIGNATURE (not verified)\n\(parts[2])")
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
