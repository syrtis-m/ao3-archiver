import SwiftUI
import AO3Kit

// Shared visual language: the Liquid Glass surface, tag pills, and small helpers. Glass
// usage is centralized here so the material can be tuned (or swapped) in one place.

extension View {
    /// A Liquid Glass panel/card surface with a rounded-rectangle shape.
    func glassPanel(cornerRadius: CGFloat = 16) -> some View {
        glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A glass capsule tag pill (fandoms, relationships, characters, your bookmark tags).
struct TagPill: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .glassEffect(in: Capsule())
    }
}

/// A compact "icon: value" stat used in the card's stats row.
struct StatLabel: View {
    let systemImage: String
    let value: String

    var body: some View {
        Label(value, systemImage: systemImage)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

extension BookmarkKind {
    /// Short badge text + SF Symbol for the card header.
    var badge: (label: String, systemImage: String) {
        switch self {
        case .work:     return ("Work", "doc.text")
        case .external: return ("External", "link")
        case .series:   return ("Series", "books.vertical")
        }
    }
}

/// Human-friendly grouping for download state.
extension WorkListItem {
    var downloadBadge: (label: String, systemImage: String, tint: Color)? {
        switch downloadState {
        case "downloaded":  return ("Saved", "checkmark.circle.fill", .green)
        case "pending":     return ("Not downloaded", "arrow.down.circle", .secondary)
        case "failed":      return ("Failed", "exclamationmark.triangle.fill", .orange)
        case "unavailable": return ("Off-site", "link", .secondary)
        case "series":      return nil
        default:            return nil
        }
    }

    /// "12,328 words · 4/? chapters" style summary line.
    var statsLine: String {
        var parts: [String] = []
        if let w = wordCount { parts.append("\(w.formatted()) words") }
        if let h = chaptersHave {
            parts.append("\(h)/\(chaptersTotal.map(String.init) ?? "?") chapters")
        }
        if let n = worksCount { parts.append("\(n) works") }
        return parts.joined(separator: " · ")
    }
}

extension Int {
    /// "1,234" with grouping separators.
    func formatted() -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? String(self)
    }
}
