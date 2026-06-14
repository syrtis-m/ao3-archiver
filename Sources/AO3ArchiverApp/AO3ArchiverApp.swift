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

    private let archiveRoot: URL = {
        // Dev/CLI override wins (so `swift run` shares the CLI's folder). Otherwise default
        // to Application Support — a stable location that works when double-clicked, where
        // the current directory is "/". The folder picker (M4.3) will let the user change it.
        if let dir = ProcessInfo.processInfo.environment["AO3_ARCHIVE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("AO3Archiver/archive")
    }()

    var body: some Scene {
        WindowGroup {
            RootView(vm: vm, archiveRoot: archiveRoot)
                .preferredColorScheme(.dark)
                .frame(minWidth: 760, minHeight: 520)
                .background(WindowConfigurator())
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)   // resize freely above the content's minimum
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
