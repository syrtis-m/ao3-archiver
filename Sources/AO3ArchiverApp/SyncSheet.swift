import SwiftUI
import AO3Kit

/// Sync-from-the-GUI sheet: enter your AO3 username + session cookie (stored in the
/// Keychain), run a bounded sync through the tested `SyncEngine`, and watch live progress.
struct SyncSheet: View {
    @Bindable var controller: SyncController
    let store: Store
    let archiveRoot: URL
    let reload: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var cookie = ""
    @AppStorage("syncDownloadEPUBs") private var downloadEPUBs = false
    @AppStorage("syncInterval") private var interval = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sync bookmarks").font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                TextField("AO3 username", text: $username)
                SecureField("_otwarchive_session cookie (optional)", text: $cookie)
                Text("""
                    A cookie unlocks private/restricted works; leave it blank for public \
                    bookmarks. Get it from your browser: DevTools → Application → Cookies → \
                    archiveofourown.org → copy the value of `_otwarchive_session`. It's saved \
                    to your Keychain and only ever sent to AO3.
                    """)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .textFieldStyle(.roundedBorder)
            .disabled(controller.isRunning)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Download EPUB files too (slower)", isOn: $downloadEPUBs)
                Text(downloadEPUBs
                     ? "Builds the bookmark list AND downloads EPUBs."
                     : "Index only — builds the bookmark list in the database (no EPUB files). Faster and gentler on AO3; download works individually from their detail panel, or run a full sync later.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Seconds between requests")
                    Stepper(value: $interval, in: 3...60, step: 1) {
                        Text("\(Int(interval))s").monospacedDigit()
                    }
                    .fixedSize()
                }
                Text("Higher = more polite. If AO3 says “retry later”, raise this and wait a while before retrying.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .disabled(controller.isRunning)

            progress

            if !controller.isRunning, let page = resumePage {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle")
                    Text("Full sync will resume near page \(page).")
                    Button("Start over") { startOver() }.buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if controller.isRunning {
                    Button("Cancel", role: .cancel) { controller.cancel() }
                } else {
                    Button("Quick sync") { startSync(quick: true) }
                        .help("Grab the latest 3 pages of bookmarks (fast catch-up).")
                    Button("Full sync") { startSync(quick: false) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            username = CredentialStore.username ?? ""
            cookie = CredentialStore.cookie ?? ""
            refreshResume()
        }
    }

    @State private var resumePage: Int?

    private func refreshResume() {
        resumePage = (try? store.getMeta(SyncEngine.resumeKey)).flatMap { $0 }
            .flatMap { SyncEngine.pageNumber(inPath: $0) }
    }

    private func startOver() {
        try? store.clearMeta(SyncEngine.resumeKey)
        refreshResume()
    }

    @ViewBuilder
    private var progress: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .done:
            Label(controller.statusLine, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            activityFeed
        case .failed:
            Label(controller.lastError ?? "Sync failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            activityFeed
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
            activityFeed
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                // Index progress — a determinate bar once we know the total page count.
                if let total = controller.totalPages, total > 0 {
                    ProgressView(value: Double(controller.currentPage), total: Double(total)) {
                        Text(controller.statusLine).font(.callout)
                    }
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(controller.statusLine).font(.callout) }
                }
                Text("\(controller.downloaded) saved"
                     + (controller.failed > 0 ? " · \(controller.failed) failed" : ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

                // Rate-limit banner: a backoff is the usual reason a long index looks frozen.
                if let rate = controller.rateLimit {
                    Label(rate, systemImage: "tortoise.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
                activityFeed
            }
        }
    }

    /// Torrent-style live feed of recent events (newest first).
    @ViewBuilder
    private var activityFeed: some View {
        if !controller.activity.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.activity.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    }
                }
            }
            .frame(height: 140)
            .padding(8)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Quick = latest 3 pages, index-only, no resume (fast catch-up for new bookmarks).
    /// Full = the whole account, resumable, with the download toggle.
    private func startSync(quick: Bool) {
        CredentialStore.set(username, account: CredentialStore.usernameAccount)
        CredentialStore.set(cookie, account: CredentialStore.cookieAccount)
        controller.start(store: store,
                         username: username.isEmpty ? nil : username,
                         cookie: cookie.isEmpty ? nil : cookie,
                         archiveRoot: archiveRoot,
                         interval: interval,
                         downloadEPUBs: quick ? false : downloadEPUBs,
                         maxPages: quick ? 3 : 999,
                         resumeIndex: quick ? false : true,
                         reload: reload)
    }
}
