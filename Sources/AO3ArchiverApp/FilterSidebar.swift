import SwiftUI
import AO3Kit

/// The glass filter sidebar: facet sections with live counts, mirroring AO3's bookmark
/// filters. Each multi-value facet row is **tri-state** — click to include (green ✓), again
/// to exclude (red ⊘), once more to clear — so include and exclude live in one list instead
/// of AO3's duplicated filter sets. Completion and download are single-select segmented
/// controls.
///
/// Built on a `ScrollView`, deliberately NOT a `List`: a `List` is NSTableView-backed, and
/// mutating the filter from a row control recomputes the facet rows, which reloads the table
/// mid-event → "reentrant operation in NSTableView delegate". A ScrollView has no such
/// constraint.
struct FilterSidebar: View {
    @Bindable var vm: GalleryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                facetGroup("Bookmark type", rows: vm.typeFacets,
                           state: { vm.typeState(BookmarkKind(rawValue: $0) ?? .work) },
                           cycle: { if let k = BookmarkKind(rawValue: $0) { vm.cycleType(k) } },
                           display: { BookmarkKind(rawValue: $0)?.badge.label ?? $0 })

                facetGroup("Rating", rows: vm.ratingFacets,
                           state: { vm.ratingState($0) }, cycle: { vm.cycleRating($0) })

                segmentedGroup("Completion", selection: $vm.filter.completion,
                               cases: CompletionFilter.allCases, label: completionLabel)

                segmentedGroup("Download", selection: $vm.filter.download,
                               cases: DownloadFilter.allCases, label: { $0.label })

                facetGroup("Fandom", rows: vm.fandomFacets,
                           state: { vm.fandomState($0) }, cycle: { vm.cycleFandom($0) }, limit: 25)
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

    @ViewBuilder
    private func facetGroup(_ title: String, rows: [(name: String, count: Int)],
                            state: @escaping (String) -> FacetState,
                            cycle: @escaping (String) -> Void,
                            display: @escaping (String) -> String = { $0 },
                            limit: Int = .max) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                groupTitle(title)
                ForEach(rows.prefix(limit), id: \.name) { row in
                    Button { cycle(row.name) } label: {
                        HStack(spacing: 8) {
                            stateIcon(state(row.name))
                            Text(display(row.name)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(row.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
        case .any: return "Any"; case .complete: return "Complete"; case .wip: return "In progress"
        }
    }
}
