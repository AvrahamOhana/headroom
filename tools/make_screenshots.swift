// make_screenshots.swift — compose App Store screenshots from phone captures.
//   swift tools/make_screenshots.swift <outDir> <image> "<caption>" [cropTopPx] [<image> "<caption>" [cropTopPx] ...]
// Portrait sources → 1290×2796 (6.9"/6.7" iPhone slot); landscape sources → 2796×1290.
// Each: stage-dark gradient, caption band at the top, the capture scaled to fit with rounded corners + shadow.
import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else { print("usage: make_screenshots <outDir> <image> <caption> [cropTop] ..."); exit(2) }
let outDir = URL(fileURLWithPath: args[0])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let cs = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r/255, g/255, b/255, a])! }

var i = 1, n = 1
while i + 1 < args.count {
    let path = args[i], caption = args[i + 1]
    var crop: CGFloat = 0
    if i + 2 < args.count, let c = Double(args[i + 2]) { crop = CGFloat(c); i += 3 } else { i += 2 }
    guard let src = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("skip \(path)"); continue }
    let cropped = crop > 0 ? src.cropping(to: CGRect(x: 0, y: Int(crop), width: src.width, height: src.height - Int(crop)))! : src
    let landscape = cropped.width > cropped.height
    let W: CGFloat = landscape ? 2796 : 1290, H: CGFloat = landscape ? 1290 : 2796
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

    let bg = CGGradient(colorsSpace: cs, colors: [rgb(34, 36, 42), rgb(10, 11, 14)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    let sheen = CGGradient(colorsSpace: cs, colors: [rgb(140, 255, 190, 0.10), rgb(140, 255, 190, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: W * 0.5, y: H), startRadius: 0, endCenter: CGPoint(x: W * 0.5, y: H), endRadius: W * 0.9, options: [])

    // Caption band.
    let capH: CGFloat = landscape ? 200 : 300
    let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gfx
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: landscape ? 76 : 88, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: para]
    let str = NSAttributedString(string: caption, attributes: attrs)
    let size = str.size()
    str.draw(in: CGRect(x: 60, y: H - capH * 0.5 - size.height * 0.5, width: W - 120, height: size.height + 10))
    NSGraphicsContext.restoreGraphicsState()

    // Image: fit within margins, rounded, shadowed.
    let margin: CGFloat = 90, avail = CGRect(x: margin, y: margin * 0.6, width: W - 2 * margin, height: H - capH - margin * 0.6 - 40)
    let scale = min(avail.width / CGFloat(cropped.width), avail.height / CGFloat(cropped.height))
    let dw = CGFloat(cropped.width) * scale, dh = CGFloat(cropped.height) * scale
    let rect = CGRect(x: avail.midX - dw / 2, y: avail.maxY - dh, width: dw, height: dh)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: rgb(0, 0, 0, 0.7))
    ctx.setFillColor(rgb(20, 21, 25)); ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 48, cornerHeight: 48, transform: nil)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 48, cornerHeight: 48, transform: nil)); ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: rect)
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(255, 255, 255, 0.12)); ctx.setLineWidth(3)
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 47, cornerHeight: 47, transform: nil)); ctx.strokePath()

    let out = outDir.appendingPathComponent(String(format: "%02d_%@_%dx%d.png", n, landscape ? "landscape" : "portrait", Int(W), Int(H)))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
    print("wrote \(out.lastPathComponent)  (\(caption))")
    n += 1
}
