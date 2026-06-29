import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// Renders a JPEG **cover image** for a work — AO3's EPUB export ships no cover, so the Kindle
/// homescreen has nothing to thumbnail. We draw a clean typographic cover (title, author,
/// fandom, word count) and register it as the EPUB cover so Amazon's converter uses it for the
/// library grid. Pure CoreGraphics/CoreText/ImageIO — no AppKit — so it's safe off the main thread
/// (the send runs in a background `Task`).
public enum KindleCover {
    /// A 2:3 portrait JPEG, or nil if the graphics context can't be built. Dark, high-contrast
    /// (eink renders greyscale), centered serif title with author + fandom + stats beneath.
    public static func renderJPEG(for w: KindleExport.WorkInfo, width: Int = 600, height: Int = 900) -> Data? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let W = CGFloat(width), H = CGFloat(height)

        // Background + a thin inset border for a "book cover" frame.
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.11, 0.11, 0.12, 1]) ?? gray(0.11))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setStrokeColor(CGColor(colorSpace: cs, components: [0.55, 0.55, 0.58, 1]) ?? gray(0.55))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 26, y: 26, width: W - 52, height: H - 52))

        let light = CGColor(colorSpace: cs, components: [0.94, 0.94, 0.95, 1]) ?? gray(0.94)
        let dim = CGColor(colorSpace: cs, components: [0.70, 0.70, 0.74, 1]) ?? gray(0.70)

        // Title font shrinks as the title grows so a long one still fits the width.
        let titleSize: CGFloat = w.title.count > 60 ? 40 : (w.title.count > 30 ? 52 : 64)
        let text = NSMutableAttributedString()
        text.append(block(w.title, font: "Georgia-Bold", size: titleSize, color: light,
                          lineSpacing: 4, spacingAfter: 22))
        text.append(block("by \(w.author)", font: "Georgia-Italic", size: 30, color: dim,
                          spacingAfter: 40))
        if let f = KindleExport.titleSuffix(fandoms: w.fandoms, wordCount: nil, maxFandoms: 2, maxFandomChars: 50)
            .map({ String($0.dropFirst().dropLast()) }) {   // reuse the fandom shortener, drop the ()
            text.append(block(f, font: "Helvetica", size: 30, color: light, spacingAfter: 14))
        }
        if !w.relationships.isEmpty {
            // First 2 ships, parenthetical fandom tags stripped ("Katara/Zuko (Avatar)" → "Katara/Zuko").
            let rels = w.relationships.prefix(2).map { $0.components(separatedBy: " (").first ?? $0 }
                .joined(separator: ", ") + (w.relationships.count > 2 ? "  +" : "")
            text.append(block(rels, font: "Helvetica", size: 28, color: light, spacingAfter: 18))
        }
        var stat: [String] = []
        if let words = KindleExport.abbreviateWords(w.wordCount) { stat.append(words) }
        if let c = w.isComplete { stat.append(c ? "Complete" : "WIP") }
        if !stat.isEmpty {
            text.append(block(stat.joined(separator: "  ·  "), font: "Helvetica", size: 28, color: dim))
        }

        // Vertically center the whole block within the side margins.
        let margin: CGFloat = 60, textWidth = W - margin * 2
        let fs = CTFramesetterCreateWithAttributedString(text)
        let needed = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: text.length), nil,
            CGSize(width: textWidth, height: .greatestFiniteMagnitude), nil)
        let originY = max(40, (H - needed.height) / 2)
        let path = CGPath(rect: CGRect(x: margin, y: originY, width: textWidth, height: needed.height), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: text.length), path, nil)
        CTFrameDraw(frame, ctx)

        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// One centered paragraph with its own font/size/color and trailing spacing.
    private static func block(_ s: String, font: String, size: CGFloat, color: CGColor,
                              lineSpacing: CGFloat = 0, spacingAfter: CGFloat = 0) -> NSAttributedString {
        let ct = CTFontCreateWithName(font as CFString, size, nil)
        var align = CTTextAlignment.center
        var ls = lineSpacing, sa = spacingAfter
        let settings = [
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &align),
            CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: &ls),
            CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: &sa),
        ]
        let para = CTParagraphStyleCreate(settings, settings.count)
        let attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): ct,
            .init(kCTForegroundColorAttributeName as String): color,
            .init(kCTParagraphStyleAttributeName as String): para,
        ]
        return NSAttributedString(string: s + "\n", attributes: attrs)
    }

    private static func gray(_ v: CGFloat) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [v, v, v, 1])
            ?? CGColor(gray: v, alpha: 1)
    }
}
