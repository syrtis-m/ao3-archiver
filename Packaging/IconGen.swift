// Renders the app icon with CoreGraphics (headless — no display needed). Liquid-glass, not
// skeuomorphic: a luminous glass squircle with a soft specular reflection, and a *translucent*
// glass bookmark that the gradient refracts through, defined by a bright rim-light + specular
// highlight rather than a solid fill. Run: `swift Packaging/IconGen.swift out.png`.
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
func grad(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = rect.width * 0.235
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Subtle contact shadow (glass floating, not an object dropped on a surface).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgba(0, 0, 0, 0.33))
ctx.addPath(squircle); ctx.setFillColor(rgba(0, 0, 0, 1)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()

// Luminous base gradient: violet (top-left) → blue → cyan-teal (bottom-right).
ctx.drawLinearGradient(grad([
    (0,   rgba(0.46, 0.40, 0.82)),
    (0.5, rgba(0.27, 0.45, 0.80)),
    (1,   rgba(0.22, 0.62, 0.70)),
]), start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

// Soft specular reflection — a glass sheen pooling in the upper-left.
let reflection = grad([(0, rgba(1, 1, 1, 0.34)), (1, rgba(1, 1, 1, 0))])
ctx.drawRadialGradient(reflection,
    startCenter: CGPoint(x: rect.minX + rect.width * 0.32, y: rect.maxY - rect.height * 0.18), startRadius: 0,
    endCenter: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.maxY - rect.height * 0.20),
    endRadius: rect.width * 0.62, options: [])
// A faint darkening toward the bottom edge for glass depth.
ctx.drawLinearGradient(grad([(0, rgba(0, 0, 0, 0)), (1, rgba(0.04, 0.06, 0.16, 0.28))]),
    start: CGPoint(x: rect.midX, y: rect.midY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
ctx.restoreGState()

// Bright thin glass rim around the tile.
ctx.saveGState()
ctx.addPath(squircle); ctx.setStrokeColor(rgba(1, 1, 1, 0.30)); ctx.setLineWidth(3); ctx.strokePath()
ctx.restoreGState()

// Bookmark path: tall rounded body with a V-notch.
func bookmarkPath() -> CGPath {
    let bw: CGFloat = 300, cx = S / 2
    let topY: CGFloat = S / 2 + 232, botY: CGFloat = S / 2 - 248
    let left = cx - bw / 2, right = cx + bw / 2
    let r: CGFloat = 54, notch: CGFloat = 104
    let p = CGMutablePath()
    p.move(to: CGPoint(x: left, y: botY))
    p.addLine(to: CGPoint(x: left, y: topY - r))
    p.addQuadCurve(to: CGPoint(x: left + r, y: topY), control: CGPoint(x: left, y: topY))
    p.addLine(to: CGPoint(x: right - r, y: topY))
    p.addQuadCurve(to: CGPoint(x: right, y: topY - r), control: CGPoint(x: right, y: topY))
    p.addLine(to: CGPoint(x: right, y: botY))
    p.addLine(to: CGPoint(x: cx, y: botY + notch))
    p.closeSubpath()
    return p
}
let mark = bookmarkPath()
let markTop = S / 2 + 232, markBot = S / 2 - 248

// Translucent glass body — low alpha so the tile gradient refracts through it; brighter at
// the top where light enters. No opaque fill, no coloured glow (that's the skeuomorphic look).
ctx.saveGState()
ctx.addPath(mark); ctx.clip()
ctx.drawLinearGradient(grad([
    (0,    rgba(1, 1, 1, 0.42)),
    (0.45, rgba(1, 1, 1, 0.16)),
    (1,    rgba(1, 1, 1, 0.10)),
]), start: CGPoint(x: S / 2, y: markTop), end: CGPoint(x: S / 2, y: markBot), options: [])
// A crisp specular streak across the top — light catching the glass edge.
ctx.drawLinearGradient(grad([(0, rgba(1, 1, 1, 0.55)), (1, rgba(1, 1, 1, 0))]),
    start: CGPoint(x: S / 2, y: markTop), end: CGPoint(x: S / 2, y: markTop - 150), options: [])
ctx.restoreGState()

// Bright rim-light defines the glass edge (this carries the shape, not the fill).
ctx.saveGState()
ctx.addPath(mark)
ctx.setStrokeColor(rgba(1, 1, 1, 0.85)); ctx.setLineWidth(7); ctx.setLineJoin(.round); ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { FileHandle.standardError.write(Data("icon render failed\n".utf8)); exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
