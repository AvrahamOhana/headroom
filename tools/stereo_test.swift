//
//  stereo_test.swift
//  Headless verification of the Tier-1 stereo DSP in StereoFX.swift.
//
//  Replicates each block's process math (copied from StereoFX.swift — these tools build standalone,
//  they do NOT import the app target) and checks the load-bearing properties:
//    (a) PingPongDelay — impulse → echoes ALTERNATE L,R,L,R and DECAY (no blow-up), finite.
//    (b) StereoReverb  — noise → L/R DEcorrelated (normalized cross-corr < 0.7), both non-silent,
//        finite over a multi-second tail.
//    (c) equalPowerPan — center = (0.707, 0.707), hard left ≈ (1, 0), hard right ≈ (0, 1).
//
//  Run:  swift tools/stereo_test.swift
//

import Foundation
import Accelerate

let sr: Float = 48000

// ---- helpers -------------------------------------------------------------------------------
func finite(_ x: [Float]) -> Bool { x.allSatisfy { $0.isFinite } }
func peak(_ x: [Float]) -> Float { x.map { abs($0) }.max() ?? 0 }
func rms(_ x: [Float]) -> Float { x.isEmpty ? 0 : sqrtf(x.map { $0 * $0 }.reduce(0, +) / Float(x.count)) }
func energy(_ x: ArraySlice<Float>) -> Float { x.map { $0 * $0 }.reduce(0, +) }

/// Pearson (zero-mean, zero-lag) normalized cross-correlation between two equal-length signals.
func normCrossCorr(_ a: [Float], _ b: [Float]) -> Float {
    let n = min(a.count, b.count); guard n > 0 else { return 0 }
    let ma = a.prefix(n).reduce(0, +) / Float(n), mb = b.prefix(n).reduce(0, +) / Float(n)
    var num: Float = 0, da: Float = 0, db: Float = 0
    for i in 0..<n { let x = a[i] - ma, y = b[i] - mb; num += x * y; da += x * x; db += y * y }
    let den = sqrtf(da * db)
    return den > 1e-20 ? num / den : 0
}

// ============================================================================================
//  equalPowerPan — copied from StereoFX.swift
// ============================================================================================
func equalPowerPan(_ pan: Float) -> (l: Float, r: Float) {
    let p = min(max(pan, -1), 1)
    let theta = (p + 1) * (Float.pi / 4)
    return (cosf(theta), sinf(theta))
}

// ============================================================================================
//  PingPongDelay math — mirrors StereoFX.swift processStereo
// ============================================================================================
func pingPong(_ inMono: [Float], timeMs: Float, feedbackPct: Float, mixPct: Float, spreadPct: Float)
    -> (l: [Float], r: [Float]) {
    let n = inMono.count
    let cap = Int(sr * 2) + 2
    var L = [Float](repeating: 0, count: cap)
    var R = [Float](repeating: 0, count: cap)
    var outL = [Float](repeating: 0, count: n)
    var outR = [Float](repeating: 0, count: n)
    let d = min(max(1, Int(timeMs / 1000 * sr)), cap - 1)
    let fb = min(max(feedbackPct * 0.01, 0), 0.99)
    let mix = max(mixPct * 0.01, 0)
    let s = min(max(spreadPct * 0.01, 0), 1)
    let selfFb = fb * (1 - s), crossFb = fb * s
    var wi = 0
    for i in 0..<n {
        let ri = wi - d, rIdx = ri >= 0 ? ri : ri + cap
        let echoL = L[rIdx], echoR = R[rIdx]
        let x = inMono[i]
        L[wi] = x + echoL * selfFb + echoR * crossFb
        R[wi] = x * (1 - s) + echoR * selfFb + echoL * crossFb
        outL[i] = echoL * mix
        outR[i] = echoR * mix
        wi += 1; if wi >= cap { wi = 0 }
    }
    return (outL, outR)
}

// ============================================================================================
//  StereoReverb math — mirrors StereoFX.swift processStereo
// ============================================================================================
func stereoReverb(_ inMono: [Float], decayPct: Float, dampPct: Float, mixPct: Float, widthPct: Float)
    -> (l: [Float], r: [Float]) {
    let combBase = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    let apBase = [556, 441, 341, 225]
    let stereoSpread = 23
    let inputGain: Float = 0.015
    let eps: Float = 1e-18
    let scale = sr / 44100
    func mk(_ t: Int) -> [Float] { [Float](repeating: 0, count: max(1, Int(Float(t) * scale))) }

    var combL = combBase.map { mk($0) }, combR = combBase.map { mk($0 + stereoSpread) }
    var apL = apBase.map { mk($0) }, apR = apBase.map { mk($0 + stereoSpread) }
    var ciL = [Int](repeating: 0, count: combL.count), ciR = ciL
    var csL = [Float](repeating: 0, count: combL.count), csR = csL
    var aiL = [Int](repeating: 0, count: apL.count), aiR = aiL

    let fb = 0.7 + min(max(decayPct * 0.01, 0), 1) * 0.28
    let d1 = min(max(dampPct * 0.01, 0), 1) * 0.4, d2 = 1 - d1
    let mix = max(mixPct * 0.01, 0)
    let width = min(max(widthPct * 0.01, 0), 1)
    let wet1 = width * 0.5 + 0.5, wet2 = (1 - width) * 0.5
    let nC = combL.count, nA = apL.count

    let n = inMono.count
    var outL = [Float](repeating: 0, count: n), outR = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let input = inMono[i] * inputGain
        var oL: Float = 0, oR: Float = 0
        for c in 0..<nC {
            let lenL = combL[c].count
            let yL = combL[c][ciL[c]]
            var stL = yL * d2 + csL[c] * d1; if abs(stL) < eps { stL = 0 }
            csL[c] = stL
            combL[c][ciL[c]] = input + stL * fb
            ciL[c] += 1; if ciL[c] >= lenL { ciL[c] = 0 }
            oL += yL

            let lenR = combR[c].count
            let yR = combR[c][ciR[c]]
            var stR = yR * d2 + csR[c] * d1; if abs(stR) < eps { stR = 0 }
            csR[c] = stR
            combR[c][ciR[c]] = input + stR * fb
            ciR[c] += 1; if ciR[c] >= lenR { ciR[c] = 0 }
            oR += yR
        }
        for a in 0..<nA {
            let lenL = apL[a].count
            let bL = apL[a][aiL[a]]
            let yL = -oL + bL
            var wL = oL + bL * 0.5; if abs(wL) < eps { wL = 0 }
            apL[a][aiL[a]] = wL
            aiL[a] += 1; if aiL[a] >= lenL { aiL[a] = 0 }
            oL = yL

            let lenR = apR[a].count
            let bR = apR[a][aiR[a]]
            let yR = -oR + bR
            var wR = oR + bR * 0.5; if abs(wR) < eps { wR = 0 }
            apR[a][aiR[a]] = wR
            aiR[a] += 1; if aiR[a] >= lenR { aiR[a] = 0 }
            oR = yR
        }
        outL[i] = (oL * wet1 + oR * wet2) * mix
        outR[i] = (oR * wet1 + oL * wet2) * mix
    }
    return (outL, outR)
}

// ============================================================================================
//  TESTS
// ============================================================================================
var pass = true
func check(_ name: String, _ ok: Bool) { print("  \(ok ? "✓" : "✗") \(name)"); if !ok { pass = false } }

print("== PingPongDelay: impulse → alternating L/R echoes that decay ==")
do {
    let timeMs: Float = 100              // 4800-sample echo spacing — clearly separated
    let d = Int(timeMs / 1000 * sr)
    let fb: Float = 0.6
    let nEch = 6
    var imp = [Float](repeating: 0, count: d * (nEch + 1))
    imp[0] = 1
    let (l, r) = pingPong(imp, timeMs: timeMs, feedbackPct: fb * 100, mixPct: 100, spreadPct: 100)

    // Energy of each channel inside the window centered on echo k (k=1 → L, 2 → R, 3 → L, …).
    var eL = [Float](), eR = [Float]()
    for k in 1...nEch {
        let lo = k * d - 4, hi = min(k * d + 4, l.count)
        eL.append(energy(l[lo..<hi])); eR.append(energy(r[lo..<hi]))
    }
    print("  echo k:   " + (1...nEch).map { String(format: "%6d", $0) }.joined())
    print("  L energy: " + eL.map { String(format: "%6.3f", $0) }.joined())
    print("  R energy: " + eR.map { String(format: "%6.3f", $0) }.joined())

    var alternates = true
    for k in 0..<nEch {
        if (k % 2 == 0) { if !(eL[k] > eR[k] * 100 + 1e-9) { alternates = false } }   // odd echo → L
        else            { if !(eR[k] > eL[k] * 100 + 1e-9) { alternates = false } }   // even echo → R
    }
    // Each successive same-channel echo must be quieter (decay ≈ fb^2 per hop on a given side).
    let decaysL = eL[0] > eL[2] && eL[2] > eL[4]
    let decaysR = eR[1] > eR[3] && eR[3] > eR[5]
    check("echoes alternate L,R,L,R", alternates)
    check("feedback decays (no blow-up)", decaysL && decaysR && peak(l) <= 1.0001 && peak(r) <= 1.0001)
    check("finite", finite(l) && finite(r))

    // spread = 0 must collapse to a centered mono slap (L == R).
    let (l0, r0) = pingPong(imp, timeMs: timeMs, feedbackPct: fb * 100, mixPct: 100, spreadPct: 0)
    let monoDiff = zip(l0, r0).map { abs($0 - $1) }.max() ?? 0
    check("spread=0 → centered mono slap (L==R)", monoDiff < 1e-6)
}

print("\n== StereoReverb: noise → decorrelated, non-silent, finite tail ==")
do {
    var rng = SystemRandomNumberGenerator()
    let excite = 48000                              // 1 s of noise
    let tail = 48000 * 3                             // + 3 s tail
    var x = [Float](repeating: 0, count: excite + tail)
    for i in 0..<excite { x[i] = Float.random(in: -0.5...0.5, using: &rng) }
    let (l, r) = stereoReverb(x, decayPct: 85, dampPct: 20, mixPct: 100, widthPct: 100)

    // Correlate over the wet field after onset (skip first 50 ms transient).
    let from = 2400
    let corr = normCrossCorr(Array(l[from...]), Array(r[from...]))
    let rmsL = rms(l), rmsR = rms(r)
    // Tail still alive & bounded at the very end (last 100 ms).
    let endL = Array(l.suffix(4800)), endR = Array(r.suffix(4800))

    print(String(format: "  L/R normalized cross-correlation = %.4f  (want < 0.7)", corr))
    print(String(format: "  rmsL=%.4f  rmsR=%.4f  peakL=%.3f  peakR=%.3f", rmsL, rmsR, peak(l), peak(r)))
    print(String(format: "  tail(end) rms L=%.5f R=%.5f", rms(endL), rms(endR)))
    check("L/R decorrelated (corr < 0.7)", corr < 0.7)
    check("both non-silent", rmsL > 1e-3 && rmsR > 1e-3)
    check("finite over full 4 s", finite(l) && finite(r))
    check("tail non-silent & finite at end", rms(endL) > 1e-7 && rms(endR) > 1e-7 && finite(endL) && finite(endR))

    // width = 0 must collapse toward mono (correlation → ~1).
    let (lm, rm) = stereoReverb(x, decayPct: 85, dampPct: 20, mixPct: 100, widthPct: 0)
    let corrMono = normCrossCorr(Array(lm[from...]), Array(rm[from...]))
    print(String(format: "  width=0 cross-correlation = %.4f  (want ~1, mono collapse)", corrMono))
    check("width=0 → mono (corr > 0.95)", corrMono > 0.95)
}

print("\n== equalPowerPan ==")
do {
    let c = equalPowerPan(0), lft = equalPowerPan(-1), rgt = equalPowerPan(1)
    print(String(format: "  center=(%.4f, %.4f)  left=(%.4f, %.4f)  right=(%.4f, %.4f)",
                 c.l, c.r, lft.l, lft.r, rgt.l, rgt.r))
    check("center ≈ (0.707, 0.707)", abs(c.l - 0.7071) < 1e-3 && abs(c.r - 0.7071) < 1e-3)
    check("hard left ≈ (1, 0)", abs(lft.l - 1) < 1e-4 && abs(lft.r) < 1e-4)
    check("hard right ≈ (0, 1)", abs(rgt.l) < 1e-4 && abs(rgt.r - 1) < 1e-4)
    let powConst = abs((c.l * c.l + c.r * c.r) - 1) < 1e-4 && abs((lft.l * lft.l + lft.r * lft.r) - 1) < 1e-4
    check("constant power across sweep (L²+R²=1)", powConst)
}

print("\n\(pass ? "ALL TESTS PASSED ✓" : "SOME TESTS FAILED ✗")")
exit(pass ? 0 : 1)
