import Foundation
import GRDB

/// The SQLite metadata store (GRDB). Single source of truth for the UI; the SyncEngine
/// writes into it and the gallery will read from it. EPUB bytes live on disk (see
/// `FileStore`); this holds metadata, archive state, and the FTS index.
///
/// Upserts are **idempotent** and deliberately preserve local archive state (`epub_path`,
/// `download_state`, …) across re-syncs: re-reading a bookmark page must never clobber a
/// file we've already downloaded. "Needs download" is computed by query, not trusted from
/// a stored flag, so it stays correct even if a sync is interrupted.
public final class Store: @unchecked Sendable {
    let dbQueue: DatabaseQueue

    /// Open (creating if needed) the database at `path` and run migrations.
    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory store, for tests.
    public init(inMemory: Bool) throws {
        dbQueue = try DatabaseQueue()
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            // Known limitation (plan-conformant, §5): `id` is the AO3 work id for kind='work'
            // and the external_works id for kind='external'. Those are independent sequences,
            // so a collision would overwrite one with the other — astronomically unlikely
            // given 8-digit ids, accepted for now rather than namespacing the PK.
            try db.execute(sql: """
                CREATE TABLE work (
                  id              INTEGER PRIMARY KEY,
                  kind            TEXT NOT NULL DEFAULT 'work',   -- work | external
                  source_path     TEXT NOT NULL,
                  title           TEXT NOT NULL,
                  author          TEXT NOT NULL,
                  author_url      TEXT,
                  summary         TEXT,
                  rating          TEXT,
                  category        TEXT,
                  language        TEXT,
                  word_count      INTEGER,
                  chapters_have   INTEGER,
                  chapters_total  INTEGER,
                  is_complete     INTEGER,
                  kudos           INTEGER,
                  comments        INTEGER,
                  bookmarks_count INTEGER,
                  hits            INTEGER,
                  date_text       TEXT,
                  updated_at      INTEGER,        -- unix ts from the card; re-download key
                  -- local archive state (preserved across re-sync)
                  epub_path       TEXT,
                  epub_updated_at INTEGER,
                  download_state  TEXT NOT NULL DEFAULT 'pending', -- pending|downloaded|failed|unavailable
                  last_error      TEXT,
                  first_seen_at   TEXT NOT NULL,
                  last_synced_at  TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE tag (
                  id   INTEGER PRIMARY KEY AUTOINCREMENT,
                  type TEXT NOT NULL,   -- fandom|relationship|character|freeform|warning
                  name TEXT NOT NULL,
                  UNIQUE(type, name)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE work_tag (
                  work_id INTEGER NOT NULL REFERENCES work(id) ON DELETE CASCADE,
                  tag_id  INTEGER NOT NULL REFERENCES tag(id),
                  PRIMARY KEY (work_id, tag_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_work_tag_tag ON work_tag(tag_id)")

            try db.execute(sql: """
                CREATE TABLE series (
                  id             INTEGER PRIMARY KEY,
                  title          TEXT NOT NULL,
                  author         TEXT,
                  summary        TEXT,
                  works_count    INTEGER,
                  date_text      TEXT,
                  first_seen_at  TEXT NOT NULL,
                  last_synced_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE series_work (
                  series_id INTEGER NOT NULL REFERENCES series(id) ON DELETE CASCADE,
                  work_id   INTEGER NOT NULL REFERENCES work(id) ON DELETE CASCADE,
                  part      INTEGER,
                  PRIMARY KEY (series_id, work_id)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE bookmark (
                  bookmark_id      INTEGER PRIMARY KEY,   -- AO3 bookmark id
                  item_kind        TEXT NOT NULL,         -- work | series (work covers external)
                  item_id          INTEGER NOT NULL,      -- work.id or series.id
                  bookmarked_at    TEXT,
                  bookmarker_notes TEXT,
                  is_rec           INTEGER NOT NULL DEFAULT 0,
                  is_private       INTEGER NOT NULL DEFAULT 0,
                  first_seen_at    TEXT NOT NULL,
                  last_synced_at   TEXT NOT NULL,
                  UNIQUE(item_kind, item_id)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE bookmark_tag (
                  bookmark_id INTEGER NOT NULL REFERENCES bookmark(bookmark_id) ON DELETE CASCADE,
                  name        TEXT NOT NULL,
                  PRIMARY KEY (bookmark_id, name)
                )
                """)

            // Full-text index over the searchable text. Plain (not external-content) FTS5
            // so we can DELETE-then-INSERT by rowid=work.id on each upsert without triggers.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE work_fts USING fts5(
                  title, author, summary, tags, bookmarker_notes,
                  tokenize='unicode61 remove_diacritics 2'
                )
                """)

            try db.execute(sql: """
                CREATE TABLE sync_run (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  started_at TEXT NOT NULL,
                  finished_at TEXT,
                  pages_scanned INTEGER NOT NULL DEFAULT 0,
                  works_seen INTEGER NOT NULL DEFAULT 0,
                  epubs_downloaded INTEGER NOT NULL DEFAULT 0,
                  status TEXT NOT NULL DEFAULT 'running',
                  message TEXT
                )
                """)
        }
        m.registerMigration("v2-meta") { db in
            // Small key/value store for app state — currently the index resume point.
            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        }
        m.registerMigration("v3-presets") { db in
            // Saved filter presets ("Smart Bookmarks"): name + a JSON-encoded GalleryFilter+sort.
            try db.execute(sql: "CREATE TABLE filter_preset (name TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        }
        return m
    }

    // MARK: - Filter presets (saved "Smart Bookmarks")

    /// Insert or replace a preset by name. The payload is the JSON-encoded `FilterPreset`.
    public func savePreset(_ preset: FilterPreset) throws {
        let json = String(decoding: try JSONEncoder().encode(preset), as: UTF8.self)
        try dbQueue.write {
            try $0.execute(sql: """
                INSERT INTO filter_preset (name, payload) VALUES (?, ?)
                ON CONFLICT(name) DO UPDATE SET payload = excluded.payload
                """, arguments: [preset.name, json])
        }
    }

    /// All saved presets, name-ordered. A preset that fails to decode (schema drift) is
    /// skipped rather than aborting the load.
    public func loadPresets() throws -> [FilterPreset] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM filter_preset ORDER BY name")
                .compactMap { try? JSONDecoder().decode(FilterPreset.self, from: Data($0.utf8)) }
        }
    }

    public func deletePreset(name: String) throws {
        try dbQueue.write { try $0.execute(sql: "DELETE FROM filter_preset WHERE name = ?", arguments: [name]) }
    }

    // MARK: - Meta (key/value app state)

    public func getMeta(_ key: String) throws -> String? {
        try dbQueue.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }
    public func setMeta(_ key: String, _ value: String) throws {
        try dbQueue.write {
            try $0.execute(sql: """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [key, value])
        }
    }
    public func clearMeta(_ key: String) throws {
        try dbQueue.write { try $0.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key]) }
    }

    // MARK: - Upserts (index sync)

    /// Insert or update a work/external card, preserving local archive-state columns.
    /// Refreshes normalized tags and the FTS row.
    public func upsertWork(_ b: WorkBlurb, now: String = Store.nowISO()) throws {
        try dbQueue.write { db in
            try Self.upsertWork(db, b, now: now)
        }
    }

    static func upsertWork(_ db: Database, _ b: WorkBlurb, now: String) throws {
        try db.execute(sql: """
            INSERT INTO work
              (id, kind, source_path, title, author, author_url, summary, rating, category,
               language, word_count, chapters_have, chapters_total, is_complete, kudos,
               comments, bookmarks_count, hits, date_text, updated_at,
               download_state, first_seen_at, last_synced_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,
               CASE WHEN ?='work' THEN 'pending' ELSE 'unavailable' END, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
               kind=excluded.kind, source_path=excluded.source_path, title=excluded.title,
               author=excluded.author, author_url=excluded.author_url, summary=excluded.summary,
               rating=excluded.rating, category=excluded.category, language=excluded.language,
               word_count=excluded.word_count, chapters_have=excluded.chapters_have,
               chapters_total=excluded.chapters_total, is_complete=excluded.is_complete,
               kudos=excluded.kudos, comments=excluded.comments,
               bookmarks_count=excluded.bookmarks_count, hits=excluded.hits,
               date_text=excluded.date_text, updated_at=excluded.updated_at,
               last_synced_at=excluded.last_synced_at
               -- epub_path, epub_updated_at, download_state, last_error are NOT touched here.
            """, arguments: [
                b.workID, b.kind.rawValue, b.sourcePath, b.title, b.author, b.authorURL,
                b.summary, b.rating, b.category, b.language, b.wordCount, b.chaptersHave,
                b.chaptersTotal, b.isComplete.map { $0 ? 1 : 0 }, b.kudos, b.comments,
                b.bookmarksCount, b.hits, b.dateText, b.updatedAt,
                b.kind.rawValue, now, now,
            ])

        try replaceWorkTags(db, workID: b.workID, b)
        try replaceFTS(db, workID: b.workID, b)
    }

    /// Insert or update the bookmark row for a card (only when it carries a bookmark id).
    public func upsertBookmark(_ b: WorkBlurb, itemKind: BookmarkKind, itemID: Int,
                               now: String = Store.nowISO()) throws {
        try dbQueue.write { db in
            try Self.upsertBookmark(db, b, itemKind: itemKind, itemID: itemID, now: now)
        }
    }

    static func upsertBookmark(_ db: Database, _ b: WorkBlurb, itemKind: BookmarkKind,
                               itemID: Int, now: String) throws {
        guard let bid = b.bookmarkID else { return }
        // item_kind is the polymorphic target: a series bookmark → 'series', everything
        // else (work/external) → 'work'.
        let kindStr = itemKind == .series ? "series" : "work"
        // A work/series can be re-bookmarked under a NEW bookmark id (the old bookmark
        // deleted, a fresh one created — common on AO3). That fresh row shares this
        // item's (item_kind,item_id) and trips its UNIQUE constraint, which the
        // ON CONFLICT(bookmark_id) clause below does NOT cover — so drop any stale
        // duplicate (same target, different bookmark id) first. Its bookmark_tag rows
        // cascade away via ON DELETE CASCADE.
        try db.execute(sql: """
            DELETE FROM bookmark WHERE item_kind = ? AND item_id = ? AND bookmark_id <> ?
            """, arguments: [kindStr, itemID, bid])
        try db.execute(sql: """
            INSERT INTO bookmark
              (bookmark_id, item_kind, item_id, bookmarked_at, bookmarker_notes,
               is_rec, is_private, first_seen_at, last_synced_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(bookmark_id) DO UPDATE SET
               item_kind=excluded.item_kind, item_id=excluded.item_id,
               bookmarked_at=excluded.bookmarked_at, bookmarker_notes=excluded.bookmarker_notes,
               is_rec=excluded.is_rec, is_private=excluded.is_private,
               last_synced_at=excluded.last_synced_at
            """, arguments: [
                bid, kindStr, itemID, b.bookmarkedAt, b.bookmarkerNotes,
                b.isRec ? 1 : 0, b.isPrivate ? 1 : 0, now, now,
            ])

        try db.execute(sql: "DELETE FROM bookmark_tag WHERE bookmark_id = ?", arguments: [bid])
        for name in b.bookmarkTags {
            try db.execute(sql: "INSERT OR IGNORE INTO bookmark_tag (bookmark_id, name) VALUES (?, ?)",
                           arguments: [bid, name])
        }
    }

    /// Insert or update a series row (from its bookmark card).
    public func upsertSeries(_ b: WorkBlurb, now: String = Store.nowISO()) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO series (id, title, author, summary, works_count, date_text,
                                    first_seen_at, last_synced_at)
                VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                   title=excluded.title, author=excluded.author, summary=excluded.summary,
                   works_count=excluded.works_count, date_text=excluded.date_text,
                   last_synced_at=excluded.last_synced_at
                """, arguments: [
                    b.workID, b.title, b.author, b.summary, b.worksCount, b.dateText, now, now,
                ])
        }
    }

    /// Link a member work to its series (idempotent).
    public func linkSeriesWork(seriesID: Int, workID: Int, part: Int?) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO series_work (series_id, work_id, part) VALUES (?,?,?)
                """, arguments: [seriesID, workID, part])
        }
    }

    private static func replaceWorkTags(_ db: Database, workID: Int, _ b: WorkBlurb) throws {
        try db.execute(sql: "DELETE FROM work_tag WHERE work_id = ?", arguments: [workID])
        let groups: [(String, [String])] = [
            ("fandom", b.fandoms), ("relationship", b.relationships),
            ("character", b.characters), ("freeform", b.freeforms), ("warning", b.warnings),
        ]
        for (type, names) in groups {
            for name in names where !name.isEmpty {
                try db.execute(sql: "INSERT OR IGNORE INTO tag (type, name) VALUES (?, ?)",
                               arguments: [type, name])
                let tagID = try Int.fetchOne(db,
                    sql: "SELECT id FROM tag WHERE type = ? AND name = ?", arguments: [type, name])
                if let tagID {
                    try db.execute(sql: "INSERT OR IGNORE INTO work_tag (work_id, tag_id) VALUES (?, ?)",
                                   arguments: [workID, tagID])
                }
            }
        }
    }

    private static func replaceFTS(_ db: Database, workID: Int, _ b: WorkBlurb) throws {
        try db.execute(sql: "DELETE FROM work_fts WHERE rowid = ?", arguments: [workID])
        let tags = (b.fandoms + b.relationships + b.characters + b.freeforms
                    + b.warnings + b.bookmarkTags).joined(separator: " ")
        try db.execute(sql: """
            INSERT INTO work_fts (rowid, title, author, summary, tags, bookmarker_notes)
            VALUES (?,?,?,?,?,?)
            """, arguments: [workID, b.title, b.author, b.summary ?? "", tags, b.bookmarkerNotes ?? ""])
    }

    // MARK: - Download queue (content sync)

    public struct PendingWork: Sendable, Equatable {
        public let id: Int
        public let title: String
        public let updatedAt: Int?
    }

    /// Works that still need an EPUB: AO3 works (not external) with no file yet, or whose
    /// `updated_at` is newer than what we last downloaded. Computed purely from *file state*,
    /// never from a stored status flag — so an interrupted sync resumes correctly AND a
    /// previously-failed work is retried on the next run. That retry is the whole point of
    /// the run-anonymously-then-add-a-cookie workflow: a work that threw `.requiresLogin`
    /// without a cookie must re-enter the queue once a cookie is present. (`download_state`
    /// /`last_error` remain as a UI status cache.) In-run spinning is already prevented by
    /// `contentSync` snapshotting this list once, so excluding 'failed' here would only
    /// block the *cross-run* retry we actually want.
    public func worksNeedingDownload(limit: Int? = nil) throws -> [PendingWork] {
        try dbQueue.read { db in
            let lim = limit.map { " LIMIT \($0)" } ?? ""
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, title, updated_at FROM work
                WHERE kind = 'work'
                  AND (epub_path IS NULL
                       OR (updated_at IS NOT NULL
                           AND (epub_updated_at IS NULL OR updated_at > epub_updated_at)))
                ORDER BY id\(lim)
                """)
            return rows.map { PendingWork(id: $0["id"], title: $0["title"], updatedAt: $0["updated_at"]) }
        }
    }

    /// Works we've **already downloaded** whose `updated_at` has since advanced past the
    /// EPUB we hold (a new chapter / revision). The incremental ("Quick") sync re-downloads
    /// exactly these — deliberately narrower than `worksNeedingDownload`, which also includes
    /// the never-downloaded backlog. Keeping the two separate is what lets a Quick sync stay
    /// cheap: it refreshes stale files without dragging the whole un-downloaded library in.
    public func worksNeedingRedownload(limit: Int? = nil) throws -> [PendingWork] {
        try dbQueue.read { db in
            let lim = limit.map { " LIMIT \($0)" } ?? ""
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, title, updated_at FROM work
                WHERE kind = 'work'
                  AND epub_path IS NOT NULL
                  AND updated_at IS NOT NULL
                  AND (epub_updated_at IS NULL OR updated_at > epub_updated_at)
                ORDER BY id\(lim)
                """)
            return rows.map { PendingWork(id: $0["id"], title: $0["title"], updatedAt: $0["updated_at"]) }
        }
    }

    /// Of the given AO3 bookmark ids, the subset already recorded — so the incremental index
    /// can tell which cards on a listing page are new. Empty input → empty set (no query).
    public func knownBookmarkIDs(among ids: [Int]) throws -> Set<Int> {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            let qs = databaseQuestionMarks(count: ids.count)
            let rows = try Int.fetchAll(db,
                sql: "SELECT bookmark_id FROM bookmark WHERE bookmark_id IN (\(qs))",
                arguments: StatementArguments(ids))
            return Set(rows)
        }
    }

    /// IDs of all bookmarked series — the work list for series expansion.
    public func bookmarkedSeriesIDs() throws -> [Int] {
        try dbQueue.read { db in
            try Int.fetchAll(db, sql: "SELECT id FROM series ORDER BY id")
        }
    }

    public func markDownloaded(workID: Int, epubPath: String, updatedAt: Int?,
                               now: String = Store.nowISO()) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE work SET epub_path = ?, epub_updated_at = ?, download_state = 'downloaded',
                    last_error = NULL, last_synced_at = ? WHERE id = ?
                """, arguments: [epubPath, updatedAt, now, workID])
        }
    }

    public func markFailed(workID: Int, error: String, now: String = Store.nowISO()) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE work SET download_state = 'failed', last_error = ?, last_synced_at = ?
                WHERE id = ?
                """, arguments: [error, now, workID])
        }
    }

    // MARK: - sync_run bookkeeping

    public func beginSyncRun(now: String = Store.nowISO()) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO sync_run (started_at) VALUES (?)", arguments: [now])
            return db.lastInsertedRowID
        }
    }

    public func finishSyncRun(id: Int64, pages: Int, worksSeen: Int, downloaded: Int,
                              status: String, message: String?, now: String = Store.nowISO()) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE sync_run SET finished_at = ?, pages_scanned = ?, works_seen = ?,
                    epubs_downloaded = ?, status = ?, message = ? WHERE id = ?
                """, arguments: [now, pages, worksSeen, downloaded, status, message, id])
        }
    }

    // MARK: - Counts (reporting / tests)

    public func count(_ table: String) throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0 }
    }

    /// Full-text search over title/author/summary/tags/notes; returns matching work ids.
    public func searchWorkIDs(_ query: String) throws -> [Int] {
        try dbQueue.read { db in
            try Int.fetchAll(db, sql: "SELECT rowid FROM work_fts WHERE work_fts MATCH ? ORDER BY rank",
                             arguments: [query])
        }
    }

    public static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
