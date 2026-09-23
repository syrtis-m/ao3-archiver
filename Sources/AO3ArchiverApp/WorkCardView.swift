import SwiftUI
import AO3Kit

/// The gallery centerpiece: a rich metadata card (not a book cover). Leads with what a
/// reader browses on — title, author, the colour-coded AO3 symbols, tags grouped by type,
/// the stats line, the summary, and the reader's own bookmark tags/notes.
struct WorkCardView: View {
    let item: WorkListItem
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            titleAndAuthor
            badgeRow
            tagBlocks
            if let line = item.statsLine.nonBlank {
                Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let summary = item.summary.nonBlank {
                // Show the full summary when comfortable; only clamp in compact density.
                Text(summary).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : nil)
            }
            if !item.bookmarkTags.isEmpty || item.bookmarkerNotes.nonBlank != nil {
                bookmarkerSection
            }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private var titleAndAuthor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.headline).lineLimit(2)
            Text("by \(item.author)").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // AO3's colour-coded corner symbols, on their own wrapping line so they never compete
    // with the title for width: rating · category(ies) · warnings · completion.
    private var badgeRow: some View {
        FlowLayout(spacing: 6) {
            if let deleted = item.deletedBadgeText {
                ColorBadge(text: deleted, systemImage: "exclamationmark.shield.fill", color: .red)
            }
            if item.removedFromBookmarks {
                ColorBadge(text: "Un-bookmarked", systemImage: "bookmark.slash", color: .gray)
                    .help("You removed this bookmark on AO3; it's kept here because you saved it.")
            }
            if item.kind == .series {
                ColorBadge(text: "Series", systemImage: "books.vertical", color: .purple)
            } else {
                ColorBadge(text: item.ratingLevel.letter, color: item.ratingLevel.color)
            }
            ForEach(item.categories, id: \.self) { cat in
                CategoryBadge(category: cat)
            }
            if let w = item.warningLevel.badge {
                ColorBadge(text: w.label, systemImage: w.systemImage, color: w.color)
            }
            if item.isComplete == true {
                ColorBadge(text: "Complete", systemImage: "checkmark.seal.fill", color: .green)
            } else if item.isComplete == false {
                ColorBadge(text: "WIP", systemImage: "stop.fill", color: .orange)
            }
        }
    }

    // Tags grouped on their own lines: fandom → relationships → everything else (characters
    // + additional tags together).
    @ViewBuilder
    private var tagBlocks: some View {
        if !item.fandoms.isEmpty { pillBlock(item.fandoms) }
        if !compact {
            if !item.relationships.isEmpty { pillBlock(item.relationships) }
            let other = item.characters + item.freeforms
            if !other.isEmpty { pillBlock(other, cap: 15) }   // cap bulk tags to keep cards short
        }
    }

    /// Wrapping block of pills, so all tags in a group are visible at once (not a scroll row).
    /// `cap` limits very long tag lists, appending a "+N more" note.
    private func pillBlock(_ values: [String], cap: Int = .max) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(values.prefix(cap), id: \.self) { TagPill(text: $0) }
            if values.count > cap {
                Text("+\(values.count - cap) more")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var bookmarkerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            if !item.bookmarkTags.isEmpty { pillBlock(item.bookmarkTags) }
            if let notes = item.bookmarkerNotes.nonBlank {
                Text(notes).font(.caption).italic().foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

}
