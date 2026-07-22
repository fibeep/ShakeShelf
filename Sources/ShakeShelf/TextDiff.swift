import Foundation

/// Line-based diff between two snippets, rendered in the familiar
/// `-` / `+` / space form.
///
/// Uses the standard library's `CollectionDifference` (Myers' algorithm)
/// rather than a hand-rolled LCS.
enum TextDiff {
    struct Result {
        let text: String
        let added: Int
        let removed: Int

        var isIdentical: Bool { added == 0 && removed == 0 }
    }

    static func diff(old: String, new: String, oldLabel: String, newLabel: String) -> Result {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        let difference = newLines.difference(from: oldLines)

        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let element, _): removals[offset] = element
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }

        var body: [String] = []
        var oldIndex = 0
        var newIndex = 0
        // Removal offsets index the original collection and insertion offsets
        // the final one, so advancing each index only when its own change is
        // consumed reconstructs the merged sequence.
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if let removed = removals[oldIndex] {
                body.append("- \(removed)")
                oldIndex += 1
            } else if let inserted = insertions[newIndex] {
                body.append("+ \(inserted)")
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                body.append("  \(oldLines[oldIndex])")
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < oldLines.count {
                body.append("  \(oldLines[oldIndex])")
                oldIndex += 1
            } else {
                body.append("  \(newLines[newIndex])")
                newIndex += 1
            }
        }

        let header = [
            "--- \(oldLabel)",
            "+++ \(newLabel)",
            "",
        ]
        return Result(
            text: (header + body).joined(separator: "\n"),
            added: insertions.count,
            removed: removals.count
        )
    }
}
