import Foundation

/// CSV ⇄ JSON conversion.
///
/// The CSV side follows RFC 4180: quoted fields may contain the delimiter,
/// newlines, and doubled quotes. Hand-rolled splitting on commas gets all
/// three of those wrong, which is why this is a real parser.
enum CSVJSON {
    enum ConversionError: Error, CustomStringConvertible {
        case notJSON
        case notAnArrayOfObjects
        case emptyCSV
        case serializationFailed

        var description: String {
            switch self {
            case .notJSON:
                return "This snippet isn't valid JSON."
            case .notAnArrayOfObjects:
                return "CSV needs a JSON array of objects, like [{\"a\": 1}, {\"a\": 2}]. "
                    + "A single object or an array of plain values has no rows to convert."
            case .emptyCSV:
                return "This snippet has no rows. The first line is used as the column headers."
            case .serializationFailed:
                return "The result couldn't be encoded."
            }
        }
    }

    // MARK: - Delimiter

    static let supportedDelimiters: [Character] = [",", "\t", ";", "|"]

    /// Picks whichever supported delimiter appears most often outside quotes
    /// in the first line — handles the tab- and semicolon-separated files that
    /// spreadsheets in other locales produce.
    static func detectDelimiter(in text: String) -> Character {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var counts: [Character: Int] = [:]
        var inQuotes = false
        for character in firstLine {
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, supportedDelimiters.contains(character) {
                counts[character, default: 0] += 1
            }
        }
        return counts.max { lhs, rhs in
            // Ties resolve to the earlier entry in supportedDelimiters so the
            // result never depends on dictionary ordering.
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let lhsRank = supportedDelimiters.firstIndex(of: lhs.key) ?? .max
            let rhsRank = supportedDelimiters.firstIndex(of: rhs.key) ?? .max
            return lhsRank > rhsRank
        }?.key ?? ","
    }

    // MARK: - CSV parsing

    static func parseCSV(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            // A trailing newline should not produce a phantom empty row.
            if !(row.count == 1 && row[0].isEmpty) {
                rows.append(row)
            }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil

            if inQuotes {
                if character == "\"" {
                    // A doubled quote inside a quoted field is a literal quote.
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }

            switch character {
            case "\"" where field.isEmpty:
                inQuotes = true
            case delimiter:
                endField()
            case "\r\n", "\r", "\n":
                // "\r\n" is a single Character in Swift (one grapheme
                // cluster), so it must be matched explicitly — matching only
                // "\r" and "\n" silently misses every CRLF file, which is
                // what most spreadsheets export.
                endRow()
            default:
                field.append(character)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }

    static func csvField(_ value: String, delimiter: Character) -> String {
        let needsQuoting = value.contains(delimiter)
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - CSV → JSON

    static func csvToJSON(_ text: String) throws -> String {
        let delimiter = detectDelimiter(in: text)
        let rows = parseCSV(text, delimiter: delimiter)
        guard let headers = rows.first, rows.count > 1 else {
            throw ConversionError.emptyCSV
        }

        var objects: [[String: Any]] = []
        for row in rows.dropFirst() {
            var object: [String: Any] = [:]
            for (index, header) in headers.enumerated() {
                let key = header.isEmpty ? "column \(index + 1)" : header
                object[key] = index < row.count ? inferValue(row[index]) : NSNull()
            }
            // Preserve fields beyond the header row rather than dropping them.
            if row.count > headers.count {
                for index in headers.count..<row.count {
                    object["column \(index + 1)"] = inferValue(row[index])
                }
            }
            objects.append(object)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: objects,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let string = String(data: data, encoding: .utf8) else {
            throw ConversionError.serializationFailed
        }
        return string
    }

    /// Only converts values that survive a round trip, so an identifier like
    /// `007` or a version like `1.10` stays the string it was.
    private static func inferValue(_ field: String) -> Any {
        switch field {
        case "true": return true
        case "false": return false
        case "": return NSNull()
        default: break
        }
        if let integer = Int(field), String(integer) == field { return integer }
        if let double = Double(field), String(double) == field { return double }
        return field
    }

    // MARK: - JSON → CSV

    static func jsonToCSV(_ text: String, delimiter: Character = ",") throws -> String {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ConversionError.notJSON
        }
        guard let array = parsed as? [Any], !array.isEmpty else {
            throw ConversionError.notAnArrayOfObjects
        }
        let objects = array.compactMap { $0 as? [String: Any] }
        guard objects.count == array.count else {
            throw ConversionError.notAnArrayOfObjects
        }

        // JSONSerialization does not preserve key order, so sorting is the
        // only deterministic column order available.
        let headers = Array(Set(objects.flatMap(\.keys))).sorted()
        var lines = [headers.map { csvField($0, delimiter: delimiter) }.joined(separator: String(delimiter))]
        for object in objects {
            let cells = headers.map { csvField(stringify(object[$0]), delimiter: delimiter) }
            lines.append(cells.joined(separator: String(delimiter)))
        }
        return lines.joined(separator: "\n")
    }

    private static func stringify(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let number = value as? NSNumber {
            // Bools arrive as NSNumber too and would otherwise print as 0/1.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            if number.doubleValue == number.doubleValue.rounded(),
               abs(number.doubleValue) < 1e15 {
                return String(number.int64Value)
            }
            return number.stringValue
        }
        if let string = value as? String { return string }
        // Nested arrays and objects have no flat representation; keep them as
        // compact JSON rather than losing them.
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return String(describing: value)
    }
}
