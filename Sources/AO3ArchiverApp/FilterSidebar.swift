import SwiftUI
import AO3Kit

/// The glass filter sidebar: facet sections with live counts, mirroring AO3's bookmark
/// filters. Every multi-value facet row is **tri-state** — click to include (green ✓), again
/// to exclude (red ⊘), once more to clear — so include and exclude live in one list instead
/// of AO3's duplicated filter sets. Completion and download are single-select segmented
/// controls. High-cardinality dimensions (characters/relationships/tags) get a typeahead.
///
/// Built on a `ScrollView`, deliberately NOT a `List`: a `List` is NSTableView-backed, and
/// mutating the filter from a row control recomputes the facet rows, which reloads the table
/// mid-event → "reentrant operation in NSTableView delegate". A ScrollView has no such
/// constraint.
struct FilterSidebar: View {
    @Bindable var vm: GalleryViewModel

    /// Per-dimension typeahead text (high-cardinality facets only).
    @State private var queries: [FacetDimension: String] = [:]

    /// Sidebar ordering — mirrors AO3's filter column, with the bookmark-specific dims last.
    private let dimensionOrder: [FacetDimension] = [
        .bookmarkType, .rating, .category, .warning,
        .language, .fandom, .relationship, .character, .freeform, .bookmarkTag,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                facetSection(.bookmarkType)
                facetSection(.rating)
                facetSection(.category)
                facetSection(.warning)

                // Single-select segmented controls. Kept to a few short labels so they fit
                // the sidebar without overflowing.
                segmentedGroup("Completion", selection: $vm.filter.completion,
                               cases: CompletionFilter.allCases, label: completionLabel)
                segmentedGroup("Download", selection: $vm.filter.download,
                               cases: [.any, .saved, .notDownloaded], label: { $0.label })

                facetSection(.language)
                facetSection(.fandom)
                facetSection(.relationship)
                facetSection(.character)
                facetSection(.freeform)
                facetSection(.bookmarkTag)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Filters")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(vm.visibleCount) of \(vm.totalCount)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if vm.filter.isActive {
                    Button("Clear", action: vm.clearFilters).buttonStyle(.borderless).font(.caption)
                }
            }
            Text("Click to include · again to exclude")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// One facet dimension: title, an optional typeahead (high-cardinality only), and the
    /// tri-state rows. Typeahead filters the *full* list before the render cap, so a rare
    /// value stays findable instead of being cut by the cap before the search sees it.
    @ViewBuilder
    private func facetSection(_ dim: FacetDimension) -> some View {
        let allRows = vm.facets(for: dim)
        if !allRows.isEmpty {
            let query = (queries[dim] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let filtered = query.isEmpty ? allRows
                : allRows.filter { display(dim, $0.name).lowercased().contains(query) }
            let cap = dim.isHighCardinality ? 30 : Int.max

            VStack(alignment: .leading, spacing: 2) {
                groupTitle(dim.title)

                if dim.isHighCardinality {
                    TextField("Filter \(dim.title.lowercased())…", text: queryBinding(dim))
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .padding(.bottom, 2)
                }

                ForEach(filtered.prefix(cap), id: \.name) { row in
                    Button { vm.cycle(dim, row.name) } label: {
                        HStack(spacing: 8) {
                            stateIcon(vm.state(dim, row.name))
                            Text(display(dim, row.name)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(row.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }

                if filtered.count > cap {
                    Text("+\(filtered.count - cap) more — type to narrow")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
                } else if filtered.isEmpty {
                    Text("No matches").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Human-facing label for a raw facet value (bookmark types use their badge label).
    private func display(_ dim: FacetDimension, _ raw: String) -> String {
        dim == .bookmarkType ? (BookmarkKind(rawValue: raw)?.badge.label ?? raw) : raw
    }

    private func queryBinding(_ dim: FacetDimension) -> Binding<String> {
        Binding(get: { queries[dim] ?? "" }, set: { queries[dim] = $0 })
    }

    private func segmentedGroup<T: Hashable>(_ title: String, selection: Binding<T>,
                                             cases: [T], label: @escaping (T) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            groupTitle(title)
            Picker(title, selection: selection) {
                ForEach(cases, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)   // fill the column; don't force it wider than the viewport
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func stateIcon(_ state: FacetState) -> some View {
        switch state {
        case .neutral: Image(systemName: "square").foregroundStyle(.secondary)
        case .include: Image(systemName: "checkmark.square.fill").foregroundStyle(.green)
        case .exclude: Image(systemName: "minus.square.fill").foregroundStyle(.red)
        }
    }

    private func completionLabel(_ c: CompletionFilter) -> String {
        switch c {
        case .any: return "Any"; case .complete: return "Complete"; case .wip: return "WIP"
        }
    }
}
