// Draws the 1024×1024 eWheel icon ("Glass Wheel"), in the same family as MacCleanser's "Light Stack":
// near-white glass tile with soft Echoro green glows, a frosted three-segment wheel whose picked segment is
// deep Echoro green, and a glass file being dropped onto it. Colours from "Echoro brand colours".
// Usage: swift Scripts/make-icon.swift out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let N = 1024, space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: space, colors: cols as CFArray, locations: locs)! }

// Echoro palette
let green = 0x123524 as UInt32        // Echoro Green
let forest = 0x2F6B57 as UInt32       // Forest
let mint = 0xC5ECD2 as UInt32         // primary container
let sage = 0xA9CFB7 as UInt32         // dark-scheme primary
let surface = 0xF2F4EF as UInt32      // flat surface
let divider = 0xDCE5DC as UInt32      // divider, lighter

// The standard macOS icon tile: 824 pt rounded square inside the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow, as macOS draws app icons
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0x000000, 0.32))
ctx.addPath(tile); ctx.setFillColor(rgb(surface)); ctx.fillPath(); ctx.restoreGState()

// Near-white glass with soft Echoro green glows
ctx.saveGState(); ctx.addPath(tile); ctx.clip()
ctx.drawLinearGradient(grad([rgb(0xFFFFFF), rgb(surface), rgb(divider)], [0, 0.6, 1]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.drawRadialGradient(grad([rgb(sage, 0.85), rgb(sage, 0)], [0, 1]),
                       startCenter: CGPoint(x: 300, y: 300), startRadius: 0, endCenter: CGPoint(x: 300, y: 300), endRadius: 520, options: [])
ctx.drawRadialGradient(grad([rgb(mint, 0.95), rgb(mint, 0)], [0, 1]),
                       startCenter: CGPoint(x: 760, y: 800), startRadius: 0, endCenter: CGPoint(x: 760, y: 800), endRadius: 400, options: [])
ctx.restoreGState()

/// A Liquid Glass shape: translucent fill, soft light from the top, bright edge at the top-left, fine green rim.
func glass(_ path: CGPath, tint: CGColor, shadow: CGFloat = 0.34) {
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: rgb(green, shadow))
    ctx.addPath(path); ctx.setFillColor(tint); ctx.fillPath(); ctx.restoreGState()
    let b = path.boundingBox
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(grad([rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0.05), rgb(0xFFFFFF, 0)], [0, 0.45, 1]),
                           start: CGPoint(x: b.midX, y: b.maxY), end: CGPoint(x: b.midX, y: b.minY), options: [])
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(path); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad([rgb(0xFFFFFF, 0.95), rgb(0xFFFFFF, 0.15), rgb(0xFFFFFF, 0.5)], [0, 0.5, 1]),
                           start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: [])
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(path); ctx.setLineWidth(6); ctx.setStrokeColor(rgb(forest, 0.40)); ctx.strokePath(); ctx.restoreGState()
}

/// Deep Echoro green with a soft white halo: the focal point, like MacCleanser's sparkle.
func deepGreen(_ path: CGPath, halo: Bool = true) {
    let b = path.boundingBox
    if halo {
        ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xFFFFFF, 0.95))
        ctx.addPath(path); ctx.setFillColor(rgb(forest)); ctx.fillPath(); ctx.restoreGState()
    }
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(grad([rgb(forest), rgb(green)], [0, 1]),
                           start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY), options: [])
    // a gentle top sheen so it reads as glass, not flat paint
    ctx.drawLinearGradient(grad([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: b.midX, y: b.maxY), end: CGPoint(x: b.midX, y: b.midY), options: [])
    ctx.restoreGState()
}

// The wheel: three segments round a hub, picked segment at the top
let wc = CGPoint(x: 486, y: 474)
let outer: CGFloat = 268, inner: CGFloat = 110, gap: CGFloat = 15
func segment(_ i: Int) -> CGPath {
    let span = 2 * CGFloat.pi / 3, mid = CGFloat.pi / 2 - span * CGFloat(i)
    let go = gap / outer, gi = gap / inner
    let p = CGMutablePath()
    p.addArc(center: wc, radius: outer, startAngle: mid + span / 2 - go, endAngle: mid - span / 2 + go, clockwise: true)
    p.addArc(center: wc, radius: inner, startAngle: mid - span / 2 + gi, endAngle: mid + span / 2 - gi, clockwise: false)
    p.closeSubpath()
    return p
}
glass(segment(1), tint: rgb(0xFFFFFF, 0.80))
glass(segment(2), tint: rgb(0xFFFFFF, 0.80))
// The picked segment sits slightly forward, like the live wheel's selection
var lift = CGAffineTransform(translationX: wc.x, y: wc.y).scaledBy(x: 1.05, y: 1.05).translatedBy(x: -wc.x, y: -wc.y)
deepGreen(segment(0).copy(using: &lift)!)

// Hub: white glass with a deep green centre
let hubR: CGFloat = 84
glass(CGPath(ellipseIn: CGRect(x: wc.x - hubR, y: wc.y - hubR, width: hubR * 2, height: hubR * 2), transform: nil),
      tint: rgb(0xFFFFFF, 0.95), shadow: 0.25)
let dot: CGFloat = 30
deepGreen(CGPath(ellipseIn: CGRect(x: wc.x - dot, y: wc.y - dot, width: dot * 2, height: dot * 2), transform: nil), halo: false)

// A glass file being dropped onto the picked segment
let fw: CGFloat = 216, fh: CGFloat = 276
let fr = CGRect(x: 612, y: 580, width: fw, height: fh)
var tilt = CGAffineTransform(translationX: fr.midX, y: fr.midY).rotated(by: -14 * .pi / 180).translatedBy(x: -fr.midX, y: -fr.midY)
let file = CGPath(roundedRect: fr, cornerWidth: 40, cornerHeight: 40, transform: &tilt)
glass(file, tint: rgb(0xFFFFFF, 0.96), shadow: 0.42)
ctx.saveGState(); ctx.concatenate(tilt)
for (k, w) in [(0, 132.0), (1, 160.0), (2, 104.0)] {
    let y = fr.midY + 44 - CGFloat(k) * 50
    let l = CGPath(roundedRect: CGRect(x: fr.minX + 38, y: y, width: w, height: 20), cornerWidth: 10, cornerHeight: 10, transform: nil)
    ctx.addPath(l); ctx.setFillColor(rgb(forest, 0.55)); ctx.fillPath()
}
ctx.restoreGState()

// A small four-point sparkle, MacCleanser's family mark
func sparkle(_ p: CGPoint, _ r: CGFloat) {
    let m = CGMutablePath(), k: CGFloat = 0.2
    m.move(to: CGPoint(x: p.x, y: p.y + r))
    m.addQuadCurve(to: CGPoint(x: p.x + r, y: p.y), control: CGPoint(x: p.x + r * k, y: p.y + r * k))
    m.addQuadCurve(to: CGPoint(x: p.x, y: p.y - r), control: CGPoint(x: p.x + r * k, y: p.y - r * k))
    m.addQuadCurve(to: CGPoint(x: p.x - r, y: p.y), control: CGPoint(x: p.x - r * k, y: p.y - r * k))
    m.addQuadCurve(to: CGPoint(x: p.x, y: p.y + r), control: CGPoint(x: p.x - r * k, y: p.y + r * k))
    deepGreen(m, halo: false)
}
sparkle(CGPoint(x: 236, y: 786), 48)

// Faint green edge so the tile keeps its shape on light backgrounds
ctx.saveGState(); ctx.addPath(tile); ctx.setLineWidth(4); ctx.setStrokeColor(rgb(forest, 0.16)); ctx.strokePath(); ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
