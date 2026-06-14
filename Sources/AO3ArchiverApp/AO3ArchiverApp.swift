import SwiftUI
import AO3Kit

// M2 SwiftUI gallery — dark, Liquid Glass, snappy. The views are a thin skin over AO3Kit's
// tested gallery model (load → filter → sort → facets all happen below this line).
//
// Reads the same SQLite DB the CLI sync writes (AO3_ARCHIVE_DIR, default ./archive). This
// is a read-only browser in M2; syncing stays in the `ao3archiver` CLI for now.
@main
struct AO3ArchiverApp: App {
    @State private var vm = GalleryViewModel()

    private let archiveRoot: URL = {
        let dir = ProcessInfo.processInfo.environment["AO3_ARCHIVE_DIR"]
            ?? FileManager.default.currentDirectoryPath + "/archive"
        return URL(fileURLWithPath: dir)
    }()

    var body: some Scene {
        WindowGroup {
            RootView(vm: vm, archiveRoot: archiveRoot)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

/// Opens the store from disk once, then hands a live `Store` + the view model to the gallery.
struct RootView: View {
    @Bindable var vm: GalleryViewModel
    let archiveRoot: URL

    @State private var store: Store?
    @State private var openError: String?

    var body: some View {
        Group {
            if let store {
                GalleryView(vm: vm, store: store, archiveRoot: archiveRoot)
            } else if let openError {
                ContentUnavailableView("Couldn't open archive", systemImage: "externaldrive.badge.xmark",
                                       description: Text(openError))
            } else {
                ProgressView("Opening archive…")
            }
        }
        .task {
            do {
                let s = try Store(path: archiveRoot.appendingPathComponent("archive.sqlite").path)
                vm.load(from: s)   // populate BEFORE presenting the sidebar list, so the
                store = s          // NSTableView-backed List renders once with data in place
            } catch {              // (an empty-then-reload cascade triggers a reentrancy warning)
                openError = String(describing: error)
            }
        }
    }
}
