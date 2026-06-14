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
    let store: Store

    /// Per-dimension typeahead text (high-cardinality facets only).
    @State private var queries: [FacetDimension: String] = [:]
    @State private var newPresetName = ""

    /// Sidebar ordering — mirrors AO3's filter column, with the bookmark-specific dims last.
    private let dimensionOrder: [FacetDimension] = [
        .bookmarkType, .rating, .category, .warning,
        .language, .fandom, .relationship, .character, .freeform, .bookmarkTag,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                presetsSection

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

                bookmarkOptionsSection
                rangesSection

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

    /// Saved presets ("Smart Bookmarks"): apply one, delete it, or save the current filter.
    @ViewBuilder
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            groupTitle("Presets")
            ForEach(vm.presets) { preset in
                HStack(spacing: 6) {
                    Button(preset.name) { vm.applyPreset(preset) }
                        .buttonStyle(.plain).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { vm.deletePreset(preset, from: store) } label: {
                        Image(systemName: "trash").font(.caption2)
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                TextField("Save current as…", text: $newPresetName)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit(saveCurrentPreset)
                Button("Save", action: saveCurrentPreset)
                    .controlSize(.small)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty || !vm.filter.isActive)
            }
        }
    }

    private func saveCurrentPreset() {
        vm.savePreset(named: newPresetName, to: store)
        newPresetName = ""
    }

    /// Bookmark-derived booleans, each a small Any/Yes/No segmented control.
    private var bookmarkOptionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            groupTitle("Bookmark options")
            triRow("Crossover", $vm.filter.crossover, yes: "Only", no: "Hide")
            triRow("Rec'd", $vm.filter.recd, yes: "Only", no: "Hide")
            triRow("Notes", $vm.filter.hasNotes, yes: "With", no: "Without")
            triRow("Private", $vm.filter.isPrivate, yes: "Private", no: "Public")
        }
    }

    private func triRow(_ title: String, _ selection: Binding<TriFilter>,
                        yes: String, no: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 72, alignment: .leading)
            Picker(title, selection: selection) {
                Text("Any").tag(TriFilter.any)
                Text(yes).tag(TriFilter.yes)
                Text(no).tag(TriFilter.no)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
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

    /// Numeric + date range filters (min/max). Empty fields mean "open end"; a value the item
    /// lacks (e.g. a series has no word count) drops out of an active range.
    private var rangesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            groupTitle("Ranges")
            numericRangeRow(.wordCount)
            numericRangeRow(.kudos)
            numericRangeRow(.comments)
            numericRangeRow(.bookmarks)
            numericRangeRow(.hits)
            dateRangeRow(.dateUpdated)
            dateRangeRow(.dateBookmarked)
        }
    }

    private func numericRangeRow(_ field: RangeField) -> some View {
        HStack(spacing: 6) {
            Text(field.title).font(.caption).frame(width: 78, alignment: .leading)
            TextField("min", text: numericBinding(field, \.min)).frame(width: 56)
            Text("–").foregroundStyle(.secondary)
            TextField("max", text: numericBinding(field, \.max)).frame(width: 56)
        }
        .textFieldStyle(.roundedBorder).controlSize(.small)
    }

    /// String binding over one end of a numeric bound — empty string clears that end.
    private func numericBinding(_ field: RangeField,
                                _ end: WritableKeyPath<NumericBound, Double?>) -> Binding<String> {
        Binding(
            get: {
                guard let v = vm.bound(field)[keyPath: end] else { return "" }
                return String(Int(v))
            },
            set: { str in
                var b = vm.bound(field)
                let digits = str.filter(\.isNumber)
                b[keyPath: end] = digits.isEmpty ? nil : Double(digits)
                vm.setBound(field, b)
            })
    }

    private func dateRangeRow(_ field: RangeField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.title).font(.caption)
            HStack(spacing: 8) {
                dateEndPicker(field, \.min, label: "From")
                dateEndPicker(field, \.max, label: "To")
            }
        }
    }

    /// A checkbox that enables one end of a date range, revealing a compact DatePicker.
    /// (Caveat: `bookmarkedDate` is parsed UTC but the picker emits local midnight, so a bound
    /// can be off by the UTC offset at the exact day boundary — cosmetic; comparisons are all
    /// in unix seconds and internally consistent.)
    @ViewBuilder
    private func dateEndPicker(_ field: RangeField,
                              _ end: WritableKeyPath<NumericBound, Double?>, label: String) -> some View {
        let current = vm.bound(field)[keyPath: end]
        HStack(spacing: 4) {
            Toggle(isOn: Binding(
                get: { current != nil },
                set: { on in
                    var b = vm.bound(field)
                    b[keyPath: end] = on ? (current ?? Date().timeIntervalSince1970) : nil
                    vm.setBound(field, b)
                })) { Text(label).font(.caption2) }
                .toggleStyle(.checkbox)
            if let current {
                DatePicker("", selection: Binding(
                    get: { Date(timeIntervalSince1970: current) },
                    set: { d in
                        var b = vm.bound(field)
                        b[keyPath: end] = d.timeIntervalSince1970
                        vm.setBound(field, b)
                    }), displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.compact).controlSize(.small)
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
