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
/// Text-only — no icon (tags read cleaner without one).
struct TagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
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

// AO3 corner-symbol colour coding (classification lives in AO3Kit; colours map here).

extension RatingLevel {
    var color: Color {
        switch self {
        case .general:  return .green
        case .teen:     return .yellow
        case .mature:   return .orange
        case .explicit: return .red
        case .notRated: return .gray
        }
    }
    /// Short corner letter (AO3's first square).
    var letter: String {
        switch self {
        case .general: return "G"; case .teen: return "T"; case .mature: return "M"
        case .explicit: return "E"; case .notRated: return "—"
        }
    }
    var label: String {
        switch self {
        case .general: return "General"; case .teen: return "Teen"; case .mature: return "Mature"
        case .explicit: return "Explicit"; case .notRated: return "Not rated"
        }
    }
}

extension WarningLevel {
    /// nil → no badge shown (no warnings apply / unknown).
    var badge: (label: String, systemImage: String, color: Color)? {
        switch self {
        case .none:           return nil
        case .applies:        return ("Warnings", "exclamationmark.triangle.fill", .red)
        case .choseNotToWarn: return ("Not warned", "exclamationmark.questionmark", .yellow)
        case .external:       return ("External", "globe", .blue)
        }
    }
}

/// A small AO3-style colour-coded capsule (tinted fill + border + matching text).
/// `fixedSize` + `lineLimit(1)` keep it a horizontal pill — never let the label wrap into
/// a one-letter-per-line tall column when horizontal space is tight.
struct ColorBadge: View {
    let text: String
    var systemImage: String? = nil
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.22), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
    }
}

// AO3 second-square category colours (relationships / pairings / orientations). F/F red,
// M/M blue, Gen green, F/M a red→blue gradient, Multi a gradient of the category colours.

/// The fill/border tint for a category — a solid colour or a gradient.
func categoryStyle(_ category: String) -> AnyShapeStyle {
    switch category {
    case "Gen":   return AnyShapeStyle(.green)
    case "F/F":   return AnyShapeStyle(.red)
    case "M/M":   return AnyShapeStyle(.blue)
    case "F/M":   return AnyShapeStyle(
        LinearGradient(colors: [.red, .blue], startPoint: .leading, endPoint: .trailing))
    case "Multi": return AnyShapeStyle(
        LinearGradient(colors: [.green, .red, .blue], startPoint: .leading, endPoint: .trailing))
    case "Other": return AnyShapeStyle(.gray)
    default:      return AnyShapeStyle(.secondary)
    }
}

/// Legible text colour for a category badge (gradients use primary text).
func categoryTextColor(_ category: String) -> Color {
    switch category {
    case "Gen": return .green
    case "F/F": return .red
    case "M/M": return .blue
    case "Other": return .gray
    default:    return .primary       // F/M, Multi: gradient fill, neutral text
    }
}

/// A category capsule supporting solid or gradient tint (for F/M and Multi).
struct CategoryBadge: View {
    let category: String

    var body: some View {
        let style = categoryStyle(category)
        Text(category)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(categoryTextColor(category))
            .background(style.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(style, lineWidth: 1))
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
