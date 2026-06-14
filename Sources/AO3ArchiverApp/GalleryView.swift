import SwiftUI
import AppKit
import AO3Kit

/// Root layout: glass filter sidebar + the metadata-card gallery, with a search/sort
/// toolbar and a trailing inspector for the selected bookmark.
struct GalleryView: View {
    @Bindable var vm: GalleryViewModel
    let store: Store
    let archiveRoot: URL
    var onChooseFolder: () -> Void = {}

    @State private var selectionID: WorkListItem.ID?
    @State private var compact = false
    @State private var showInspector = false
    @State private var showSync = false
    @State private var syncController = SyncController()
    // The search field binds to local state and pushes into the model on change. Binding
    // `.searchable` straight into `$vm.filter.searchText` (a nested property of an
    // @Observable) can drop live updates inside a NavigationSplitView on macOS.
    @State private var searchText = ""
    // Debounce typing before it reaches the filter (M6/P1): each keystroke otherwise forces a
    // full recompute. ~200ms collapses a burst of keystrokes into one. Clearing applies at once.
    @State private var searchDebounce: Task<Void, Never>?

    private var selectedItem: WorkListItem? {
        // Resolve against the full set so the detail survives filter changes (and so we
        // don't trigger another filter+sort pass just to look up the selection).
        vm.allItems.first { $0.id == selectionID }
    }

    var body: some View {
        NavigationSplitView {
            FilterSidebar(vm: vm, store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            gallery
                .navigationTitle("Bookmarks")
                .searchable(text: $searchText, prompt: "Search title, author, tags, notes")
                .onChange(of: searchText) { _, newValue in debounceSearch(newValue) }
                .toolbar { toolbarContent }
                .inspector(isPresented: $showInspector) {
                    if let item = selectedItem {
                        WorkDetailView(item: item, store: store, archiveRoot: archiveRoot,
                                       onChanged: { vm.load(from: store) })
                            .inspectorColumnWidth(min: 280, ideal: 360, max: 460)
                    } else {
                        ContentUnavailableView("No selection", systemImage: "sidebar.right")
                    }
                }
                .sheet(isPresented: $showSync) {
                    SyncSheet(controller: syncController, store: store, archiveRoot: archiveRoot,
                              reload: { vm.load(from: store) })
                }
        }
    }

    /// Push the search text into the filter after a short quiet period, so a burst of
    /// keystrokes triggers one recompute, not one per character. An empty query (the user
    /// cleared the field) applies immediately — clearing should feel instant.
    private func debounceSearch(_ newValue: String) {
        searchDebounce?.cancel()
        if newValue.isEmpty { vm.filter.searchText = ""; return }
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            vm.filter.searchText = newValue
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if let err = vm.loadError {
            ContentUnavailableView("Couldn't load archive", systemImage: "externaldrive.badge.xmark",
                                   description: Text(err))
        } else if vm.allItems.isEmpty {
            ContentUnavailableView {
                Label("No bookmarks yet", systemImage: "bookmark")
            } description: {
                Text("Sync from the CLI, or point at an existing archive folder.")
            } actions: {
                Button("Choose Archive Folder…", action: onChooseFolder)
            }
        } else if vm.visibleItems.isEmpty {
            ContentUnavailableView.search
        } else {
            let items = vm.visibleItems   // compute the filtered+sorted set once per render
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(items) { item in
                        WorkCardView(item: item, compact: compact)
                            .overlay {
                                if item.id == selectionID {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                            .contentShape(Rectangle())   // make the whole card clickable
                            .onTapGesture { selectionID = item.id; showInspector = true }
                    }
                }
                .padding(16)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // Menu-style + fixedSize so the control stays a compact pop-up (the default
            // picker chrome stretches and reads as overlapping in a crowded toolbar).
            Picker("Sort", selection: $vm.sort) {
                ForEach(GallerySort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        ToolbarItem(placement: .primaryAction) {
            Button { compact.toggle() } label: {
                Label("Density", systemImage: compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Reveal in Finder") { NSWorkspace.shared.open(archiveRoot) }
                Button("Choose Archive Folder…", action: onChooseFolder)
                Divider()
                Text(archiveRoot.path)
            } label: {
                Label("Archive Folder", systemImage: "folder")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showSync = true } label: {
                Label("Sync", systemImage: syncController.isRunning ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
        }
    }
}
