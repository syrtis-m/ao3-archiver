import Foundation

/// Stable on-disk naming for archived EPUBs. The work id is the durable key; the title
/// is cosmetic and sanitized so it's safe on the filesystem.
public enum ArchivePaths {
    public static func epubFilename(workID: Int, title: String) -> String {
        "\(workID) - \(sanitize(title)).epub"
    }

    /// Room left in a 255-unit filename for the "<id> - " prefix and ".epub" suffix.
    static let maxTitleUTF16 = 200

    /// Strip path-hostile characters, collapse whitespace, and bound the length so a
    /// pathologically long AO3 title can't blow past filesystem limits.
    public static func sanitize(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = String(title.unicodeScalars.map { illegal.contains($0) ? " " : Character($0) })
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Leading dots would make a hidden file (".hack//SIGN" → ".hack SIGN.epub").
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "." }).trimmingCharacters(in: .whitespaces)
        // Bound by characters *and* by UTF-16 length: APFS caps a name at 255 UTF-16 units, and
        // 120 Characters of a combining-mark-heavy title can be 600+ units (ENAMETOOLONG — the
        // EPUB was fetched, the write failed, and the work re-downloaded every sync). Cut on a
        // Character boundary so a grapheme is never split.
        var bounded = String(trimmed.prefix(120))
        while bounded.utf16.count > maxTitleUTF16 { bounded.removeLast() }
        bounded = bounded.trimmingCharacters(in: .whitespaces)
        return bounded.isEmpty ? "untitled" : bounded
    }
}
