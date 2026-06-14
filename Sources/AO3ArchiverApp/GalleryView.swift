import SwiftUI
import AO3Kit

/// Root layout: glass filter sidebar + the metadata-card gallery, with a search/sort
/// toolbar and a trailing inspector for the selected bookmark.
struct GalleryView: View {
    @Bindable var vm: GalleryViewModel
    let archiveRoot: URL

    @State private var selectionID: WorkListItem.ID?
    @State private var compact = false
    @State private var showInspector = false

    private var selectedItem: WorkListItem? {
        // Resolve against the full set so the detail survives filter changes (and so we
        // don't trigger another filter+sort pass just to look up the selection).
        vm.allItems.first { $0.id == selectionID }
    }

    var body: some View {
        NavigationSplitView {
            FilterSidebar(vm: vm)
                .frame(minWidth: 230)
        } detail: {
            gallery
                .navigationTitle("Bookmarks")
                .searchable(text: $vm.filter.searchText, prompt: "Search title, author, tags, notes")
                .toolbar { toolbarContent }
                .inspector(isPresented: $showInspector) {
                    if let item = selectedItem {
                        WorkDetailView(item: item, archiveRoot: archiveRoot)
                            .inspectorColumnWidth(min: 280, ideal: 360, max: 460)
                    } else {
                        ContentUnavailableView("No selection", systemImage: "sidebar.right")
                    }
                }
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if let err = vm.loadError {
            ContentUnavailableView("Couldn't load archive", systemImage: "externaldrive.badge.xmark",
                                   description: Text(err))
        } else if vm.allItems.isEmpty {
            ContentUnavailableView("No bookmarks yet", systemImage: "bookmark",
                                   description: Text("Run a sync to populate the archive."))
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
            Picker("Sort", selection: $vm.sort) {
                ForEach(GallerySort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { compact.toggle() } label: {
                Label("Density", systemImage: compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
        }
    }
}
