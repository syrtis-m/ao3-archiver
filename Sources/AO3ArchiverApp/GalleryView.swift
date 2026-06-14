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
    @State private var scrolledID: WorkListItem.ID?   // top-most card; preserved across reflows
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

    // Responsive layout, three breakpoints driven by the window width:
    //   • wide   (≥ wideMinWidth): both side panels can be pinned as columns at once.
    //   • medium (narrow..<wide):  ONE column at a time — opening one closes the other (which
    //                              also prevents the three-pane squeeze that clipped content).
    //   • narrow (< narrowMaxWidth): panels are full-screen SHEETS over a full-width gallery, so
    //                              nothing is cramped and the gallery never reflows (no jumping).
    // `showFilters`/`showInspector` are the user's intent; how each renders depends on the
    // breakpoint, so the same toggle works everywhere.
    @State private var showFilters = true
    @State private var availableWidth: CGFloat = 10_000   // assume wide until geometry resolves
                                                          // (else isNarrow flashes a sheet on launch)
    private static let wideMinWidth: CGFloat = 1100
    private static let narrowMaxWidth: CGFloat = 720
    private var isWide: Bool { availableWidth >= Self.wideMinWidth }
    private var isNarrow: Bool { availableWidth < Self.narrowMaxWidth }

    /// Which panel (if any) is showing as a takeover sheet — only when narrow.
    private enum NarrowPanel: Int, Identifiable { case filters, details; var id: Int { rawValue } }
    private var narrowPanel: Binding<NarrowPanel?> {
        Binding(
            get: {
                guard isNarrow else { return nil }
                if showInspector { return .details }
                if showFilters { return .filters }
                return nil
            },
            set: { if $0 == nil { showInspector = false; showFilters = false } })
    }
    /// The filter sidebar is a column only when not narrow (narrow uses the sheet).
    private var filterColumn: Binding<NavigationSplitViewVisibility> {
        Binding(get: { (showFilters && !isNarrow) ? .all : .detailOnly },
                set: { v in if !isNarrow { showFilters = (v != .detailOnly) } })
    }
    /// The detail inspector is a column only when not narrow (narrow uses the sheet).
    private var inspectorColumn: Binding<Bool> {
        Binding(get: { showInspector && !isNarrow }, set: { showInspector = $0 })
    }

    /// Toggle the filter sidebar; below wide, showing it closes the details panel.
    private func toggleFilters() {
        showFilters.toggle()
        if showFilters && !isWide { showInspector = false }
    }

    /// Show the details panel; below wide, close the filter sidebar (one at a time).
    private func presentDetails() {
        showInspector = true
        if !isWide { showFilters = false }
    }

    /// Toggle the details panel (toolbar button).
    private func toggleDetails() {
        if showInspector { showInspector = false } else { presentDetails() }
    }

    private var selectedItem: WorkListItem? {
        // Resolve against the full set so the detail survives filter changes (and so we
        // don't trigger another filter+sort pass just to look up the selection).
        vm.allItems.first { $0.id == selectionID }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: filterColumn) {
            FilterSidebar(vm: vm, store: store)
                .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 360)
                .toolbar(removing: .sidebarToggle)   // replaced by our own Filters toggle
        } detail: {
            gallery
                .navigationTitle("Bookmarks")
                .searchable(text: $searchText, prompt: "Search title, author, tags, notes")
                .onChange(of: searchText) { _, newValue in debounceSearch(newValue) }
                .toolbar { toolbarContent }
                .inspector(isPresented: inspectorColumn) {
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
        // Narrow: panels take over as a sheet rather than splitting the gallery.
        .sheet(item: narrowPanel) { panel in narrowTakeover(panel) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onChange(of: isWide) { _, nowWide in
            // Leaving wide can't show both columns → keep filters, step the details aside.
            if !nowWide, showFilters, showInspector { showInspector = false }
        }
        .onChange(of: isNarrow) { _, nowNarrow in
            // Cross the narrow boundary with a clean slate so a stale intent doesn't auto-open a
            // sheet (entering) or two columns (leaving).
            if nowNarrow { showFilters = false; showInspector = false }
            else { showFilters = true; showInspector = false }
        }
    }

    /// A panel presented full-window over the gallery when the window is narrow.
    @ViewBuilder
    private func narrowTakeover(_ panel: NarrowPanel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(panel == .filters ? "Filters" : "Details").font(.headline)
                Spacer()
                Button("Done") { showFilters = false; showInspector = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            switch panel {
            case .filters:
                FilterSidebar(vm: vm, store: store)
            case .details:
                if let item = selectedItem {
                    WorkDetailView(item: item, store: store, archiveRoot: archiveRoot,
                                   onChanged: { vm.load(from: store) })
                } else {
                    ContentUnavailableView("No selection", systemImage: "sidebar.right")
                }
            }
        }
        .frame(minWidth: 360, idealWidth: 460, minHeight: 480, idealHeight: 680)
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
                            .onTapGesture { selectionID = item.id; presentDetails() }
                    }
                }
                .padding(16)
                .scrollTargetLayout()
            }
            // Pin the scroll to the top-most card so opening/closing a side panel (which reflows
            // the cards at a new width) keeps your place instead of jumping.
            .scrollPosition(id: $scrolledID, anchor: .top)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { toggleFilters() } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
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
            Button { toggleDetails() } label: { Label("Details", systemImage: "sidebar.right") }
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
