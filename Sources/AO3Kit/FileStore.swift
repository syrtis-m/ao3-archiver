import Foundation

/// Manages the on-disk archive folder: where the SQLite database and the EPUB files live,
/// and how works are laid out and named. The `Store` holds metadata; this owns bytes.
///
/// Layout:
/// ```
/// <root>/
///   archive.sqlite
///   works/<work_id> - <sanitized title>.epub
/// ```
///
/// > **Scope note (M1):** this is plain directory management. The security-scoped folder
/// > **bookmark** that lets a sandboxed app retain access to a user-chosen folder across
/// > launches is an *app-sandbox* concern (entitlements + `NSURL` bookmark data) and is
/// > deferred to M2, where the SwiftUI app picks the folder. A SwiftPM CLI can't hold one.
public struct FileStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `<root>/archive.sqlite`.
    public var databaseURL: URL {
        root.appendingPathComponent("archive.sqlite")
    }

    /// `works/` subfolder (relative paths in the DB are stored against the root).
    public var worksDirectory: URL {
        root.appendingPathComponent("works", isDirectory: true)
    }

    /// Create the archive root and its `works/` subfolder if they don't exist.
    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: worksDirectory, withIntermediateDirectories: true)
    }

    /// The DB-stored relative path for a work's EPUB, e.g. "works/123 - Title.epub".
    public func epubRelativePath(workID: Int, title: String) -> String {
        "works/" + ArchivePaths.epubFilename(workID: workID, title: title)
    }

    /// Resolve a stored relative path against the archive root.
    public func url(forRelativePath relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func fileExists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forRelativePath: relativePath).path)
    }

    /// Write EPUB bytes to the given relative path, creating the parent directory. Returns
    /// the relative path so callers can persist it in the `Store`.
    @discardableResult
    public func writeEPUB(_ data: Data, workID: Int, title: String) throws -> String {
        try ensureDirectories()
        let rel = epubRelativePath(workID: workID, title: title)
        try data.write(to: url(forRelativePath: rel), options: .atomic)
        return rel
    }
}
