import SwiftUI
import AO3Kit
import AppKit

/// Detail panel for the selected bookmark: full metadata plus actions — open the saved
/// EPUB in Books, reveal it in Finder, and view the work on AO3.
struct WorkDetailView: View {
    let item: WorkListItem
    let store: Store
    /// Absolute path to the archive root, for resolving the relative epub path.
    let archiveRoot: URL
    /// Called after a single-work download so the gallery (and this item) refresh.
    var onChanged: () -> Void = {}

    @State private var seriesMembers: [WorkListItem] = []
    @State private var downloading = false
    @State private var downloadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title2.bold())
                    Text("by \(item.author)").foregroundStyle(.secondary)
                }
                actions
                if let line = nonEmpty(item.statsLine) {
                    Text(line).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                if item.kind == .series, !seriesMembers.isEmpty { seriesSection }
                metaGrid
                if let summary = nonEmpty(item.summary) {
                    labeled("Summary") { Text(summary) }
                }
                if !item.fandoms.isEmpty { labeled("Fandoms") { wrap(item.fandoms) } }
                if !item.relationships.isEmpty { labeled("Relationships") { wrap(item.relationships) } }
                if !item.characters.isEmpty { labeled("Characters") { wrap(item.characters) } }
                if !item.freeforms.isEmpty { labeled("Additional tags") { wrap(item.freeforms) } }
                if !item.bookmarkTags.isEmpty { labeled("Your tags") { wrap(item.bookmarkTags) } }
                if let notes = nonEmpty(item.bookmarkerNotes) {
                    labeled("Your notes") { Text(notes).italic() }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: item.id) {
            seriesMembers = item.kind == .series
                ? ((try? store.fetchSeriesMembers(seriesID: item.itemID)) ?? [])
                : []
        }
    }

    // The works inside a bookmarked series, in series order.
    private var seriesSection: some View {
        labeled("Works in this series") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(seriesMembers.enumerated()), id: \.element.id) { index, work in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(work.title).fontWeight(.medium)
                            if let line = nonEmpty(work.statsLine) {
                                Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        if work.downloadState == "downloaded" {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        // FlowLayout (not HStack) so the buttons wrap to a second line in a narrow inspector
        // instead of overflowing its right edge.
        FlowLayout(spacing: 10) {
            if item.downloadState == "downloaded", let rel = item.epubPath {
                let url = archiveRoot.appendingPathComponent(rel)
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in Books", systemImage: "book") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            } else if item.kind == .work {
                // Download just this work on demand (after indexing builds the list).
                if downloading {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading…") }
                } else {
                    Button { download() } label: { Label("Download EPUB", systemImage: "arrow.down.circle") }
                }
            }
            if let ao3 = item.ao3URL {
                Button { NSWorkspace.shared.open(ao3) } label: { Label("View on AO3", systemImage: "safari") }
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        if let downloadError {
            Label(downloadError, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    /// Fetch this single work's EPUB (using the stored cookie if present), write it, and
    /// mark it downloaded — then refresh so the buttons flip to Open/Reveal.
    private func download() {
        downloading = true; downloadError = nil
        let workID = item.itemID, title = item.title, updatedAt = item.updatedAt
        let root = archiveRoot, store = store
        Task {
            do {
                let client = AO3Client(config: AO3Config(
                    userAgent: "ao3-archiver/0.1 (personal bookmark backup; contact syrtis@sysd.info)",
                    sessionCookie: CredentialStore.cookie))
                let data = try await WorkDownloader(client: client).downloadEPUB(workID: workID)
                let rel = try FileStore(root: root).writeEPUB(data, workID: workID, title: title)
                try store.markDownloaded(workID: workID, epubPath: rel, updatedAt: updatedAt)
                downloading = false
                onChanged()
            } catch {
                downloading = false
                downloadError = String(describing: error)
            }
        }
    }

    private var metaGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            if let r = item.rating { metaRow("Rating", r) }
            if let c = item.category { metaRow("Category", c) }
            if let l = item.language { metaRow("Language", l) }
            if let k = item.kudos { metaRow("Kudos", k.formatted()) }
            if let h = item.hits { metaRow("Hits", h.formatted()) }
            if let bk = item.bookmarkedAt { metaRow("Bookmarked", bk) }
            if let up = item.dateText { metaRow("Updated", up) }
        }
        .font(.callout)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func wrap(_ values: [String]) -> some View {
        // Simple wrapping flow of pills.
        FlowLayout(spacing: 6) { ForEach(values, id: \.self) { TagPill(text: $0) } }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

/// Minimal wrapping layout for tag pills (a thin, dependency-free flow).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    /// A subview's size, clamped to the row width: an item wider than the container (e.g. a
    /// very long relationship tag) is proposed the max width so `lineLimit(1)` truncates it
    /// inside the card instead of overflowing the edge. `sizeThatFits`/`placeSubviews` must
    /// clamp identically or reserved size won't match placement.
    private func fitted(_ view: LayoutSubview, _ maxWidth: CGFloat) -> CGSize {
        let s = view.sizeThatFits(.unspecified)
        guard maxWidth != .infinity, s.width > maxWidth else { return s }
        return view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = fitted(view, maxWidth)
            if x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = fitted(view, bounds.width)
            if x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
