import SwiftUI
import AO3Kit

/// The gallery centerpiece: a rich metadata card (not a book cover). Leads with what a
/// reader browses on — title, author, fandoms, tag pills, the stats line, the summary, and
/// the reader's own bookmark tags/notes.
struct WorkCardView: View {
    let item: WorkListItem
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            header
            if !item.fandoms.isEmpty { pillRow(item.fandoms, image: "theatermasks") }
            if !compact {
                let tags = item.relationships + item.characters + item.freeforms
                if !tags.isEmpty { pillRow(Array(tags.prefix(8)), image: "tag") }
            }
            if let line = nonEmpty(item.statsLine) {
                Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !compact, let summary = nonEmpty(item.summary) {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !item.bookmarkTags.isEmpty || nonEmpty(item.bookmarkerNotes) != nil {
                bookmarkerSection
            }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                badges
            }
            Text("by \(item.author)").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var badges: some View {
        HStack(spacing: 6) {
            if let r = item.rating { miniBadge(r, "star.circle") }
            if item.isComplete == true { miniBadge("Complete", "checkmark.seal") }
            else if item.isComplete == false { miniBadge("WIP", "ellipsis.circle") }
            let b = item.kind.badge
            miniBadge(b.label, b.systemImage)
        }
    }

    private func miniBadge(_ text: String, _ image: String) -> some View {
        Label(text, systemImage: image)
            .font(.caption2).foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    private func pillRow(_ values: [String], image: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { ForEach(values, id: \.self) { TagPill(text: $0, systemImage: image) } }
        }
    }

    private var bookmarkerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            if !item.bookmarkTags.isEmpty {
                pillRow(item.bookmarkTags, image: "bookmark")
            }
            if let notes = nonEmpty(item.bookmarkerNotes) {
                Text(notes).font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
