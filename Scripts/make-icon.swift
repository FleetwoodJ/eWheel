// Draws the 1024×1024 app icon in Echoro Green: a glassy wheel of eight segments.
// Usage: swift Scripts/make-icon.swift out.png
import AppKit

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Squircle background (macOS icon grid: 824 pt body inside 1024 canvas)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let grad = CGGradient(colorsSpace: space, colors: [rgb(0x2B4E3B), rgb(0x123524), rgb(0x002112)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Wheel: three segments (Convert, Tools, Actions), top one picked — matches the menu-bar icon.
let c = CGPoint(x: 512, y: 512)
let outer: CGFloat = 330, inner: CGFloat = 170, gap: CGFloat = 22
for i in 0..<3 {
    let mid = CGFloat.pi / 2 - 2 * CGFloat.pi / 3 * CGFloat(i)
    let half = CGFloat.pi / 3
    let go = gap / outer, gi = gap / inner
    let p = CGMutablePath()
    p.addArc(center: c, radius: outer, startAngle: mid + half - go, endAngle: mid - half + go, clockwise: true)
    p.addArc(center: c, radius: inner, startAngle: mid - half + gi, endAngle: mid + half - gi, clockwise: false)
    p.closeSubpath()
    if i == 0 {
        // picked segment: mint with a soft glow and a lighter top edge
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xC5ECD2, 0.45))
        ctx.addPath(p); ctx.setFillColor(rgb(0xC5ECD2, 0.96)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.45), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: c.y + outer), end: CGPoint(x: 512, y: c.y + inner), options: [])
        ctx.restoreGState()
    } else {
        // glass segments: translucent mint
        ctx.addPath(p); ctx.setFillColor(rgb(0xC5ECD2, 0.2)); ctx.fillPath()
    }
    ctx.addPath(p)
    ctx.setStrokeColor(rgb(0xFFFFFF, i == 0 ? 0.65 : 0.25))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

// Centre hub
let hub: CGFloat = 66
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xC5ECD2, 0.4))
ctx.setFillColor(rgb(0xC5ECD2))
ctx.fillEllipse(in: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))
ctx.restoreGState()

// Top gloss
ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let gloss = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()
ctx.addPath(bg); ctx.setStrokeColor(rgb(0xC5ECD2, 0.25)); ctx.setLineWidth(4); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
