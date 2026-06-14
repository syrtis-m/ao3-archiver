import SwiftUI
import AO3Kit

/// The glass filter sidebar: facet sections with live counts, mirroring AO3's bookmark
/// filters. Each facet row is **tri-state** — click to include (green ✓), click again to
/// exclude (red ⊘), once more to clear — so include and exclude live in one list instead of
/// AO3's duplicated "include" / "exclude" filter sets. Toggling re-derives the visible set
/// in memory (no disk on the hot path).
struct FilterSidebar: View {
    @Bindable var vm: GalleryViewModel

    var body: some View {
        List {
            Section {
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

            facetSection("Bookmark type", rows: vm.typeFacets,
                         state: { vm.typeState(BookmarkKind(rawValue: $0) ?? .work) },
                         cycle: { if let k = BookmarkKind(rawValue: $0) { vm.cycleType(k) } },
                         display: { BookmarkKind(rawValue: $0)?.badge.label ?? $0 })

            facetSection("Rating", rows: vm.ratingFacets,
                         state: { vm.ratingState($0) }, cycle: { vm.cycleRating($0) })

            completionSection

            facetSection("Download", rows: vm.downloadFacets,
                         state: { vm.downloadState($0) }, cycle: { vm.cycleDownloadState($0) },
                         display: { downloadLabel($0) })

            facetSection("Fandom", rows: vm.fandomFacets,
                         state: { vm.fandomState($0) }, cycle: { vm.cycleFandom($0) },
                         limit: 25)
        }
        .listStyle(.sidebar)
        .navigationTitle("Filters")
    }

    @ViewBuilder
    private func facetSection(_ title: String, rows: [(name: String, count: Int)],
                              state: @escaping (String) -> FacetState,
                              cycle: @escaping (String) -> Void,
                              display: @escaping (String) -> String = { $0 },
                              limit: Int = .max) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows.prefix(limit), id: \.name) { row in
                    Button { cycle(row.name) } label: {
                        HStack {
                            stateIcon(state(row.name))
                            Text(display(row.name)).lineLimit(1)
                            Spacer()
                            Text("\(row.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: FacetState) -> some View {
        switch state {
        case .neutral: Image(systemName: "square").foregroundStyle(.secondary)
        case .include: Image(systemName: "checkmark.square.fill").foregroundStyle(.green)
        case .exclude: Image(systemName: "minus.square.fill").foregroundStyle(.red)
        }
    }

    private var completionSection: some View {
        Section("Completion") {
            Picker("Completion", selection: $vm.filter.completion) {
                Text("Any").tag(CompletionFilter.any)
                Text("Complete").tag(CompletionFilter.complete)
                Text("In progress").tag(CompletionFilter.wip)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func downloadLabel(_ state: String) -> String {
        switch state {
        case "downloaded":  return "Saved"
        case "pending":     return "Not downloaded"
        case "failed":      return "Failed"
        case "unavailable": return "Off-site"
        case "series":      return "Series"
        default:            return state.capitalized
        }
    }
}
