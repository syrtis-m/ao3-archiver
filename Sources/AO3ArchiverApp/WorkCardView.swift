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
            if let line = nonEmpty(item.statsLine) {
                Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let summary = nonEmpty(item.summary) {
                // Show the full summary when comfortable; only clamp in compact density.
                Text(summary).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : nil)
            }
            if !item.bookmarkTags.isEmpty || nonEmpty(item.bookmarkerNotes) != nil {
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
            if item.kind == .series {
                ColorBadge(text: "Series", systemImage: "books.vertical", color: .purple)
            } else {
                ColorBadge(text: item.ratingLevel.letter, color: item.ratingLevel.color)
            }
            ForEach(item.categories, id: \.self) { cat in
                ColorBadge(text: cat, color: categoryColor(cat))
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

    // Tags grouped by type, each on its own line: fandom → relationships → characters → other.
    @ViewBuilder
    private var tagBlocks: some View {
        if !item.fandoms.isEmpty { pillBlock(item.fandoms) }
        if !compact {
            if !item.relationships.isEmpty { pillBlock(item.relationships) }
            if !item.characters.isEmpty { pillBlock(item.characters) }
            if !item.freeforms.isEmpty { pillBlock(item.freeforms) }
        }
    }

    /// Wrapping block of pills, so all tags in a group are visible at once (not a scroll row).
    private func pillBlock(_ values: [String]) -> some View {
        FlowLayout(spacing: 6) { ForEach(values, id: \.self) { TagPill(text: $0) } }
    }

    private var bookmarkerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            if !item.bookmarkTags.isEmpty { pillBlock(item.bookmarkTags) }
            if let notes = nonEmpty(item.bookmarkerNotes) {
                Text(notes).font(.caption).italic().foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
