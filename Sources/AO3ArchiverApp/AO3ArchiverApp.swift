import SwiftUI
import AppKit
import AO3Kit

/// Makes a bare SwiftPM executable behave as a proper foreground GUI app. Launched via
/// `swift run` (no .app bundle), the process defaults to an accessory/prohibited activation
/// policy, so it can't become the active app or key window — and keystrokes go to the
/// launching terminal instead of the search field. Promoting to `.regular` and activating
/// fixes keyboard focus. A bundled .app gets this for free.
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Forces the host `NSWindow` to be resizable/zoomable and key (same bare-executable reason
/// as above — the window is otherwise created without `.resizable` and isn't made key).
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.styleMask.insert([.resizable, .miniaturizable])
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.makeKeyAndOrderFront(nil)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// M2 SwiftUI gallery — dark, Liquid Glass, snappy. The views are a thin skin over AO3Kit's
// tested gallery model (load → filter → sort → facets all happen below this line).
//
// Reads the same SQLite DB the CLI sync writes (AO3_ARCHIVE_DIR, default ./archive). This
// is a read-only browser in M2; syncing stays in the `ao3archiver` CLI for now.
@main
struct AO3ArchiverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var vm = GalleryViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(vm: vm)
                .preferredColorScheme(.dark)
                .frame(minWidth: 480, minHeight: 520)
                .background(WindowConfigurator())
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)   // resize freely above the content's minimum

        // Each opened work gets its own independent reader window (resize / fullscreen / many
        // at once), decoupled from the gallery window. Value-based, so distinct works open
        // distinct windows; reopening the same work refocuses its existing one.
        WindowGroup(id: "reader", for: ReaderWindowValue.self) { $value in
            if let value {
                ReaderWindowRoot(value: value)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 380, minHeight: 420)
                    .background(WindowConfigurator())
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 620, height: 940)   // a book-like portrait page, resizable
    }
}

/// Identifies a work to open in its own reader window. `Codable`/`Hashable` for value-based
/// `WindowGroup`. Carries the archive root so the window can open its own `Store` for resume.
struct ReaderWindowValue: Codable, Hashable {
    let workID: Int
    let title: String
    let epubPath: String          // absolute path to the .epub
    let archiveRootPath: String
}

/// Hosts a `ReaderView` in an independent window, opening its own `Store` handle (a second
/// SQLite connection on the same file — fine for tiny, `try?`-guarded resume reads/writes).
struct ReaderWindowRoot: View {
    let value: ReaderWindowValue
    @State private var store: Store?
    @State private var ready = false

    var body: some View {
        Group {
            if ready {
                ReaderView(epubURL: URL(fileURLWithPath: value.epubPath),
                           workID: value.workID, workTitle: value.title, store: store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(value.title)
        .task {
            store = try? Store(path: URL(fileURLWithPath: value.archiveRootPath)
                .appendingPathComponent("archive.sqlite").path)
            ready = true
        }
    }
}

/// Resolves the archive folder, opens the store, and hands a live `Store` to the gallery.
/// Non-sandboxed, so the chosen folder is a plain path persisted in UserDefaults — no
/// security-scoped bookmark needed. `AO3_ARCHIVE_DIR` (dev/CLI) overrides the picker.
struct RootView: View {
    @Bindable var vm: GalleryViewModel
    @AppStorage("archiveFolderPath") private var storedPath = ""

    @State private var store: Store?
    @State private var openError: String?

    private var archiveRoot: URL {
        if let env = ProcessInfo.processInfo.environment["AO3_ARCHIVE_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if !storedPath.isEmpty { return URL(fileURLWithPath: storedPath) }
        // Default to a visible ~/Documents/ao3archive — a backup tool's files belong
        // somewhere the user can actually find, not hidden in ~/Library/Application Support.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("ao3archive")
    }

    var body: some View {
        Group {
            if let store {
                GalleryView(vm: vm, store: store, archiveRoot: archiveRoot, onChooseFolder: chooseFolder)
            } else if let openError {
                ContentUnavailableView {
                    Label("Couldn't open archive", systemImage: "externaldrive.badge.xmark")
                } description: {
                    Text(openError)
                } actions: {
                    Button("Choose Archive Folder…", action: chooseFolder)
                }
            } else {
                ProgressView("Opening archive…")
            }
        }
        .task(id: archiveRoot) { open() }   // re-open when the chosen folder changes
    }

    private func open() {
        do {
            // Create the archive folder first — when double-clicked there's no
            // AO3_ARCHIVE_DIR and the default Application Support path won't exist yet,
            // so SQLite can't create the db file (error 14).
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            let s = try Store(path: archiveRoot.appendingPathComponent("archive.sqlite").path)
            vm.load(from: s)   // populate BEFORE presenting the sidebar list, so the
            store = s          // NSTableView-backed List renders once with data in place
            openError = nil
        } catch {              // (an empty-then-reload cascade triggers a reentrancy warning)
            openError = String(describing: error)
        }
    }

    /// Pick the archive folder (the one containing `archive.sqlite` + `works/`). Stores the
    /// plain path; `.task(id: archiveRoot)` re-opens the store when it changes.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your AO3 Archiver folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            store = nil            // show the spinner while the new folder opens
            storedPath = url.path
        }
    }
}
