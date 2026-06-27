// make_icon.swift — run with:  swift tools/make_icon.swift   (macOS, no Xcode project needed)
// Renders a 1024x1024 NamRig app icon to ./icon_1024.png (CoreGraphics + AppKit).
// Opaque (noneSkipLast) → no alpha channel, App-Store-Connect safe. iOS applies the rounded mask itself.
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("ctx") }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r/255, g/255, b/255, a])! }

// 1. Background: diagonal charcoal gradient (matches dark app UI)
let bg = CGGradient(colorsSpace: cs, colors: [rgb(22,23,28), rgb(12,13,16)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
// red glow behind the amp
ctx.saveGState()
let glow = CGGradient(colorsSpace: cs, colors: [rgb(225,52,43,0.55), rgb(225,52,43,0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: S*0.5, y: S*0.46), startRadius: 0,
    endCenter: CGPoint(x: S*0.5, y: S*0.46), endRadius: S*0.55, options: [])
ctx.restoreGState()

// 2. Amp head silhouette
let ampRect = CGRect(x: S*0.16, y: S*0.30, width: S*0.68, height: S*0.40)
let ampPath = CGPath(roundedRect: ampRect, cornerWidth: 56, cornerHeight: 56, transform: nil)
ctx.saveGState(); ctx.addPath(ampPath)
let bezel = CGGradient(colorsSpace: cs, colors: [rgb(58,60,68), rgb(28,29,34)] as CFArray, locations: [0, 1])!
ctx.clip(); ctx.drawLinearGradient(bezel, start: CGPoint(x: 0, y: ampRect.maxY), end: CGPoint(x: 0, y: ampRect.minY), options: [])
ctx.restoreGState()

let faceRect = ampRect.insetBy(dx: 30, dy: 30)
let facePath = CGPath(roundedRect: faceRect, cornerWidth: 40, cornerHeight: 40, transform: nil)
ctx.saveGState(); ctx.addPath(facePath); ctx.clip()
let face = CGGradient(colorsSpace: cs, colors: [rgb(18,19,24), rgb(10,11,14)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(face, start: CGPoint(x: 0, y: faceRect.maxY), end: CGPoint(x: 0, y: faceRect.minY), options: [])
ctx.setStrokeColor(rgb(255,255,255,0.05)); ctx.setLineWidth(2)
var d: CGFloat = -S
while d < S*2 { ctx.move(to: CGPoint(x: d, y: faceRect.minY)); ctx.addLine(to: CGPoint(x: d+faceRect.height, y: faceRect.maxY)); d += 16 }
ctx.strokePath(); ctx.restoreGState()

// 3. Neural waveform (vertices = neurons, faint synapse lines)
let cx0 = faceRect.minX + 26, cx1 = faceRect.maxX - 26
let midY = faceRect.midY
let amps: [CGFloat] = [0.10, 0.55, 0.22, 0.85, 0.40, 0.95, 0.30, 0.60, 0.12]
var nodes: [CGPoint] = []
for (i, a) in amps.enumerated() {
    let t = CGFloat(i) / CGFloat(amps.count - 1)
    let x = cx0 + (cx1 - cx0) * t
    let sign: CGFloat = (i % 2 == 0) ? -1 : 1
    nodes.append(CGPoint(x: x, y: midY + sign * a * (faceRect.height * 0.30)))
}
func strokeWave(width: CGFloat, color: CGColor, blur: Bool) {
    ctx.saveGState()
    if blur { ctx.setShadow(offset: .zero, blur: 26, color: color) }
    let p = CGMutablePath(); p.move(to: nodes[0])
    for i in 1..<nodes.count {
        let prev = nodes[i-1], cur = nodes[i]; let midX = (prev.x + cur.x)/2
        p.addCurve(to: cur, control1: CGPoint(x: midX, y: prev.y), control2: CGPoint(x: midX, y: cur.y))
    }
    ctx.addPath(p); ctx.setStrokeColor(color); ctx.setLineWidth(width)
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath(); ctx.restoreGState()
}
strokeWave(width: 18, color: rgb(255,176,64), blur: true)
strokeWave(width: 11, color: rgb(255,210,140), blur: false)
ctx.saveGState(); ctx.setStrokeColor(rgb(120,200,255,0.30)); ctx.setLineWidth(2.5)
for i in 0..<nodes.count { for j in [i+2, i+3] where j < nodes.count { ctx.move(to: nodes[i]); ctx.addLine(to: nodes[j]) } }
ctx.strokePath(); ctx.restoreGState()
for (i, n) in nodes.enumerated() {
    let r: CGFloat = (i % 2 == 0) ? 13 : 16
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 18, color: rgb(120,200,255,0.9))
    ctx.setFillColor(rgb(150,215,255)); ctx.fillEllipse(in: CGRect(x: n.x-r, y: n.y-r, width: r*2, height: r*2)); ctx.restoreGState()
    ctx.setFillColor(rgb(255,255,255)); ctx.fillEllipse(in: CGRect(x: n.x-r*0.4, y: n.y-r*0.4, width: r*0.8, height: r*0.8))
}

// 4. Green power LED (top-right of bezel)
ctx.saveGState()
let led = CGPoint(x: ampRect.maxX - 46, y: ampRect.maxY - 44)
ctx.setShadow(offset: .zero, blur: 16, color: rgb(60,220,120,0.9))
ctx.setFillColor(rgb(80,230,140)); ctx.fillEllipse(in: CGRect(x: led.x-10, y: led.y-10, width: 20, height: 20))
ctx.restoreGState()

guard let img = ctx.makeImage() else { fatalError("img") }
let rep = NSBitmapImageRep(cgImage: img)
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("icon_1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
