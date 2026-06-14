import SwiftUI
import AO3Kit

/// The glass filter sidebar: facet sections with live counts, mirroring AO3's bookmark
/// filters. Toggling a facet re-derives the visible set in memory (no disk on the hot path).
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
            }

            facetSection("Bookmark type", rows: vm.typeFacets,
                         isOn: { vm.filter.bookmarkTypes.contains(.init(rawValue: $0) ?? .work) },
                         toggle: { if let k = BookmarkKind(rawValue: $0) { vm.toggleType(k) } },
                         display: { BookmarkKind(rawValue: $0)?.badge.label ?? $0 })

            facetSection("Rating", rows: vm.ratingFacets,
                         isOn: { vm.filter.ratings.contains($0) },
                         toggle: { vm.toggleRating($0) })

            completionSection

            facetSection("Download", rows: vm.downloadFacets,
                         isOn: { vm.filter.downloadStates.contains($0) },
                         toggle: { vm.toggleDownloadState($0) },
                         display: { downloadLabel($0) })

            facetSection("Fandom", rows: vm.fandomFacets,
                         isOn: { vm.filter.fandoms.contains($0) },
                         toggle: { vm.toggleFandom($0) },
                         limit: 25)
        }
        .listStyle(.sidebar)
        .navigationTitle("Filters")
    }

    @ViewBuilder
    private func facetSection(_ title: String, rows: [(name: String, count: Int)],
                              isOn: @escaping (String) -> Bool,
                              toggle: @escaping (String) -> Void,
                              display: @escaping (String) -> String = { $0 },
                              limit: Int = .max) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows.prefix(limit), id: \.name) { row in
                    Button { toggle(row.name) } label: {
                        HStack {
                            Image(systemName: isOn(row.name) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isOn(row.name) ? Color.accentColor : .secondary)
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
