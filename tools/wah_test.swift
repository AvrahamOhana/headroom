import Foundation
// Replicate WahBlock's TPT-SVF bandpass to verify the resonant peak sweeps heel→toe.
final class Wah {
    let fs: Float = 48000, loHz: Float = 400, hiHz: Float = 2200, q: Float = 4.0
    var ic1: Float = 0, ic2: Float = 0
    func reset() { ic1 = 0; ic2 = 0 }
    @inline(__always) func bp(_ x: Float, _ g: Float, _ k: Float) -> Float {
        let a1 = 1/(1+g*(g+k)), a2 = g*a1, a3 = g*a2
        let v3 = x - ic2
        let v1 = a1*ic1 + a2*v3
        let v2 = ic2 + a2*ic1 + a3*v3
        ic1 = 2*v1 - ic1; ic2 = 2*v2 - ic2
        return v1
    }
    func gain(at f: Float, pos: Float) -> Float {
        reset()
        let fc = min(loHz * powf(hiHz/loHz, pos), fs*0.45)
        let g = tanf(.pi*fc/fs), k = 1/q
        var inSum: Float = 0, outSum: Float = 0
        for i in 0..<8000 {
            let x = sinf(2 * .pi * f * Float(i) / fs)
            let y = bp(x, g, k)
            if i > 2000 { inSum += x*x; outSum += y*y }
        }
        return sqrtf(outSum / inSum)
    }
}
let w = Wah()
let freqs: [Float] = [150,300,400,600,900,1400,2200,3200,4500]
for pos: Float in [0.0, 0.5, 1.0] {
    var best: Float = 0, bestG: Float = 0, line = "pos \(pos): "
    for f in freqs { let g = w.gain(at: f, pos: pos); line += String(format:"%.0f=%.2f ",f,g); if g>bestG {bestG=g;best=f} }
    print(line); print(String(format:"   → peak ~%.0f Hz (target fc ~%.0f Hz)", best, 400*powf(2200/400,pos)))
}
let g0lo=w.gain(at:400,pos:0), g0hi=w.gain(at:2200,pos:0), g1lo=w.gain(at:400,pos:1), g1hi=w.gain(at:2200,pos:1)
var pass = true
if !(g0lo > g0hi) { print("FAIL heel"); pass=false }
if !(g1hi > g1lo) { print("FAIL toe"); pass=false }
print(pass ? "\nWAH TEST PASSED — resonant peak sweeps heel→toe" : "\nWAH TEST FAILED")
