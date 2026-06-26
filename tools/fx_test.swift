import Foundation

// Verify the new FX blocks (mirrors of Blocks.swift process()). Checks: non-silent, finite,
// and that modulation actually modulates / feedback stays bounded.
let sr: Float = 48000
let N = 48000
func sine(_ f: Float) -> [Float] { (0..<N).map { 0.5 * sinf(2 * Float.pi * f * Float($0) / sr) } }
func rms(_ x: ArraySlice<Float>) -> Float { sqrtf(x.map { $0*$0 }.reduce(0,+) / Float(x.count)) }
func finite(_ x: [Float]) -> Bool { x.allSatisfy { $0.isFinite } }
func peak(_ x: [Float]) -> Float { x.map { abs($0) }.max() ?? 0 }

func boost(_ x: [Float], db: Float) -> [Float] { let g = powf(10, db/20); return x.map { $0 * g } }

func tremolo(_ x: [Float], rate: Float, depth: Float) -> [Float] {
    let inc = 2*Float.pi*rate/sr; var ph: Float = 0; var o = x
    for i in 0..<o.count { o[i] *= 1 - depth*0.5*(1-cosf(ph)); ph += inc; if ph > 2*Float.pi { ph -= 2*Float.pi } }
    return o
}
func modDelay(_ x: [Float], baseMs: Float, capS: Float, rate: Float, depthMs: Float, fb: Float, mix: Float) -> [Float] {
    let cap = Int(sr*capS)+4; var buf = [Float](repeating: 0, count: cap)
    let inc = 2*Float.pi*rate/sr, baseS = baseMs/1000*sr, depthS = depthMs/1000*sr
    var ph: Float = 0, wi = 0; var o = x
    for i in 0..<o.count {
        let dry = x[i]
        let delayS = baseS + depthS*(0.5*(1-cosf(ph)))
        let rd = Float(wi) - delayS
        let r0 = Int(rd.rounded(.down)), frac = rd - rd.rounded(.down)
        let i0 = ((r0 % cap)+cap)%cap, i1 = (i0+1)%cap
        let wet = buf[i0]*(1-frac) + buf[i1]*frac
        buf[wi] = dry + wet*fb
        o[i] = dry*(1-mix) + wet*mix
        wi += 1; if wi >= cap { wi = 0 }
        ph += inc; if ph > 2*Float.pi { ph -= 2*Float.pi }
    }
    return o
}

let g = sine(220)

// Boost +6dB → ~2x
let b = boost(g, db: 6)
print(String(format: "boost     peak=%.3f (expect ~%.3f)  %@", peak(b), peak(g)*2, abs(peak(b)-peak(g)*2) < 0.01 ? "✓" : "✗"))

// Tremolo 5Hz depth .7 → windowed RMS should swing a lot
let tr = tremolo(g, rate: 5, depth: 0.7)
var mn: Float = 9, mx: Float = 0
var s = 0; while s+2400 <= N { let r = rms(tr[s..<s+2400]); mn = min(mn,r); mx = max(mx,r); s += 2400 }
print(String(format: "tremolo   rms swing %.3f→%.3f  finite=%@  %@", mn, mx, finite(tr) ? "Y":"N", (mx-mn) > 0.1 && finite(tr) ? "✓" : "✗"))

// Chorus (no feedback) → wet present, bounded
let ch = modDelay(g, baseMs: 12, capS: 0.06, rate: 0.8, depthMs: 6, fb: 0, mix: 0.5)
let chDiff = zip(ch,g).map { abs($0-$1) }.reduce(0,+)
print(String(format: "chorus    peak=%.3f diffFromDry=%.0f finite=%@  %@", peak(ch), chDiff, finite(ch) ? "Y":"N", chDiff > 1 && peak(ch) < 1.5 && finite(ch) ? "✓" : "✗"))

// Flanger at high feedback (0.9) → must stay FINITE and not explode
let fl = modDelay(g, baseMs: 1, capS: 0.03, rate: 0.4, depthMs: 2, fb: 0.9, mix: 0.5)
print(String(format: "flanger   peak=%.3f finite=%@  %@", peak(fl), finite(fl) ? "Y":"N", finite(fl) && peak(fl) < 20 ? "✓" : "✗"))
