// make_mac_icons.swift — run: swift tools/make_mac_icons.swift <icon_1024.png> <AppIcon.appiconset dir>
// macOS icons are drawn by the app (no system mask): render the square art into Apple's rounded-rect
// shape with the standard ~10 % transparent margin, then emit every mac size + a Contents.json that
// keeps the iOS single-size entry.
import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, let src = NSImage(contentsOfFile: args[0])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("usage"); exit(2) }
let dir = URL(fileURLWithPath: args[1])
let cs = CGColorSpaceCreateDeviceRGB()

func render(_ px: Int) -> CGImage {
    let S = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))
    let inset = S * 0.098                                   // Apple's macOS icon grid: ~824/1024 body
    let body = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let radius = body.width * 0.2237                        // macOS squircle-ish corner
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.02, color: CGColor(colorSpace: cs, components: [0, 0, 0, 0.35])!)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(CGColor(colorSpace: cs, components: [0.06, 0.06, 0.07, 1])!); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(src, in: body)
    ctx.restoreGState()
    return ctx.makeImage()!
}

var entries: [[String: String]] = [["filename": "icon_1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]]
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = pt * scale, name = "mac_\(pt)x\(pt)@\(scale)x.png"
    let rep = NSBitmapImageRep(cgImage: render(px))
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    entries.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
}
let json: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: dir.appendingPathComponent("Contents.json"))
print("wrote \(entries.count - 1) mac icons + Contents.json")
