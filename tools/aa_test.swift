//
//  aa_test.swift
//  Headless verification for DriveBlock's anti-aliasing (Oversampler + ADAA1).
//
//  Replicates the EXACT hard-clip path used by DriveBlock mode 1 (8× Oversampler + ADAA1,
//  the same struct code copied verbatim from Blocks.swift), feeds a high-frequency sine at
//  high drive at 48 kHz, FFTs the output, and measures the aliasing as the energy in the
//  INHARMONIC bins (FFT bins that are NOT integer multiples of the fundamental — these are the
//  aliased, folded-down partials that cause "digital fizz"), for:
//     (a) naive point-sampled hard clip   (clamp(x·drive) at the base rate)
//     (b) the 8× OS + ADAA1 hard-clip path
//  and reports the dB reduction (target ≥ 20–30 dB). Also reports the oversampler latency.
//
//  Run:  swift tools/aa_test.swift
//

import Foundation
import Accelerate

// ============================================================================================
//  ADAA1 — copied verbatim from Blocks.swift
// ============================================================================================
struct ADAA1 {
    var prevX: Float = 0
    static let eps: Float = 1e-5

    mutating func reset() { prevX = 0 }

    mutating func process(_ x: Float, _ f: (Float) -> Float, _ F1: (Float) -> Float) -> Float {
        let dx = x - prevX
        let y = abs(dx) < ADAA1.eps ? f((x + prevX) * 0.5) : (F1(x) - F1(prevX)) / dx
        prevX = x
        return y
    }

    mutating func processTanh(_ x: Float) -> Float {
        let dx = x - prevX
        let y = abs(dx) < ADAA1.eps ? tanhf((x + prevX) * 0.5)
                                    : (ADAA1.tanhF1(x) - ADAA1.tanhF1(prevX)) / dx
        prevX = x; return y
    }
    mutating func processClip(_ x: Float) -> Float {
        let dx = x - prevX
        let y = abs(dx) < ADAA1.eps ? ADAA1.hardClip((x + prevX) * 0.5)
                                    : (ADAA1.clipF1(x) - ADAA1.clipF1(prevX)) / dx
        prevX = x; return y
    }
    mutating func processFuzz(_ x: Float) -> Float {
        let dx = x - prevX
        let y = abs(dx) < ADAA1.eps ? ADAA1.fuzz((x + prevX) * 0.5)
                                    : (ADAA1.fuzzF1(x) - ADAA1.fuzzF1(prevX)) / dx
        prevX = x; return y
    }

    @inline(__always) static func lnCosh(_ x: Float) -> Float {
        let a = abs(x); return a + log1pf(expf(-2 * a)) - 0.6931472
    }
    @inline(__always) static func tanhF1(_ x: Float) -> Float { lnCosh(x) }
    @inline(__always) static func hardClip(_ x: Float) -> Float { x < -1 ? -1 : (x > 1 ? 1 : x) }
    @inline(__always) static func clipF1(_ x: Float) -> Float { let a = abs(x); return a <= 1 ? x * x * 0.5 : a - 0.5 }
    @inline(__always) static func fuzz(_ x: Float) -> Float { x >= 0 ? tanhf(x) : 0.8 * tanhf(0.7 * x) }
    @inline(__always) static func fuzzF1(_ x: Float) -> Float { x >= 0 ? lnCosh(x) : (0.8 / 0.7) * lnCosh(0.7 * x) }
}

// ============================================================================================
//  Oversampler — copied verbatim from Blocks.swift
// ============================================================================================
struct Oversampler {
    private(set) var factor = 1
    private let tapsPerPhase = 16
    private var N = 16
    private var maxBlk = 0

    private var upRev: UnsafeMutableBufferPointer<Float>?
    private var downRev: UnsafeMutableBufferPointer<Float>?
    private var upHist: UnsafeMutableBufferPointer<Float>?
    private var upScratch: UnsafeMutableBufferPointer<Float>?
    private var high: UnsafeMutableBufferPointer<Float>?
    private var downHist: UnsafeMutableBufferPointer<Float>?
    private var downScratch: UnsafeMutableBufferPointer<Float>?
    private var filtered: UnsafeMutableBufferPointer<Float>?

    var latencySamples: Int { factor > 0 ? (N - 1 + factor / 2) / factor : 0 }

    mutating func prepare(factor: Int, maxBlock: Int) {
        let f = max(1, factor), mb = max(1, maxBlock)
        if upRev != nil && self.factor == f && maxBlk == mb { reset(); return }
        freeBuffers()
        self.factor = f; maxBlk = mb; N = tapsPerPhase * f
        let P = tapsPerPhase

        func mk(_ c: Int) -> UnsafeMutableBufferPointer<Float> {
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, c)); b.initialize(repeating: 0); return b
        }

        var proto = [Float](repeating: 0, count: N)
        let fc = 0.5 / Float(f), center = Float(N - 1) / 2
        var sum: Float = 0
        for k in 0..<N {
            let m = Float(k) - center
            let sval: Float = abs(m) < 1e-6 ? 2 * fc : sinf(2 * Float.pi * fc * m) / (Float.pi * m)
            let w = 0.42 - 0.5 * cosf(2 * Float.pi * Float(k) / Float(N - 1)) + 0.08 * cosf(4 * Float.pi * Float(k) / Float(N - 1))
            proto[k] = sval * w; sum += proto[k]
        }
        let inv = 1 / sum
        for k in 0..<N { proto[k] *= inv }

        let up = mk(P * f)
        for p in 0..<f { for q in 0..<P { up[p * P + q] = proto[(P - 1 - q) * f + p] * Float(f) } }
        upRev = up
        let dn = mk(N)
        for j in 0..<N { dn[j] = proto[N - 1 - j] }
        downRev = dn

        upHist = mk(P - 1)
        upScratch = mk((P - 1) + mb)
        high = mk(mb * f)
        downHist = mk(N - 1)
        downScratch = mk((N - 1) + mb * f)
        filtered = mk(mb * f)
    }

    mutating func reset() {
        if let p = upHist?.baseAddress { for i in 0..<(tapsPerPhase - 1) { p[i] = 0 } }
        if let p = downHist?.baseAddress, N > 1 { for i in 0..<(N - 1) { p[i] = 0 } }
    }

    mutating func freeBuffers() {
        upRev?.deallocate(); downRev?.deallocate()
        upHist?.deallocate(); upScratch?.deallocate(); high?.deallocate()
        downHist?.deallocate(); downScratch?.deallocate(); filtered?.deallocate()
        upRev = nil; downRev = nil; upHist = nil; upScratch = nil; high = nil
        downHist = nil; downScratch = nil; filtered = nil
    }

    mutating func process(_ s: UnsafeMutablePointer<Float>, _ n: Int, _ shape: (Float) -> Float) {
        guard n > 0, n <= maxBlk,
              let upRev = upRev?.baseAddress, let downRev = downRev?.baseAddress,
              let uh = upHist?.baseAddress, let us = upScratch?.baseAddress, let hi = high?.baseAddress,
              let dh = downHist?.baseAddress, let ds = downScratch?.baseAddress, let ft = filtered?.baseAddress
        else { for i in 0..<n { s[i] = shape(s[i]) }; return }

        let f = factor, P = tapsPerPhase, nHigh = n * f
        let histLen = P - 1, dHist = N - 1

        for i in 0..<histLen { us[i] = uh[i] }
        for i in 0..<n { us[histLen + i] = s[i] }
        for p in 0..<f {
            vDSP_conv(us, 1, upRev + p * P, 1, hi + p, vDSP_Stride(f), vDSP_Length(n), vDSP_Length(P))
        }
        for i in 0..<histLen { uh[i] = us[n + i] }

        for k in 0..<nHigh { hi[k] = shape(hi[k]) }

        for i in 0..<dHist { ds[i] = dh[i] }
        for i in 0..<nHigh { ds[dHist + i] = hi[i] }
        vDSP_conv(ds, 1, downRev, 1, ft, 1, vDSP_Length(nHigh), vDSP_Length(N))
        for m in 0..<n { s[m] = ft[m * f] }
        for i in 0..<dHist { dh[i] = ds[nHigh + i] }
    }
}

// ============================================================================================
//  Test harness
// ============================================================================================
let fs: Float = 48000
let log2n: vDSP_Length = 14
let Nfft = 1 << Int(log2n)          // 16384
let half = Nfft / 2                 // 8192
let warmup = 4096
let total = warmup + Nfft           // analyzed window = [warmup, warmup+Nfft)
let block = 512                     // realistic audio block size (exercises rolling history)

let f0: Float = 4500
let k0 = Int((f0 * Float(Nfft) / fs).rounded())   // = 1536, bin-exact fundamental
let driveAmt: Float = 20            // hard into the clipper -> near square wave
let Ain: Float = 0.5

print(String(format: "Config: fs=%.0f Hz  f0=%.0f Hz (bin %d)  drive=%.0f  Nfft=%d  block=%d",
             fs, f0, k0, driveAmt, Nfft, block))

// ---- Input sine ----
var x = [Float](repeating: 0, count: total)
for i in 0..<total { x[i] = Ain * sinf(2 * Float.pi * Float(k0) * Float(i) / Float(Nfft)) }

// ---- (a) naive point-sampled hard clip ----
var naive = [Float](repeating: 0, count: total)
for i in 0..<total { naive[i] = ADAA1.hardClip(x[i] * driveAmt) }

// ---- (b) 8× OS + ADAA1 hard-clip path (EXACT DriveBlock mode-1 inner path), chunked ----
var os8 = Oversampler()
os8.prepare(factor: 8, maxBlock: block)
var adaa = ADAA1()
var osOut = [Float](repeating: 0, count: total)
var workBlk = [Float](repeating: 0, count: block)
var pos = 0
while pos < total {
    let n = min(block, total - pos)
    for i in 0..<n { workBlk[i] = x[pos + i] }
    workBlk.withUnsafeMutableBufferPointer { wb in
        os8.process(wb.baseAddress!, n) { adaa.processClip($0 * driveAmt) }
    }
    for i in 0..<n { osOut[pos + i] = workBlk[i] }
    pos += n
}

// ---- FFT power spectrum of a length-Nfft segment ----
let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
func powerSpectrum(_ seg: ArraySlice<Float>) -> [Float] {
    precondition(seg.count == Nfft)
    let src = Array(seg)
    var realp = [Float](repeating: 0, count: half)
    var imagp = [Float](repeating: 0, count: half)
    var power = [Float](repeating: 0, count: half)
    realp.withUnsafeMutableBufferPointer { rp in
        imagp.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            src.withUnsafeBufferPointer { sb in
                sb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            // bin 0 packs DC (realp[0]) + Nyquist (imagp[0]); bins 1..half-1 are complex.
            power[0] = rp[0] * rp[0]                       // DC only (Nyquist ignored)
            for k in 1..<half { power[k] = rp[k] * rp[k] + ip[k] * ip[k] }
        }
    }
    return power
}

// ---- Split energy into harmonic vs inharmonic bins ----
var harmonicBins = Set<Int>()
var m = 1
while k0 * m < half { harmonicBins.insert(k0 * m); m += 1 }   // 1536, 3072, 4608, 6144, 7680

func energies(_ power: [Float]) -> (harm: Float, inharm: Float, subFund: Float, fund: Float) {
    var harm: Float = 0, inharm: Float = 0, sub: Float = 0
    for k in 1..<half {
        let p = power[k]
        if harmonicBins.contains(k) { harm += p }
        else { inharm += p; if k < k0 { sub += p } }   // bins below the fundamental are pure aliases
    }
    return (harm, inharm, sub, power[k0])
}

let pNaive = powerSpectrum(naive[warmup..<total])
let pOS    = powerSpectrum(osOut[warmup..<total])
let eN = energies(pNaive)
let eO = energies(pOS)

func dB(_ x: Float) -> Float { 10 * log10f(max(x, 1e-30)) }

let improvement = dB(eN.inharm) - dB(eO.inharm)
let subImprove  = dB(eN.subFund) - dB(eO.subFund)

print("")
print("Inharmonic (aliasing) energy — relative to each path's own fundamental:")
print(String(format: "  (a) naive hardclip : inharmonic = %7.2f dBc   (sub-fundamental = %7.2f dBc)",
             dB(eN.inharm) - dB(eN.fund), dB(eN.subFund) - dB(eN.fund)))
print(String(format: "  (b) 8x OS + ADAA1  : inharmonic = %7.2f dBc   (sub-fundamental = %7.2f dBc)",
             dB(eO.inharm) - dB(eO.fund), dB(eO.subFund) - dB(eO.fund)))
print("")
print(String(format: "  Aliasing REDUCTION (total inharmonic) : %6.2f dB", improvement))
print(String(format: "  Aliasing REDUCTION (sub-fundamental)  : %6.2f dB", subImprove))

// ---- Oversampler latency (measured via impulse) + reported value ----
var probe = Oversampler()
probe.prepare(factor: 8, maxBlock: 64)
var imp = [Float](repeating: 0, count: 64); imp[0] = 1
var peakIdx = 0; var peakVal: Float = 0
imp.withUnsafeMutableBufferPointer { ib in
    probe.process(ib.baseAddress!, 64) { $0 }     // identity shape -> pure up/down filter pair
    for i in 0..<64 { if abs(ib[i]) > peakVal { peakVal = abs(ib[i]); peakIdx = i } }
}
print("")
print(String(format: "  Oversampler latency: reported %d base samples (%.3f ms @ 48k), measured impulse peak @ %d",
             probe.latencySamples, Float(probe.latencySamples) / fs * 1000, peakIdx))
probe.freeBuffers()
os8.freeBuffers()

// ---- Verdict ----
print("")
if improvement >= 20 {
    print(String(format: "PASS  (>= 20 dB) — aliasing cut by %.1f dB", improvement))
    exit(0)
} else {
    print(String(format: "FAIL  (%.1f dB < 20 dB target)", improvement))
    exit(1)
}
