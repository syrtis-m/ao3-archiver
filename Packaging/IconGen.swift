// Renders the app icon with CoreGraphics (headless — no display needed): a dark
// liquid-glass squircle with a gradient, a glossy top highlight, and a frosted bookmark
// glyph. Run via `swift Packaging/IconGen.swift Packaging/icon_1024.png`.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// macOS icon grid: rounded square inset from the canvas edges, with a soft drop shadow.
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = rect.width * 0.225
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: rgba(0, 0, 0, 0.45))
ctx.addPath(squircle); ctx.setFillColor(rgba(0, 0, 0, 1)); ctx.fillPath()
ctx.restoreGState()

// Base gradient: indigo (top) → teal (bottom).
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let base = CGGradient(colorsSpace: space, colors: [
    rgba(0.36, 0.29, 0.64),   // indigo
    rgba(0.16, 0.34, 0.58),   // blue
    rgba(0.13, 0.45, 0.52),   // teal
] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

// Glossy top highlight — the glass sheen.
let gloss = CGGradient(colorsSpace: space, colors: [
    rgba(1, 1, 1, 0.30), rgba(1, 1, 1, 0.0),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: rect.midX, y: rect.maxY),
                       end: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.05), options: [])
ctx.restoreGState()

// Glass edge: a bright inner stroke + a faint outer ring.
ctx.saveGState()
ctx.addPath(squircle); ctx.setStrokeColor(rgba(1, 1, 1, 0.22)); ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

// Frosted bookmark glyph: tall rounded body with a V-notch at the bottom.
func bookmarkPath() -> CGPath {
    let bw: CGFloat = 300, cx = S / 2
    let topY: CGFloat = S / 2 + 230, botY: CGFloat = S / 2 - 250
    let left = cx - bw / 2, right = cx + bw / 2
    let r: CGFloat = 52, notch: CGFloat = 105
    let p = CGMutablePath()
    p.move(to: CGPoint(x: left, y: botY))
    p.addLine(to: CGPoint(x: left, y: topY - r))
    p.addQuadCurve(to: CGPoint(x: left + r, y: topY), control: CGPoint(x: left, y: topY))
    p.addLine(to: CGPoint(x: right - r, y: topY))
    p.addQuadCurve(to: CGPoint(x: right, y: topY - r), control: CGPoint(x: right, y: topY))
    p.addLine(to: CGPoint(x: right, y: botY))
    p.addLine(to: CGPoint(x: cx, y: botY + notch))   // notch peak
    p.closeSubpath()
    return p
}
let mark = bookmarkPath()

// Soft glow beneath the glyph.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 36, color: rgba(0.5, 0.85, 1.0, 0.55))
ctx.addPath(mark); ctx.setFillColor(rgba(1, 1, 1, 1)); ctx.fillPath()
ctx.restoreGState()

// The glyph itself — frosted white with a subtle vertical gradient.
ctx.saveGState()
ctx.addPath(mark); ctx.clip()
let glass = CGGradient(colorsSpace: space, colors: [
    rgba(1, 1, 1, 0.97), rgba(0.85, 0.93, 1.0, 0.9),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(glass, start: CGPoint(x: S / 2, y: S / 2 + 230),
                       end: CGPoint(x: S / 2, y: S / 2 - 250), options: [])
ctx.restoreGState()

// Write PNG.
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { FileHandle.standardError.write(Data("icon render failed\n".utf8)); exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
