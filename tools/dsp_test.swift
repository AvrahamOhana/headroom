// Standalone impulse test for the Delay + Reverb DSP (mirrors Blocks.swift).
// Run on the Mac: swift tools/dsp_test.swift   — no device, no simulator.

import Foundation

final class TestDelay {
    var buf: [Float]; let cap: Int; var w = 0
    let delaySamples: Int; let feedback: Float; let mix: Float
    init(sr: Double, delaySamples: Int, feedback: Float, mix: Float) {
        cap = Int(sr * 2) + 2; buf = [Float](repeating: 0, count: cap)
        self.delaySamples = delaySamples; self.feedback = feedback; self.mix = mix
    }
    func process(_ s: inout [Float]) {
        let d = min(max(1, delaySamples), cap - 1)
        for i in 0..<s.count {
            let ri = (w - d + cap) % cap
            let echo = buf[ri]; let dry = s[i]
            buf[w] = dry + echo * feedback
            s[i] = dry + echo * mix
            w = (w + 1) % cap
        }
    }
}

final class TestReverb {
    let combTune = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    let apTune = [556, 441, 341, 225]
    var comb: [[Float]] = []; var combIdx: [Int] = []; var combStore: [Float] = []
    var ap: [[Float]] = []; var apIdx: [Int] = []
    let feedback: Float; let damp1: Float; let mix: Float
    init(sr: Double, feedback: Float, damp1: Float, mix: Float) {
        self.feedback = feedback; self.damp1 = damp1; self.mix = mix
        let scale = Float(sr) / 44100
        for t in combTune { comb.append([Float](repeating: 0, count: max(1, Int(Float(t) * scale)))); combIdx.append(0); combStore.append(0) }
        for t in apTune { ap.append([Float](repeating: 0, count: max(1, Int(Float(t) * scale)))); apIdx.append(0) }
    }
    func process(_ s: inout [Float]) {
        let d2 = 1 - damp1
        for i in 0..<s.count {
            let input = s[i] * 0.015
            var out: Float = 0
            for c in 0..<comb.count {
                let len = comb[c].count; var idx = combIdx[c]
                let y = comb[c][idx]
                combStore[c] = y * d2 + combStore[c] * damp1
                comb[c][idx] = input + combStore[c] * feedback
                idx += 1; if idx >= len { idx = 0 }; combIdx[c] = idx
                out += y
            }
            for a in 0..<ap.count {
                let len = ap[a].count; var idx = apIdx[a]
                let bufout = ap[a][idx]
                let y = -out + bufout
                ap[a][idx] = out + bufout * 0.5
                idx += 1; if idx >= len { idx = 0 }; apIdx[a] = idx
                out = y
            }
            s[i] = s[i] * (1 - mix) + out * mix
        }
    }
}

func peakNaN(_ x: [Float]) -> (Float, Bool) {
    var peak: Float = 0, nan = false
    for v in x { if !v.isFinite { nan = true; continue }; let a = abs(v); if a > peak { peak = a } }
    return (peak, nan)
}
func rms(_ x: ArraySlice<Float>) -> Float {
    var s: Float = 0; for v in x where v.isFinite { s += v * v }; return (s / Float(x.count)).squareRoot()
}

let sr = 48000.0

var d = [Float](repeating: 0, count: Int(sr)); d[0] = 1
TestDelay(sr: sr, delaySamples: 16800, feedback: 0.5, mix: 0.5).process(&d)
let (dp, dn) = peakNaN(d)
print(String(format: "DELAY  peak %.3f  NaN %@  | echo@16800=%.3f (≈0.50)  echo@33600=%.3f (≈0.25)",
             dp, dn ? "YES" : "no", d[16800], d[33600]))

var r = [Float](repeating: 0, count: Int(sr * 2)); r[0] = 1
TestReverb(sr: sr, feedback: 0.84, damp1: 0.2, mix: 1.0).process(&r)
let (rp, rn) = peakNaN(r)
let early = rms(r[100..<2400]), late = rms(r[(Int(sr * 2) - 2400)..<Int(sr * 2)])
print(String(format: "REVERB peak %.3f  NaN %@  | early RMS %.5f  late RMS %.5f  (tail should decay)",
             rp, rn ? "YES" : "no", early, late))

// ---- Compressor (mirrors CompressorBlock) ----
final class TestComp {
    let thr: Float, slope: Float, atk: Float, rel: Float; var env: Float = 0
    init(sr: Double, thr: Float, ratio: Float, atkMs: Float, relMs: Float) {
        self.thr = thr; slope = 1 - 1 / ratio
        atk = expf(-1 / (atkMs / 1000 * Float(sr))); rel = expf(-1 / (relMs / 1000 * Float(sr)))
    }
    func process(_ s: inout [Float]) {
        for i in 0..<s.count {
            let x = abs(s[i])
            env = x > env ? atk * (env - x) + x : rel * (env - x) + x
            let envDb = 20 * log10f(env > 1e-9 ? env : 1e-9)
            let gr = envDb > thr ? (thr - envDb) * slope : 0
            s[i] *= powf(10, gr / 20)
        }
    }
}

// ---- Drive (mirrors DriveBlock) ----
final class TestDrive {
    let d: Float, lv: Float, tc: Float; var ts: Float = 0
    init(sr: Double, drive: Float, level: Float, toneHz: Float) {
        d = drive; lv = level; tc = 1 - expf(-2 * Float.pi * toneHz / Float(sr))
    }
    func process(_ s: inout [Float]) {
        for i in 0..<s.count { let sh = tanhf(s[i] * d); ts += tc * (sh - ts); s[i] = ts * lv }
    }
}

func sine(_ amp: Float, _ hz: Double, _ count: Int, _ sr: Double) -> [Float] {
    (0..<count).map { amp * Float(sin(2 * Double.pi * hz * Double($0) / sr)) }
}

var cq = sine(0.0316, 440, 4800, sr)   // -30 dB (below -18 dB threshold)
var cl = sine(1.0, 440, 4800, sr)      //   0 dB (well above threshold)
TestComp(sr: sr, thr: -18, ratio: 4, atkMs: 5, relMs: 100).process(&cq)
TestComp(sr: sr, thr: -18, ratio: 4, atkMs: 5, relMs: 100).process(&cl)
let cqs = cq[3800..<4800].map { abs($0) }.max()!   // steady state (after attack settles)
let cls = cl[3800..<4800].map { abs($0) }.max()!
print(String(format: "COMP   quiet 0.032 → %.3f (≈unchanged)   loud 1.000 → %.3f steady (should compress <1)", cqs, cls))

var dr = sine(0.8, 220, 4800, sr)
TestDrive(sr: sr, drive: 20, level: 1, toneHz: 4000).process(&dr)
let (dp2, dn2) = peakNaN(dr)
print(String(format: "DRIVE  driven peak %.3f (bounded ≤1, saturated)   NaN %@", dp2, dn2 ? "YES" : "no"))

// ---- Tuner / YIN (mirrors Tuner.swift) ----
enum TestTuner {
    static let minLag = 48, maxLag = 768, window = 2048
    static func detect(_ x: [Float], sr: Float) -> Float? {
        guard x.count >= window + maxLag else { return nil }
        var r: Float = 0; for i in 0..<window { r += x[i] * x[i] }
        if (r / Float(window)).squareRoot() < 0.003 { return nil }
        var d = [Float](repeating: 0, count: maxLag)
        for tau in minLag..<maxLag { var s: Float = 0; for i in 0..<window { let df = x[i] - x[i + tau]; s += df * df }; d[tau] = s }
        var cm = [Float](repeating: 1, count: maxLag); var run: Float = 0
        for tau in 1..<maxLag { run += d[tau]; cm[tau] = run > 0 ? d[tau] * Float(tau) / run : 1 }
        var best = -1, tau = minLag
        while tau < maxLag - 1 { if cm[tau] < 0.15 { while tau + 1 < maxLag && cm[tau + 1] < cm[tau] { tau += 1 }; best = tau; break }; tau += 1 }
        if best < 0 { return nil }
        var t = Float(best)
        if best > minLag && best < maxLag - 1 { let a = cm[best - 1], b = cm[best], c = cm[best + 1]; let dn = a + c - 2 * b; if abs(dn) > 1e-9 { t += (a - c) / (2 * dn) } }
        let f = sr / t; return (f > 40 && f < 1200) ? f : nil
    }
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static func name(_ f: Float) -> String { let m = 69 + 12 * log2f(f / 440); let n = Int(m.rounded()); return "\(names[((n % 12) + 12) % 12])\(n / 12 - 1)" }
}
func tsine(_ hz: Double, _ n: Int) -> [Float] { (0..<n).map { 0.3 * Float(sin(2 * Double.pi * hz * Double($0) / 48000)) } }
let strings: [(String, Double)] = [("E2", 82.41), ("A2", 110.0), ("D3", 146.83), ("G3", 196.0), ("B3", 246.94), ("E4", 329.63)]
var tunerOK = true
for (expected, hz) in strings {
    if let f = TestTuner.detect(tsine(hz, 3100), sr: 48000) {
        let got = TestTuner.name(f); let ok = got == expected; tunerOK = tunerOK && ok
        print(String(format: "TUNER  %@ (%.2f Hz) → %.2f Hz = %@ %@", expected, hz, f, got, ok ? "✓" : "✗"))
    } else { print("TUNER  \(expected) → NO DETECTION ✗"); tunerOK = false }
}
print("TUNER  open strings: \(tunerOK ? "ALL PASS ✓" : "FAIL ✗")")
