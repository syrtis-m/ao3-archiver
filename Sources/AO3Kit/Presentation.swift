import Foundation

// Display decisions that used to be made inline in SwiftUI views. Per the project rule —
// anything with an `if` lives below the SwiftUI line — they're here, headless-testable.

extension Optional where Wrapped == String {
    /// The string, or nil when it's nil / empty / whitespace-only.
    public var nonBlank: String? {
        guard let s = self, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

extension String {
    /// The string, or nil when it's empty / whitespace-only.
    public var nonBlank: String? { Optional(self).nonBlank }
}

extension WorkListItem {
    /// Whether we hold an EPUB for this item — the single test for "can Read / Open / Send to
    /// Kindle". Keyed on the file, not the `download_state` cache: a failed refresh once
    /// flipped that cache to 'failed' and hid the actions while the file was still on disk.
    public var isSaved: Bool { kind != .series && epubPath != nil }

    /// "12,328 words · 4/? chapters" (or "· 7 works" for a series).
    public var statsLine: String {
        var parts: [String] = []
        if let w = wordCount { parts.append("\(w.formatted()) words") }
        if let h = chaptersHave { parts.append("\(h)/\(chaptersTotal.map(String.init) ?? "?") chapters") }
        if let n = worksCount { parts.append("\(n) works") }
        return parts.joined(separator: " · ")
    }

    /// Card badge for a work confirmed deleted on AO3, or nil.
    public var deletedBadgeText: String? {
        guard deletedOnAO3 else { return nil }
        return isSaved ? "Only copy" : "Deleted on AO3"
    }

    /// Detail-view banner sentence for a work confirmed deleted on AO3, or nil.
    public var deletedBannerText: String? {
        guard deletedOnAO3 else { return nil }
        return isSaved
            ? "This work was deleted from AO3 — your saved copy is the only one left."
            : "This work was deleted from AO3 before you could save it."
    }
}

extension CompletionFilter {
    public var label: String {
        switch self {
        case .any: return "Any"; case .complete: return "Complete"; case .wip: return "WIP"
        }
    }
}
