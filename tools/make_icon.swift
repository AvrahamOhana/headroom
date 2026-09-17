// make_icon.swift — run with:  swift tools/make_icon.swift   (macOS, no Xcode project needed)
// Renders the 1024x1024 Headroom app icon to ./icon_1024.png: a VU meter whose needle sits high
// in the green just below the red — "headroom". Opaque (noneSkipLast) → no alpha channel, App Store
// Connect safe. iOS applies the rounded mask itself, so the composition keeps clear of the corners.
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("ctx") }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r/255, g/255, b/255, a])! }
let phosphor = rgb(140, 255, 190), phosphorDim = rgb(140, 255, 190, 0.35)
let red = rgb(255, 70, 60)

// 1. Charcoal panel with a top light + faint brushed texture.
let bg = CGGradient(colorsSpace: cs, colors: [rgb(38, 40, 46), rgb(14, 15, 18)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
ctx.saveGState()
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(255, 255, 255, 0.07), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: S * 0.5, y: S * 0.95), startRadius: 0, endCenter: CGPoint(x: S * 0.5, y: S * 0.95), endRadius: S * 0.9, options: [])
ctx.setStrokeColor(rgb(255, 255, 255, 0.025)); ctx.setLineWidth(2)
var y: CGFloat = 0
while y < S { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: S, y: y)); y += 6 }
ctx.strokePath(); ctx.restoreGState()

// 2. Meter geometry: pivot low-center, arc sweeping 140° across the upper half.
let pivot = CGPoint(x: S * 0.5, y: S * 0.31)
let R: CGFloat = S * 0.45
let a0: CGFloat = 160 * .pi / 180, a1: CGFloat = 20 * .pi / 180      // left → right (CG angles, y-up)
func pt(_ ang: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: pivot.x + cos(ang) * r, y: pivot.y + sin(ang) * r) }
func lerp(_ t: CGFloat) -> CGFloat { a0 + (a1 - a0) * t }

// Glow window behind the arc (the meter face).
ctx.saveGState()
let face = CGGradient(colorsSpace: cs, colors: [rgb(140, 255, 190, 0.10), rgb(140, 255, 190, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(face, startCenter: pivot, startRadius: 0, endCenter: pivot, endRadius: R * 1.1, options: [])
ctx.restoreGState()

// 3. Scale arc: green portion (0…82 %) then red (82…100 %).
func arc(from t0: CGFloat, to t1: CGFloat, r: CGFloat, width: CGFloat, color: CGColor, glow: CGFloat = 0) {
    ctx.saveGState()
    if glow > 0 { ctx.setShadow(offset: .zero, blur: glow, color: color) }
    ctx.addArc(center: pivot, radius: r, startAngle: lerp(t0), endAngle: lerp(t1), clockwise: true)
    ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineCap(.butt); ctx.strokePath()
    ctx.restoreGState()
}
arc(from: 0, to: 0.82, r: R, width: 30, color: phosphor, glow: 30)
arc(from: 0.83, to: 1.0, r: R, width: 30, color: red, glow: 30)

// Tick marks (major every 20 %, minor every 5 %).
for i in 0...20 {
    let t = CGFloat(i) / 20, major = i % 4 == 0
    let inner = pt(lerp(t), R - (major ? 92 : 62)), outer = pt(lerp(t), R - 36)
    ctx.setStrokeColor(t > 0.82 ? red : (major ? phosphor : phosphorDim))
    ctx.setLineWidth(major ? 12 : 6); ctx.setLineCap(.round)
    ctx.move(to: inner); ctx.addLine(to: outer); ctx.strokePath()
}

// 4. Needle: pointing at 78 % — high, with headroom to spare before the red.
let needleT: CGFloat = 0.78
let tip = pt(lerp(needleT), R - 44)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: rgb(0, 0, 0, 0.7))
ctx.setStrokeColor(rgb(250, 250, 252)); ctx.setLineWidth(20); ctx.setLineCap(.round)
ctx.move(to: pivot); ctx.addLine(to: tip); ctx.strokePath()
ctx.restoreGState()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 24, color: rgb(255, 255, 255, 0.55))
ctx.setStrokeColor(rgb(255, 255, 255)); ctx.setLineWidth(8); ctx.setLineCap(.round)
ctx.move(to: pivot); ctx.addLine(to: tip); ctx.strokePath()
ctx.restoreGState()

// Pivot cap: metallic dome.
let capR: CGFloat = 84
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: rgb(0, 0, 0, 0.8))
ctx.setFillColor(rgb(30, 31, 36)); ctx.fillEllipse(in: CGRect(x: pivot.x - capR, y: pivot.y - capR, width: capR * 2, height: capR * 2))
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: pivot.x - capR, y: pivot.y - capR, width: capR * 2, height: capR * 2)); ctx.clip()
let dome = CGGradient(colorsSpace: cs, colors: [rgb(110, 114, 124), rgb(28, 29, 34)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(dome, start: CGPoint(x: 0, y: pivot.y + capR), end: CGPoint(x: 0, y: pivot.y - capR), options: [])
ctx.restoreGState()
ctx.setStrokeColor(rgb(255, 255, 255, 0.35)); ctx.setLineWidth(3)
ctx.strokeEllipse(in: CGRect(x: pivot.x - capR + 2, y: pivot.y - capR + 2, width: capR * 2 - 4, height: capR * 2 - 4))
ctx.setFillColor(phosphor); ctx.fillEllipse(in: CGRect(x: pivot.x - 14, y: pivot.y - 14, width: 28, height: 28))

// 5. Power LED, bottom-right, and "dB" glyph bottom-left — small, quiet.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 22, color: rgb(140, 255, 190, 0.9))
ctx.setFillColor(phosphor); ctx.fillEllipse(in: CGRect(x: S * 0.83, y: S * 0.13, width: 30, height: 30))
ctx.restoreGState()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 74, weight: .heavy), .foregroundColor: NSColor(cgColor: rgb(255, 255, 255, 0.28))!]
let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gfx
NSAttributedString(string: "dB", attributes: attrs).draw(at: CGPoint(x: S * 0.135, y: S * 0.115))
NSGraphicsContext.restoreGraphicsState()

guard let img = ctx.makeImage() else { fatalError("img") }
let rep = NSBitmapImageRep(cgImage: img)
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("icon_1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
