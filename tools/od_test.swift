//
//  od_test.swift
//  Headless verification for CircuitDriveBlock (the circuit-modeled OD/dist/fuzz library).
//
//  Replicates each PedalModel's signal path with the SAME shared DSP (Biquad / ADAA1 / Oversampler
//  copied verbatim from Blocks.swift, and the exact clip shapers + antiderivatives from
//  CircuitDrive.swift) and verifies, per model:
//    (a) ANTI-ALIASING — a ~4 kHz sine at high drive: inharmonic/folded energy of the OS+ADAA clip
//        is >= 20 dB below the naive point-sampled clip (same pre-filters both sides).
//    (b) VOICING — Green Screamer pre-clip mid-hump (lows stay cleaner than mids); Rodent/DS-1
//        produce hard-clip high-order odd harmonics + a darker top than the TS; Muffin Fuzz shows
//        the ~1 kHz spectral scoop.
//    (c) FINITE & BOUNDED — every model, across the whole drive range, stays finite and bounded.
//    (d) CENTAUR DELAY-MATCH — the clean + clipped branch blend has NO comb notch when the clean
//        branch is delay-matched to the OS/ADAA wet (and a deep comb appears when it is not).
//
//  Run:  swift tools/od_test.swift
//

import Foundation
import Accelerate

// ============================================================================================
//  Shared DSP — copied verbatim from Blocks.swift
// ============================================================================================
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
    mutating func setLowShelf(freq: Float, gainDb: Float, sr: Float) {
        let A = powf(10, gainDb / 40)
        let w0 = 2 * Float.pi * freq / sr, cw = cosf(w0), sw = sinf(w0)
        let sa = 2 * sqrtf(A) * (sw / 2 * 1.4142135)
        let a0 = (A + 1) + (A - 1) * cw + sa
        b0 = A * ((A + 1) - (A - 1) * cw + sa) / a0
        b1 = 2 * A * ((A - 1) - (A + 1) * cw) / a0
        b2 = A * ((A + 1) - (A - 1) * cw - sa) / a0
        a1 = -2 * ((A - 1) + (A + 1) * cw) / a0
        a2 = ((A + 1) + (A - 1) * cw - sa) / a0
    }
    mutating func setHighShelf(freq: Float, gainDb: Float, sr: Float) {
        let A = powf(10, gainDb / 40)
        let w0 = 2 * Float.pi * freq / sr, cw = cosf(w0), sw = sinf(w0)
        let sa = 2 * sqrtf(A) * (sw / 2 * 1.4142135)
        let a0 = (A + 1) - (A - 1) * cw + sa
        b0 = A * ((A + 1) + (A - 1) * cw + sa) / a0
        b1 = -2 * A * ((A - 1) + (A + 1) * cw) / a0
        b2 = A * ((A + 1) + (A - 1) * cw - sa) / a0
        a1 = 2 * ((A - 1) - (A + 1) * cw) / a0
        a2 = ((A + 1) - (A - 1) * cw - sa) / a0
    }
    mutating func setPeaking(freq: Float, gainDb: Float, q: Float, sr: Float) {
        let A = powf(10, gainDb / 40)
        let w0 = 2 * Float.pi * freq / sr, cw = cosf(w0), sw = sinf(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha / A
        b0 = (1 + alpha * A) / a0
        b1 = -2 * cw / a0
        b2 = (1 - alpha * A) / a0
        a1 = -2 * cw / a0
        a2 = (1 - alpha / A) / a0
    }
    mutating func setLowpass(freq: Float, q: Float, sr: Float) {
        let w0 = 2 * Float.pi * freq / sr, cw = cosf(w0), sw = sinf(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        b0 = (1 - cw) / 2 / a0; b1 = (1 - cw) / a0; b2 = (1 - cw) / 2 / a0
        a1 = -2 * cw / a0; a2 = (1 - alpha) / a0
    }
    mutating func setHighpass(freq: Float, q: Float, sr: Float) {
        let w0 = 2 * Float.pi * freq / sr, cw = cosf(w0), sw = sinf(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        b0 = (1 + cw) / 2 / a0; b1 = -(1 + cw) / a0; b2 = (1 + cw) / 2 / a0
        a1 = -2 * cw / a0; a2 = (1 - alpha) / a0
    }
}

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
    @inline(__always) static func lnCosh(_ x: Float) -> Float {
        let a = abs(x); return a + log1pf(expf(-2 * a)) - 0.6931472
    }
    @inline(__always) static func hardClip(_ x: Float) -> Float { x < -1 ? -1 : (x > 1 ? 1 : x) }
    @inline(__always) static func clipF1(_ x: Float) -> Float { let a = abs(x); return a <= 1 ? x * x * 0.5 : a - 0.5 }
}

struct Oversampler {
    private(set) var factor = 1
    private let tapsPerPhase = 16
    private var N = 16
    private var maxBlk = 0
    private var upRev, downRev, upHist, upScratch, high, downHist, downScratch, filtered: UnsafeMutableBufferPointer<Float>?
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
        upHist = mk(P - 1); upScratch = mk((P - 1) + mb); high = mk(mb * f)
        downHist = mk(N - 1); downScratch = mk((N - 1) + mb * f); filtered = mk(mb * f)
    }
    mutating func reset() {
        if let p = upHist?.baseAddress { for i in 0..<(tapsPerPhase - 1) { p[i] = 0 } }
        if let p = downHist?.baseAddress, N > 1 { for i in 0..<(N - 1) { p[i] = 0 } }
    }
    mutating func freeBuffers() {
        upRev?.deallocate(); downRev?.deallocate(); upHist?.deallocate(); upScratch?.deallocate()
        high?.deallocate(); downHist?.deallocate(); downScratch?.deallocate(); filtered?.deallocate()
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
        for p in 0..<f { vDSP_conv(us, 1, upRev + p * P, 1, hi + p, vDSP_Stride(f), vDSP_Length(n), vDSP_Length(P)) }
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
//  Model table + clip shapers — mirror CircuitDrive.swift exactly
// ============================================================================================
enum ClipMode { case softFeedback, hardShunt, asym }
enum ToneType { case lowpassTilt, ratFilter, scoopTilt, klonTilt, muffScoop }

struct PModel {
    let name: String; let inputHz: Float; let gLo: Float; let gHi: Float
    let clip: ClipMode; let vf: Float; let asymVf: Float; let fbHz: Float
    let tone: ToneType; let toneLo: Float; let toneHi: Float; let scoopHz: Float; let scoopDb: Float
    let makeup: Float; let os: Int; let stages: Int; let needsDC: Bool
}

let MODELS: [PModel] = [
    PModel(name: "Green Screamer",     inputHz: 720, gLo: 2,  gHi: 90,  clip: .softFeedback, vf: 0.6, asymVf: 0.6, fbHz: 0,    tone: .lowpassTilt, toneLo: 2500, toneHi: 8000, scoopHz: 0,    scoopDb: 0,     makeup: 0.55, os: 2, stages: 1, needsDC: false),
    PModel(name: "Rodent",             inputHz: 32,  gLo: 6,  gHi: 800, clip: .hardShunt,    vf: 0.6, asymVf: 0.6, fbHz: 2400, tone: .ratFilter,   toneLo: 700,  toneHi: 4500, scoopHz: 0,    scoopDb: 0,     makeup: 0.32, os: 8, stages: 1, needsDC: false),
    PModel(name: "Modern Distortion",  inputHz: 50,  gLo: 8,  gHi: 500, clip: .hardShunt,    vf: 0.6, asymVf: 0.6, fbHz: 5000, tone: .scoopTilt,   toneLo: 1500, toneHi: 4000, scoopHz: 600,  scoopDb: -7,    makeup: 0.36, os: 8, stages: 1, needsDC: false),
    PModel(name: "Centaur Gold",       inputHz: 40,  gLo: 3,  gHi: 120, clip: .asym,         vf: 0.30, asymVf: 0.38, fbHz: 0,  tone: .klonTilt,    toneLo: 0,    toneHi: 3000, scoopHz: 0,    scoopDb: 0,     makeup: 0.70, os: 4, stages: 1, needsDC: true),
    PModel(name: "Muffin Fuzz",        inputHz: 80,  gLo: 10, gHi: 300, clip: .softFeedback, vf: 0.6, asymVf: 0.6, fbHz: 0,    tone: .muffScoop,   toneLo: 800,  toneHi: 6000, scoopHz: 1000, scoopDb: -13.5, makeup: 0.40, os: 8, stages: 2, needsDC: true),
]

// Memoryless shapers + antiderivatives — identical math to CircuitDriveBlock.
func softShape(_ x: Float, _ g: Float, _ vf: Float) -> Float { x + vf * tanhf(g * x / vf) }
func softF1(_ x: Float, _ g: Float, _ vf: Float) -> Float { 0.5 * x * x + (vf * vf / g) * ADAA1.lnCosh(g * x / vf) }
func hardShape(_ x: Float, _ g: Float, _ vf: Float) -> Float { vf * ADAA1.hardClip(g * x / vf) }
func hardF1(_ x: Float, _ g: Float, _ vf: Float) -> Float { (vf * vf / g) * ADAA1.clipF1(g * x / vf) }
func asymShape(_ x: Float, _ g: Float, _ vp: Float, _ vn: Float) -> Float { x >= 0 ? vp * tanhf(g * x / vp) : vn * tanhf(g * x / vn) }
func asymF1(_ x: Float, _ g: Float, _ vp: Float, _ vn: Float) -> Float { x >= 0 ? (vp * vp / g) * ADAA1.lnCosh(g * x / vp) : (vn * vn / g) * ADAA1.lnCosh(g * x / vn) }

func gainsFor(_ m: PModel, _ drive: Float) -> (Float, Float) {
    let g = m.gLo * powf(m.gHi / m.gLo, max(0, min(1, drive)))
    let g2 = m.stages == 2 ? max(2, g * 0.6) : g
    return (g, g2)
}

// ============================================================================================
//  A replica of CircuitDriveBlock used by the tests (block-by-block, exercises rolling history).
// ============================================================================================
let SR: Float = 48000
let BLOCK = 512

final class Sim {
    let m: PModel
    let drive: Float
    var g: Float = 1, g2: Float = 1
    var inputHP = Biquad(), preLP = Biquad(), bq0 = Biquad(), bq1 = Biquad(), bq2 = Biquad()
    var dcX1: Float = 0, dcY1: Float = 0
    var adaaA = ADAA1(), adaaB = ADAA1()
    var os = Oversampler()
    var ring = [Float](repeating: 0, count: 256); var ringW = 0
    var hasPreLP: Bool { m.fbHz > 0 }

    init(_ m: PModel, drive: Float) {
        self.m = m; self.drive = drive
        (g, g2) = gainsFor(m, drive)
        inputHP.setHighpass(freq: min(m.inputHz, SR * 0.45), q: 0.707, sr: SR)
        if hasPreLP { preLP.setLowpass(freq: min(m.fbHz, SR * 0.45), q: 0.707, sr: SR) }
        os.prepare(factor: m.os, maxBlock: BLOCK)
        setTone(0.5)
    }
    deinit { os.freeBuffers() }

    func setTone(_ t: Float) {
        func lerp(_ a: Float, _ b: Float, _ x: Float) -> Float { a + (b - a) * x }
        func ident(_ b: inout Biquad) { b.b0 = 1; b.b1 = 0; b.b2 = 0; b.a1 = 0; b.a2 = 0 }
        switch m.tone {
        case .lowpassTilt:
            bq0.setLowpass(freq: lerp(m.toneLo, m.toneHi, t), q: 0.707, sr: SR)
            bq1.setHighShelf(freq: 2000, gainDb: 3, sr: SR); ident(&bq2)
        case .ratFilter:
            bq0.setLowpass(freq: lerp(m.toneHi, m.toneLo, t), q: 0.707, sr: SR); ident(&bq1); ident(&bq2)
        case .scoopTilt:
            bq0.setLowpass(freq: lerp(m.toneLo, m.toneHi, t), q: 0.707, sr: SR)
            bq1.setHighShelf(freq: 3000, gainDb: lerp(-6, 6, t), sr: SR)
            bq2.setPeaking(freq: m.scoopHz, gainDb: m.scoopDb, q: 1.0, sr: SR)
        case .klonTilt:
            bq0.setHighShelf(freq: m.toneHi, gainDb: lerp(-3, 8, t), sr: SR); ident(&bq1); ident(&bq2)
        case .muffScoop:
            bq0.setPeaking(freq: m.scoopHz, gainDb: m.scoopDb, q: 0.9, sr: SR)
            bq1.setLowpass(freq: lerp(m.toneLo, m.toneHi, t), q: 0.707, sr: SR); ident(&bq2)
        }
    }

    // Run the OS+ADAA clip on a block (in place). `asym` here is the WET branch only.
    private func clipBlock(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        switch m.clip {
        case .softFeedback:
            if m.stages == 2 {
                os.process(p, n) { x in
                    let a = self.adaaA.process(x, { softShape($0, self.g, self.m.vf) }, { softF1($0, self.g, self.m.vf) })
                    return self.adaaB.process(a, { softShape($0, self.g2, self.m.vf) }, { softF1($0, self.g2, self.m.vf) })
                }
            } else {
                os.process(p, n) { x in self.adaaA.process(x, { softShape($0, self.g, self.m.vf) }, { softF1($0, self.g, self.m.vf) }) }
            }
        case .hardShunt:
            os.process(p, n) { x in self.adaaA.process(x, { hardShape($0, self.g, self.m.vf) }, { hardF1($0, self.g, self.m.vf) }) }
        case .asym:
            os.process(p, n) { x in self.adaaA.process(x, { asymShape($0, self.g, self.m.vf, self.m.asymVf) }, { asymF1($0, self.g, self.m.vf, self.m.asymVf) }) }
        }
    }

    // Naive point-sampled clip (no OS, no ADAA) — the aliasing baseline.
    private func clipNaive(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        switch m.clip {
        case .softFeedback:
            if m.stages == 2 { for i in 0..<n { p[i] = softShape(softShape(p[i], g, m.vf), g2, m.vf) } }
            else { for i in 0..<n { p[i] = softShape(p[i], g, m.vf) } }
        case .hardShunt: for i in 0..<n { p[i] = hardShape(p[i], g, m.vf) }
        case .asym:      for i in 0..<n { p[i] = asymShape(p[i], g, m.vf, m.asymVf) }
        }
    }

    // Post-clip signal only (input HPF + preLP + clip). No clean-sum, no DC, no tone — isolates the
    // nonlinearity for the AA + harmonic-profile measurements.
    func runClip(_ x: [Float], useOS: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var pos = 0
        var blk = [Float](repeating: 0, count: BLOCK)
        while pos < x.count {
            let n = min(BLOCK, x.count - pos)
            for i in 0..<n { var v = inputHP.process(x[pos + i]); if hasPreLP { v = preLP.process(v) }; blk[i] = v }
            blk.withUnsafeMutableBufferPointer { bp in
                if useOS { clipBlock(bp.baseAddress!, n) } else { clipNaive(bp.baseAddress!, n) }
            }
            for i in 0..<n { out[pos + i] = blk[i] }
            pos += n
        }
        return out
    }

    // Full path: input HPF + preLP + clip(OS) + [Klon clean-sum, delay-matched] + DC + tone + level.
    func runFull(_ x: [Float], klonMatch: Bool = true) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var pos = 0
        var blk = [Float](repeating: 0, count: BLOCK)
        var clean = [Float](repeating: 0, count: BLOCK)
        let outGain = m.makeup    // level knob = 1.0 in tests
        let L = min(os.latencySamples, ring.count - 1)
        let cleanMix: Float = 1
        let wetMix: Float = (m.clip == .asym) ? (0.0 + 0.8 * max(0, min(1, drive))) : 1
        while pos < x.count {
            let n = min(BLOCK, x.count - pos)
            for i in 0..<n { var v = inputHP.process(x[pos + i]); if hasPreLP { v = preLP.process(v) }; blk[i] = v }
            if m.clip == .asym {
                for i in 0..<n { clean[i] = blk[i] }
                blk.withUnsafeMutableBufferPointer { clipBlock($0.baseAddress!, n) }
                for i in 0..<n {
                    ring[ringW] = clean[i]
                    let rd = ringW - (klonMatch ? L : 0)
                    let cd = ring[rd >= 0 ? rd : rd + ring.count]
                    ringW += 1; if ringW >= ring.count { ringW = 0 }
                    blk[i] = cleanMix * cd + wetMix * blk[i]
                }
            } else {
                blk.withUnsafeMutableBufferPointer { clipBlock($0.baseAddress!, n) }
            }
            if m.needsDC {
                for i in 0..<n {
                    let xx = blk[i].isFinite ? blk[i] : 0
                    let yy = xx - dcX1 + 0.9975 * dcY1
                    dcX1 = xx; dcY1 = yy; blk[i] = yy
                }
            }
            for i in 0..<n {
                var v = bq0.process(blk[i]); v = bq1.process(v); v = bq2.process(v)
                v *= outGain
                out[pos + i] = v.isFinite ? v : 0
            }
            pos += n
        }
        return out
    }
}

// ============================================================================================
//  FFT helpers
// ============================================================================================
let LOG2N: vDSP_Length = 14
let NFFT = 1 << Int(LOG2N)        // 16384
let HALF = NFFT / 2
let WARMUP = 4096
let setup = vDSP_create_fftsetup(LOG2N, FFTRadix(kFFTRadix2))!

func binFor(_ hz: Float) -> Int { Int((hz * Float(NFFT) / SR).rounded()) }
func hzFor(_ bin: Int) -> Float { Float(bin) * SR / Float(NFFT) }

func powerSpectrum(_ seg: ArraySlice<Float>) -> [Float] {
    precondition(seg.count == NFFT)
    let src = Array(seg)
    var realp = [Float](repeating: 0, count: HALF)
    var imagp = [Float](repeating: 0, count: HALF)
    var power = [Float](repeating: 0, count: HALF)
    realp.withUnsafeMutableBufferPointer { rp in
        imagp.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            src.withUnsafeBufferPointer { sb in
                sb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: HALF) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(HALF)) }
            }
            vDSP_fft_zrip(setup, &split, 1, LOG2N, FFTDirection(kFFTDirection_Forward))
            power[0] = rp[0] * rp[0]
            for k in 1..<HALF { power[k] = rp[k] * rp[k] + ip[k] * ip[k] }
        }
    }
    return power
}

func dB(_ x: Float) -> Float { 10 * log10f(max(x, 1e-30)) }

// Build a steady tone, run it through `gen`, return power spectrum of the steady window.
func spectrumOf(_ gen: ([Float]) -> [Float], toneHz: Float, amp: Float) -> (p: [Float], k0: Int) {
    let k0 = binFor(toneHz)
    let total = WARMUP + NFFT
    var x = [Float](repeating: 0, count: total)
    for i in 0..<total { x[i] = amp * sinf(2 * Float.pi * Float(k0) * Float(i) / Float(NFFT)) }
    let y = gen(x)
    return (powerSpectrum(y[WARMUP..<total]), k0)
}

// ============================================================================================
//  Suite (a) — anti-aliasing per model
// ============================================================================================
print("================ CircuitDrive verification (fs=\(Int(SR)) Hz, Nfft=\(NFFT), block=\(BLOCK)) ================\n")
print("(a) ANTI-ALIASING — ~4 kHz sine @ high drive, inharmonic energy: naive vs 8×/4×/2× OS+ADAA")
let f0 = hzFor(binFor(4000))
let k0aa = binFor(4000)
print(String(format: "    test tone = %.1f Hz (bin %d), drive = 0.90, target reduction >= 20 dB\n", f0, k0aa))

var harmonicBins = Set<Int>()
do { var mm = 1; while k0aa * mm < HALF { harmonicBins.insert(k0aa * mm); mm += 1 } }
func inharmonic(_ p: [Float]) -> (inh: Float, fund: Float) {
    var inh: Float = 0
    for k in 1..<HALF where !harmonicBins.contains(k) { inh += p[k] }
    return (inh, p[k0aa])
}

var aaPass = true
for m in MODELS {
    let naive = spectrumOf({ Sim(m, drive: 0.9).runClip($0, useOS: false) }, toneHz: f0, amp: 0.5)
    let osd   = spectrumOf({ Sim(m, drive: 0.9).runClip($0, useOS: true)  }, toneHz: f0, amp: 0.5)
    let en = inharmonic(naive.p), eo = inharmonic(osd.p)
    let nRel = dB(en.inh) - dB(en.fund), oRel = dB(eo.inh) - dB(eo.fund)
    let reduction = dB(en.inh) - dB(eo.inh)
    let ok = reduction >= 20
    aaPass = aaPass && ok
    print(String(format: "    %-18@  naive inharm %7.2f dBc → OS %7.2f dBc   reduction %6.2f dB  [%@]",
                 m.name as NSString, nRel, oRel, reduction, (ok ? "PASS" : "FAIL") as NSString))
}
print("")

// ============================================================================================
//  Suite (b) — voicing signatures
// ============================================================================================
print("(b) VOICING signatures")
var voicePass = true

// b1 — Green Screamer pre-clip mid-hump: lows distort less than mids (HPF cleans lows before clip).
func thdAt(_ m: PModel, _ hz: Float, drive: Float, amp: Float) -> Float {
    let s = spectrumOf({ Sim(m, drive: drive).runClip($0, useOS: true) }, toneHz: hz, amp: amp)
    var harm: Float = 0; var mm = 2
    while s.k0 * mm < HALF { harm += s.p[s.k0 * mm]; mm += 1 }
    return dB(harm) - dB(s.p[s.k0])   // harmonic-to-fundamental ratio, dB
}
let ts = MODELS[0]
let thdLow = thdAt(ts, 80, drive: 0.7, amp: 1.0)
let thdMid = thdAt(ts, 1000, drive: 0.7, amp: 1.0)
let humpGap = thdMid - thdLow
let humpOK = humpGap >= 8
voicePass = voicePass && humpOK
print(String(format: "    Green Screamer mid-hump: THD@80Hz = %6.2f dBc, THD@1kHz = %6.2f dBc  → mids %5.2f dB dirtier  [%@]",
             thdLow, thdMid, humpGap, (humpOK ? "PASS" : "FAIL") as NSString))

// b2 — Rodent/DS-1 hard-clip high-order odd harmonics + darker top than the TS.
//   high-order odd richness (pre-tone): (P5+P7+P9)/P3 — hard clip is far richer in the high odds than
//   the soft TS. darker top: fraction of full-output energy above 3 kHz (driven by the post-clip LPF).
func oddProfile(_ m: PModel, hz: Float, drive: Float) -> Float {
    let s = spectrumOf({ Sim(m, drive: drive).runClip($0, useOS: true) }, toneHz: hz, amp: 0.5)
    func P(_ ord: Int) -> Float { let b = s.k0 * ord; return b < HALF ? s.p[b] : 0 }
    return (P(5) + P(7) + P(9)) / max(P(3), 1e-20)
}
func hfRatio(_ m: PModel, hz: Float, drive: Float) -> Float {   // energy >3 kHz / total
    let s = spectrumOf({ Sim(m, drive: drive).runFull($0) }, toneHz: hz, amp: 0.6)
    var hi: Float = 0, all: Float = 0
    for k in 1..<HALF { all += s.p[k]; if hzFor(k) > 3000 { hi += s.p[k] } }
    return all > 0 ? hi / all : 0
}
let tsOdd = oddProfile(MODELS[0], hz: 1000, drive: 0.5)
let ratOdd = oddProfile(MODELS[1], hz: 1000, drive: 0.5)
let dsOdd  = oddProfile(MODELS[2], hz: 1000, drive: 0.5)
let tsHF = hfRatio(MODELS[0], hz: 1000, drive: 0.7)
let ratHF = hfRatio(MODELS[1], hz: 1000, drive: 0.7)
let dsHF  = hfRatio(MODELS[2], hz: 1000, drive: 0.7)
let ratHarder = ratOdd > tsOdd
let dsHarder  = dsOdd  > tsOdd
let ratDarker = ratHF < tsHF
let dsDarker  = dsHF  < tsHF
voicePass = voicePass && ratHarder && dsHarder && ratDarker && dsDarker
print(String(format: "    Hard-clip high-order odds (P5+7+9)/P3:  TS %6.3f | Rodent %6.3f [%@] | DS-1 %6.3f [%@]",
             tsOdd, ratOdd, (ratHarder ? "PASS" : "FAIL") as NSString, dsOdd, (dsHarder ? "PASS" : "FAIL") as NSString))
print(String(format: "    Darker top (energy >3 kHz, %% of total): TS %5.1f%% | Rodent %5.1f%% [%@] | DS-1 %5.1f%% [%@]",
             tsHF * 100, ratHF * 100, (ratDarker ? "PASS" : "FAIL") as NSString,
             dsHF * 100, (dsDarker ? "PASS" : "FAIL") as NSString))

// b3 — Muffin Fuzz ~1 kHz scoop: tiny-amplitude tones (near-linear) — 1 kHz output sits well below 300/2k.
func toneLevel(_ m: PModel, hz: Float) -> Float {
    let s = spectrumOf({ Sim(m, drive: 0.0).runFull($0) }, toneHz: hz, amp: 0.001)
    return dB(s.p[s.k0])
}
let muff = MODELS[4]
let l300 = toneLevel(muff, hz: 300), l1k = toneLevel(muff, hz: 1000), l2k = toneLevel(muff, hz: 2000)
let scoop300 = l300 - l1k, scoop2k = l2k - l1k
let scoopOK = scoop300 >= 8 && scoop2k >= 8
voicePass = voicePass && scoopOK
print(String(format: "    Muffin Fuzz 1 kHz scoop: L300=%6.2f L1k=%6.2f L2k=%6.2f dB → dip %5.2f/%5.2f dB vs 300/2k  [%@]",
             l300, l1k, l2k, scoop300, scoop2k, (scoopOK ? "PASS" : "FAIL") as NSString))
print("")

// ============================================================================================
//  Suite (c) — finite & bounded across the drive range
// ============================================================================================
print("(c) FINITE & BOUNDED — 220 Hz @ amp 1.0 + impulses, drive ∈ {0, .25, .5, .75, 1}")
let BOUND: Float = 8
var boundPass = true
for m in MODELS {
    var worst: Float = 0; var allFinite = true
    for d in [Float(0), 0.25, 0.5, 0.75, 1.0] {
        let total = WARMUP + NFFT
        var x = [Float](repeating: 0, count: total)
        let kb = binFor(220)
        for i in 0..<total { x[i] = sinf(2 * Float.pi * Float(kb) * Float(i) / Float(NFFT)) }
        for i in stride(from: 1000, to: total, by: 2000) { x[i] += (i % 4000 == 1000) ? 1.0 : -1.0 }  // impulses
        let y = Sim(m, drive: d).runFull(x)
        for v in y { if !v.isFinite { allFinite = false }; worst = max(worst, abs(v)) }
    }
    let ok = allFinite && worst < BOUND
    boundPass = boundPass && ok
    print(String(format: "    %-18@  peak |out| = %6.3f   finite=%@   [%@]",
                 m.name as NSString, worst, (allFinite ? "yes" : "NO") as NSString, (ok ? "PASS" : "FAIL") as NSString))
}
print("")

// ============================================================================================
//  Suite (d) — Centaur clean/clipped delay-match (no comb notch)
// ============================================================================================
print("(d) CENTAUR delay-match — impulse through the clean+clipped blend, deepest notch 200 Hz–8 kHz")
// A tiny impulse keeps the asym clip in its LINEAR region (slope g). At drive 0.2 the blend weights
// are equal (cleanMix=1 ≈ wetMix·g), so a NON-delay-matched clean branch sums with the OS-delayed wet
// as two equal impulses → a deep, periodic comb. Delay-matching collapses them to one cluster → flat.
let klon = MODELS[3]
let total = WARMUP + NFFT
var imp = [Float](repeating: 0, count: total)
imp[WARMUP] = 0.005
func deepestNotchDb(_ y: [Float]) -> Float {
    let p = powerSpectrum(y[WARMUP..<total])     // |H|² of the blend impulse response (deterministic)
    let lo = binFor(200), hi = binFor(8000)
    var mean: Float = 0; var cnt = 0
    for k in lo...hi { mean += p[k]; cnt += 1 }
    mean /= Float(cnt)
    var minP: Float = .greatestFiniteMagnitude
    for k in lo...hi { minP = min(minP, p[k]) }
    return 0.5 * (dB(minP) - dB(mean))           // magnitude dB (half of power dB) re band mean
}
let matched   = deepestNotchDb(Sim(klon, drive: 0.2).runFull(imp, klonMatch: true))
let unmatched = deepestNotchDb(Sim(klon, drive: 0.2).runFull(imp, klonMatch: false))
let combOK = (matched > -4) && (unmatched < matched - 8)
let dPass = combOK
print(String(format: "    matched notch = %6.2f dB (shallow, no comb)  |  unmatched notch = %6.2f dB (deep comb)  [%@]",
             matched, unmatched, (combOK ? "PASS" : "FAIL") as NSString))
print("")

// ============================================================================================
//  Verdict
// ============================================================================================
let allPass = aaPass && voicePass && boundPass && dPass
print("================================================================")
print(String(format: "  (a) anti-aliasing : %@", (aaPass ? "PASS" : "FAIL") as NSString))
print(String(format: "  (b) voicing       : %@", (voicePass ? "PASS" : "FAIL") as NSString))
print(String(format: "  (c) bounded       : %@", (boundPass ? "PASS" : "FAIL") as NSString))
print(String(format: "  (d) delay-match   : %@", (dPass ? "PASS" : "FAIL") as NSString))
print("================================================================")
vDSP_destroy_fftsetup(setup)
if allPass { print("\nALL PASS"); exit(0) } else { print("\nFAILED"); exit(1) }
