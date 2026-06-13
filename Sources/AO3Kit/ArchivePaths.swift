import Foundation

/// Stable on-disk naming for archived EPUBs. The work id is the durable key; the title
/// is cosmetic and sanitized so it's safe on the filesystem.
public enum ArchivePaths {
    public static func epubFilename(workID: Int, title: String) -> String {
        "\(workID) - \(sanitize(title)).epub"
    }

    /// Strip path-hostile characters, collapse whitespace, and bound the length so a
    /// pathologically long AO3 title can't blow past filesystem limits.
    public static func sanitize(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = String(title.unicodeScalars.map { illegal.contains($0) ? " " : Character($0) })
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        let bounded = trimmed.count > 120 ? String(trimmed.prefix(120)).trimmingCharacters(in: .whitespaces) : trimmed
        return bounded.isEmpty ? "untitled" : bounded
    }
}
