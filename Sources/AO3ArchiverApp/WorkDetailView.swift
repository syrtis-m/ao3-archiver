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

    @Environment(\.openWindow) private var openWindow
    @State private var seriesMembers: [WorkListItem] = []
    @State private var downloading = false
    @State private var downloadError: String?
    /// In-flight / failure state for the one-button "Send to Kindle" hand-off.
    @State private var sendingToKindle = false
    @State private var kindleError: String?
    /// A fresh session cookie pasted into the retry field when a download fails (likely an
    /// expired cookie). Persisted to the Keychain on retry; cleared on success.
    @State private var cookieInput = ""
    /// True only when the last failure was a genuine auth error (`requiresLogin`) — so the
    /// cookie-paste field shows for that, not for a transient Cloudflare/network blip (which
    /// would wrongly imply a login problem and just needs a plain retry).
    @State private var needsCookie = false
    /// Set when a pasted cookie couldn't be saved to the Keychain (the download still proceeds
    /// with it, but it won't persist) — so the failure isn't silent.
    @State private var keychainWarning: String?

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

    /// Open the in-app reader for a downloaded item (a work, or a series member row) in its
    /// own independent window — open as many as you like, resize/fullscreen each freely.
    private func read(_ work: WorkListItem) {
        guard work.downloadState == "downloaded", let rel = work.epubPath else { return }
        openWindow(id: "reader", value: ReaderWindowValue(
            workID: work.itemID, title: work.title,
            epubPath: archiveRoot.appendingPathComponent(rel).path,
            archiveRootPath: archiveRoot.path))
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
                            Button { read(work) } label: { Label("Read", systemImage: "book.pages") }
                                .buttonStyle(.glass).controlSize(.small)
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
                // Primary action: read in-app. Open-in-Books/Reveal demote to secondary.
                Button { read(item) } label: { Label("Read", systemImage: "book.pages") }
                    .buttonStyle(.glassProminent)
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in Books", systemImage: "book") }
                if sendingToKindle {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…") }
                } else {
                    Button { sendToKindle(rel) } label: { Label("Send to Kindle", systemImage: "paperplane") }
                }
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
            VStack(alignment: .leading, spacing: 8) {
                Label(downloadError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                if item.kind == .work, !downloading {
                    if needsCookie {
                        // A genuine auth failure — let the user paste a fresh cookie and retry in
                        // place (no trip through the sync sheet). Saved to the Keychain, so later
                        // downloads pick it up too.
                        HStack(spacing: 8) {
                            SecureField("Paste a fresh _otwarchive_session cookie", text: $cookieInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { retryWithCookie() }
                            Button("Save & retry") { retryWithCookie() }
                                .disabled(cookieInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .controlSize(.small)
                    } else {
                        // Transient (Cloudflare / network) — not a cookie problem. Just retry.
                        Button { download() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                            .controlSize(.small)
                    }
                }
                if let keychainWarning {
                    Label(keychainWarning, systemImage: "key.slash")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        if let kindleError {
            Label(kindleError, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    /// One-button hand-off: write a temp EPUB copy whose `<dc:title>` carries the fandom +
    /// word-count badge, then open it with Amazon's Send to Kindle Mac app (the user confirms
    /// the device in its window). Title-rewrite keeps useful metadata visible in the Kindle list.
    private func sendToKindle(_ rel: String) {
        sendingToKindle = true; kindleError = nil
        let src = archiveRoot.appendingPathComponent(rel)
        let work = KindleExport.WorkInfo(
            title: item.title, author: item.author, fandoms: item.fandoms,
            relationships: item.relationships, rating: item.rating, warnings: item.warnings,
            category: item.category, wordCount: item.wordCount, chaptersHave: item.chaptersHave,
            chaptersTotal: item.chaptersTotal, isComplete: item.isComplete, updated: item.dateText,
            kudos: item.kudos, hits: item.hits)
        Task {
            do {
                let tagged = try KindleExport.makeKindleEPUB(source: src, work: work)
                guard let app = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: KindleExport.sendToKindleBundleID) else {
                    throw KindleExport.ExportError.rewriteFailed(
                        "Send to Kindle isn't installed (open the app once first).")
                }
                _ = try await NSWorkspace.shared.open(
                    [tagged], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                sendingToKindle = false
            } catch {
                sendingToKindle = false
                kindleError = "Couldn't send to Kindle: \(error)"
            }
        }
    }

    private func retryWithCookie() {
        let trimmed = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        download(newCookie: trimmed)
    }

    /// Fetch this single work's EPUB and mark it downloaded — then refresh so the buttons
    /// flip to Open/Reveal. Pass `newCookie` to retry with a freshly-pasted session cookie:
    /// it's persisted to the Keychain (so every later download uses it too) and used for this
    /// request. With no argument it uses whatever cookie is already stored.
    private func download(newCookie: String? = nil) {
        downloading = true; downloadError = nil
        let typed = newCookie.flatMap(AO3Config.sanitizeCookie)
        if let typed {
            // Persist so later downloads reuse it. If the Keychain write is denied (e.g. an
            // ad-hoc-signed rebuild changed identity), the retry below still uses `typed`, but
            // warn — otherwise the next download silently falls back to the stale stored cookie.
            if !CredentialStore.set(typed, account: CredentialStore.cookieAccount) {
                keychainWarning = "Couldn't save the cookie to the Keychain — this download will "
                    + "use it, but you may have to paste it again next time."
            } else {
                keychainWarning = nil
            }
        }
        let cookie = typed ?? CredentialStore.cookie
        let workID = item.itemID, title = item.title, updatedAt = item.updatedAt
        let root = archiveRoot, store = store
        Task {
            do {
                // Higher retry budget than the default: AO3 behind Cloudflare can flap 525s for
                // several requests in a row, and a single-work download should ride that out
                // (with backoff) rather than give up after a handful of tries.
                let client = AO3Client(config: AO3Config(
                    userAgent: AO3Config.defaultUserAgent(ao3User: CredentialStore.username),
                    sessionCookie: cookie, maxRetries: 8))
                let data = try await WorkDownloader(client: client).downloadEPUB(workID: workID)
                let rel = try FileStore(root: root).writeEPUB(data, workID: workID, title: title)
                try store.markDownloaded(workID: workID, epubPath: rel, updatedAt: updatedAt)
                downloading = false
                cookieInput = ""
                onChanged()
            } catch {
                downloading = false
                downloadError = String(describing: error)
                if case AO3Error.requiresLogin = error { needsCookie = true } else { needsCookie = false }
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
