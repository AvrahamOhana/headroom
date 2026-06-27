//
//  Blocks.swift
//  NamRig — block-based signal chain (modeler-style).
//
//  A SignalChain holds an ordered list of AudioBlocks. The audio render walks the chain
//  in order, calling each block's `render` (which skips it if bypassed). Future effects
//  (EQ, delay, reverb, comp, modulation, wah) are just new AudioBlock subclasses.
//
//  Threading: blocks pre-allocate in `prepare`; `process`/`render` run on the audio thread.
//  Bypass is atomic (safe live). Params are plain values (benign races, like the gains).
//  CHAIN STRUCTURE edits (add/remove/reorder) are done while STOPPED for now — gapless live
//  reordering (lock-free chain swap) is a later enhancement.
//

import Foundation
import Synchronization
import Accelerate

enum BlockKind: String, Sendable, CaseIterable {
    case gate = "Noise Gate"
    case comp = "Compressor"
    case boost = "Boost"
    case drive = "Drive"
    case pedal = "Pedal"
    case amp = "Amp"
    case eq = "EQ"
    case chorus = "Chorus"
    case flanger = "Flanger"
    case tremolo = "Tremolo"
    case delay = "Delay"
    case reverb = "Reverb"
    case irReverb = "IR Reverb"
}

/// Base class for a real-time DSP block. Subclasses override prepare/process/reset.
/// `nonisolated` — these run on the audio thread, not the main actor.
nonisolated class AudioBlock: @unchecked Sendable {
    let kind: BlockKind
    let bypass = Atomic<Bool>(false)

    init(kind: BlockKind) { self.kind = kind }

    func prepare(sampleRate: Double, maxBlock: Int) {}
    func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {}  // in place, mono
    func reset() {}

    /// Called by the chain — applies bypass.
    final func render(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        if !bypass.load(ordering: .relaxed) { process(s, n) }
    }
}

/// Noise gate — cuts the signal below a threshold (kills hiss between notes).
final class GateBlock: AudioBlock {
    var threshold: Float = 0.02   // linear
    private var env: Float = 0
    private var g: Float = 0

    init() { super.init(kind: .gate) }
    override func reset() { env = 0; g = 0 }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        let thr = threshold
        var e = env, gg = g
        for i in 0..<n {
            let a = abs(s[i])
            e = a > e ? a : e * 0.9995                              // peak envelope follower
            let target: Float = e > thr ? 1 : 0
            gg += (target - gg) * (target > gg ? 0.02 : 0.0006)    // fast open, slow close
            s[i] *= gg
        }
        env = e; g = gg
    }
}

/// Amp — drives the input into a NAM model, then DC-blocks + auto-levels the output.
final class AmpBlock: AudioBlock {
    // Model swap is RT-safe (mirrors `setIR`): the audio thread reads a raw pointer atomically and
    // NEVER does ARC on it, so it can't race the main thread's release of an old model. `keepAlive`
    // (main-thread-only) retains the current + recent models so none is freed while possibly in-flight.
    private let modelPtr = Atomic<UInt>(0)
    private var keepAlive: [NAMModel] = []
    var inputGain: Float = 1     // drive into the amp
    var makeupGain: Float = 1    // auto-level (from the model self-test)
    private var dcX1: Float = 0
    private var dcY1: Float = 0

    // Optional cab IR — post-amp convolution (vDSP overlap, RT-safe data-copy swap).
    private let maxIR = 2048
    private var maxBlk = 4096
    private var irRev: UnsafeMutableBufferPointer<Float>?    // IR taps, reversed (so vDSP_conv = convolution)
    private var irHist: UnsafeMutableBufferPointer<Float>?   // previous (irLen-1) input samples
    private var irScratch: UnsafeMutableBufferPointer<Float>?
    private var irLen = 0
    private let irOn = Atomic<Bool>(false)

    override init(kind: BlockKind = .amp) { super.init(kind: kind) }

    /// Swap the active model (main thread). Retains it in `keepAlive` (capped — a model from 8 user
    /// swaps ago can't still be in-flight on the audio thread), then publishes a raw pointer for the
    /// audio thread. Pass nil to detach.
    func setModel(_ m: NAMModel?) {
        if let m {
            keepAlive.append(m)
            if keepAlive.count > 8 { keepAlive.removeFirst() }
            modelPtr.store(UInt(bitPattern: Unmanaged.passUnretained(m).toOpaque()), ordering: .releasing)
        } else {
            modelPtr.store(0, ordering: .releasing)
        }
    }

    var hasModel: Bool { modelPtr.load(ordering: .relaxed) != 0 }

    override func prepare(sampleRate: Double, maxBlock: Int) {
        maxBlk = max(maxBlock, 1)
        if irRev == nil {
            irRev = .allocate(capacity: maxIR); irRev!.initialize(repeating: 0)
            irHist = .allocate(capacity: maxIR); irHist!.initialize(repeating: 0)
            irScratch = .allocate(capacity: maxIR + maxBlk); irScratch!.initialize(repeating: 0)
        }
    }

    override func reset() {
        dcX1 = 0; dcY1 = 0
        if let h = irHist?.baseAddress { for i in 0..<maxIR { h[i] = 0 } }
    }

    /// Load a cab IR (mono, already at engine SR, L1-normalized). Copies into the pre-allocated buffer.
    func setIR(_ taps: [Float]) {
        guard let rev = irRev?.baseAddress, let h = irHist?.baseAddress else { return }
        let n = min(taps.count, maxIR)
        irOn.store(false, ordering: .releasing)
        guard n > 1 else { irLen = 0; return }
        for i in 0..<n { rev[i] = taps[n - 1 - i] }
        for i in 0..<maxIR { h[i] = 0 }
        irLen = n
        irOn.store(true, ordering: .releasing)
    }
    func clearIR() { irOn.store(false, ordering: .releasing) }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        let ig = inputGain
        if ig != 1 { for i in 0..<n { s[i] *= ig } }

        // Read the model pointer atomically and use it WITHOUT ARC (takeUnretainedValue does no
        // retain/release) — the model stays alive via `keepAlive`, so no use-after-free on swap.
        let p = modelPtr.load(ordering: .acquiring)
        if p != 0, let raw = UnsafeRawPointer(bitPattern: p) {
            Unmanaged<NAMModel>.fromOpaque(raw).takeUnretainedValue().process(input: s, output: s, frames: Int32(n))
        }

        // DC blocker (~19 Hz one-pole high-pass) + makeup, in one pass.
        var x1 = dcX1, y1 = dcY1
        let mk = makeupGain
        for i in 0..<n {
            let x = s[i].isFinite ? s[i] : 0
            let y = x - x1 + 0.9975 * y1
            x1 = x; y1 = y
            s[i] = y * mk
        }
        dcX1 = x1; dcY1 = y1

        // Cab IR convolution: out[j] = Σ padded[j+p]·irRev[p], padded = [hist | block].
        if irOn.load(ordering: .acquiring), irLen > 1, n <= maxBlk,
           let rev = irRev?.baseAddress, let h = irHist?.baseAddress, let scr = irScratch?.baseAddress {
            let need = irLen - 1
            memcpy(scr, h, need * MemoryLayout<Float>.size)
            memcpy(scr + need, s, n * MemoryLayout<Float>.size)
            vDSP_conv(scr, 1, rev, 1, s, 1, vDSP_Length(n), vDSP_Length(irLen))
            memcpy(h, scr + n, need * MemoryLayout<Float>.size)
        }
    }
    deinit { irRev?.deallocate(); irHist?.deallocate(); irScratch?.deallocate() }
}

/// A single biquad filter (RBJ cookbook). Coefficients are set off the audio thread; state runs on it.
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
        b0 = (1 - cw) / 2 / a0
        b1 = (1 - cw) / a0
        b2 = (1 - cw) / 2 / a0
        a1 = -2 * cw / a0
        a2 = (1 - alpha) / a0
    }

    mutating func setHighpass(freq: Float, q: Float, sr: Float) {
        let w0 = 2 * Float.pi * freq / sr, cw = cosf(w0), sw = sinf(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        b0 = (1 + cw) / 2 / a0
        b1 = -(1 + cw) / a0
        b2 = (1 + cw) / 2 / a0
        a1 = -2 * cw / a0
        a2 = (1 - alpha) / a0
    }

    /// Constant 0 dB peak-gain band-pass (RBJ).
    mutating func setBandpass(freq: Float, q: Float, sr: Float) {
        let w0 = 2 * Float.pi * freq / sr, cw = cosf(w0), sw = sinf(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b1 = 0
        b2 = -alpha / a0
        a1 = -2 * cw / a0
        a2 = (1 - alpha) / a0
    }
}

/// First-order antiderivative anti-aliasing (ADAA) for a memoryless waveshaper. Reduces the
/// aliasing a hard nonlinearity creates by integrating it across each sample step instead of
/// point-sampling it. Stores one sample of state (`prevX`). Reusable value type.
///
/// y = (F1(x) − F1(prevX)) / (x − prevX), where F1 is an antiderivative of the shaper f.
/// When the step |x − prevX| is tiny the difference quotient is ill-conditioned (0/0), so we
/// fall back to the direct midpoint value f((x+prevX)/2). This fallback is MANDATORY — without
/// it, sustained/static signals produce NaNs, clicks and denormals.
struct ADAA1 {
    var prevX: Float = 0
    static let eps: Float = 1e-5

    mutating func reset() { prevX = 0 }

    /// Generic ADAA step. `f` is the waveshaper, `F1` its antiderivative.
    mutating func process(_ x: Float, _ f: (Float) -> Float, _ F1: (Float) -> Float) -> Float {
        let dx = x - prevX
        let y = abs(dx) < ADAA1.eps ? f((x + prevX) * 0.5) : (F1(x) - F1(prevX)) / dx
        prevX = x
        return y
    }

    // Specialized hot-path variants (no closure indirection) for the three DriveBlock shapes.
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

    // ---- Shapers and their antiderivatives (static, reusable) ----
    /// Numerically stable ln(cosh x) = |x| + ln(1 + e^−2|x|) − ln 2.
    @inline(__always) static func lnCosh(_ x: Float) -> Float {
        let a = abs(x); return a + log1pf(expf(-2 * a)) - 0.6931472
    }
    @inline(__always) static func tanhF1(_ x: Float) -> Float { lnCosh(x) }                  // ∫ tanh
    @inline(__always) static func hardClip(_ x: Float) -> Float { x < -1 ? -1 : (x > 1 ? 1 : x) }
    @inline(__always) static func clipF1(_ x: Float) -> Float { let a = abs(x); return a <= 1 ? x * x * 0.5 : a - 0.5 } // ∫ clip[-1,1]
    @inline(__always) static func fuzz(_ x: Float) -> Float { x >= 0 ? tanhf(x) : 0.8 * tanhf(0.7 * x) }
    @inline(__always) static func fuzzF1(_ x: Float) -> Float { x >= 0 ? lnCosh(x) : (0.8 / 0.7) * lnCosh(0.7 * x) }    // ∫ fuzz
}

/// Integer-factor (2/4/8) mono oversampler for taming the aliasing of a nonlinearity. Upsamples
/// with a polyphase linear-phase FIR interpolator, lets the caller apply a shaper at the high rate,
/// then low-pass-filters and decimates back to the base rate, in place.
///
/// Filter: one windowed-sinc prototype (Blackman, `tapsPerPhase` taps per polyphase branch, cutoff
/// at the base-rate Nyquist). The same prototype is reused (reversed) as the decimator FIR. All
/// buffers and coefficients are built in `prepare`; `process` only runs vDSP convs + copies + the
/// caller's shaper — no malloc, no locks.
///
/// LATENCY: linear phase ⇒ a pure delay of (N−1) high-rate samples = (N−1)/factor base-rate samples,
/// where N = tapsPerPhase·factor. With tapsPerPhase = 16 that is ≈ tapsPerPhase−1/factor base samples
/// for every factor (e.g. 127/8 = 15.875 samples ≈ 0.33 ms @ 48 kHz for 8×). `latencySamples` exposes
/// the exact base-rate value.
///
/// Ownership: holds raw buffers (like the blocks in this file). Meant to live as a stored property of
/// a single block and be mutated in place — do NOT copy it. The owner calls `freeBuffers()` from deinit.
struct Oversampler {
    private(set) var factor = 1
    private let tapsPerPhase = 16
    private var N = 16                  // total prototype taps = tapsPerPhase * factor
    private var maxBlk = 0

    // Coefficients (built in prepare).
    private var upRev: UnsafeMutableBufferPointer<Float>?    // factor branches × tapsPerPhase, reversed, ×factor gain
    private var downRev: UnsafeMutableBufferPointer<Float>?  // reverse(prototype), unity DC gain

    // Work + state buffers.
    private var upHist: UnsafeMutableBufferPointer<Float>?     // last tapsPerPhase−1 base inputs
    private var upScratch: UnsafeMutableBufferPointer<Float>?  // [upHist | block]             (tapsPerPhase−1 + maxBlk)
    private var high: UnsafeMutableBufferPointer<Float>?       // upsampled / shaped signal     (maxBlk·factor)
    private var downHist: UnsafeMutableBufferPointer<Float>?   // last N−1 high-rate samples
    private var downScratch: UnsafeMutableBufferPointer<Float>? // [downHist | high]            (N−1 + maxBlk·factor)
    private var filtered: UnsafeMutableBufferPointer<Float>?   // decimator FIR output          (maxBlk·factor)

    /// Pure delay the oversampler adds, in base-rate samples.
    var latencySamples: Int { factor > 0 ? (N - 1) / factor : 0 }

    mutating func prepare(factor: Int, maxBlock: Int) {
        let f = max(1, factor), mb = max(1, maxBlock)
        if upRev != nil && self.factor == f && maxBlk == mb { reset(); return }
        freeBuffers()
        self.factor = f; maxBlk = mb; N = tapsPerPhase * f
        let P = tapsPerPhase

        func mk(_ c: Int) -> UnsafeMutableBufferPointer<Float> {
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, c)); b.initialize(repeating: 0); return b
        }

        // Windowed-sinc (Blackman) prototype, cutoff at the base Nyquist (0.5/f cyc/sample of the high rate).
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
        for k in 0..<N { proto[k] *= inv }                       // unity DC gain

        // Polyphase up coefficients: branch p, reversed for vDSP_conv, with ×factor interpolation gain.
        let up = mk(P * f)
        for p in 0..<f { for q in 0..<P { up[p * P + q] = proto[(P - 1 - q) * f + p] * Float(f) } }
        upRev = up
        // Decimator coefficients: reversed prototype (unity DC gain), applied directly at the high rate.
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

    /// Upsample `s` (n base samples), apply `shape` at the high rate, low-pass + decimate back into `s`.
    mutating func process(_ s: UnsafeMutablePointer<Float>, _ n: Int, _ shape: (Float) -> Float) {
        guard n > 0, n <= maxBlk,
              let upRev = upRev?.baseAddress, let downRev = downRev?.baseAddress,
              let uh = upHist?.baseAddress, let us = upScratch?.baseAddress, let hi = high?.baseAddress,
              let dh = downHist?.baseAddress, let ds = downScratch?.baseAddress, let ft = filtered?.baseAddress
        else { for i in 0..<n { s[i] = shape(s[i]) }; return }     // not prepared → shape at base rate

        let f = factor, P = tapsPerPhase, nHigh = n * f
        let histLen = P - 1, dHist = N - 1

        // 1) Polyphase interpolation: upScratch = [upHist | s], one strided conv per branch → high.
        for i in 0..<histLen { us[i] = uh[i] }
        for i in 0..<n { us[histLen + i] = s[i] }
        for p in 0..<f {
            vDSP_conv(us, 1, upRev + p * P, 1, hi + p, vDSP_Stride(f), vDSP_Length(n), vDSP_Length(P))
        }
        for i in 0..<histLen { uh[i] = us[n + i] }                // roll input history

        // 2) Nonlinear shaper at the high rate (the caller's ADAA closure lives here).
        for k in 0..<nHigh { hi[k] = shape(hi[k]) }

        // 3) Decimation: downScratch = [downHist | high], FIR, keep every f-th sample.
        for i in 0..<dHist { ds[i] = dh[i] }
        for i in 0..<nHigh { ds[dHist + i] = hi[i] }
        vDSP_conv(ds, 1, downRev, 1, ft, 1, vDSP_Length(nHigh), vDSP_Length(N))
        for m in 0..<n { s[m] = ft[m * f] }
        for i in 0..<dHist { dh[i] = ds[nHigh + i] }              // roll high-rate history ([downHist|high] tail)
    }
}

/// 3-band EQ — low shelf @120 Hz, mid bell @750 Hz, high shelf @3 kHz. Post-amp tone shaping.
final class EQBlock: AudioBlock {
    private var lo = Biquad(), md = Biquad(), hi = Biquad()
    private var sr: Float = 48000
    private var bassDb: Float = 0, midDb: Float = 0, trebleDb: Float = 0

    init() { super.init(kind: .eq) }
    override func prepare(sampleRate: Double, maxBlock: Int) { sr = Float(sampleRate); recompute() }
    override func reset() { lo.reset(); md.reset(); hi.reset() }

    func setBands(bass: Float, mid: Float, treble: Float) {
        bassDb = bass; midDb = mid; trebleDb = treble
        recompute()
    }

    private func recompute() {
        lo.setLowShelf(freq: 120, gainDb: bassDb, sr: sr)
        md.setPeaking(freq: 750, gainDb: midDb, q: 0.7, sr: sr)
        hi.setHighShelf(freq: 3000, gainDb: trebleDb, sr: sr)
    }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            var v = lo.process(s[i])
            v = md.process(v)
            v = hi.process(v)
            s[i] = v
        }
    }
}

/// Feedback delay (single tap + feedback, wet/dry mix).
final class DelayBlock: AudioBlock {
    private var buf: UnsafeMutableBufferPointer<Float>?
    private var cap = 0
    private var w = 0
    var delaySamples = 16800   // ~350 ms @ 48k
    var feedback: Float = 0.35
    var mix: Float = 0.30

    init() { super.init(kind: .delay) }

    override func prepare(sampleRate: Double, maxBlock: Int) {
        let need = Int(sampleRate * 2) + 2     // up to 2 s
        if buf == nil || cap != need {
            buf?.deallocate()
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: need)
            b.initialize(repeating: 0)
            buf = b; cap = need
        }
        w = 0
    }

    override func reset() {
        if let base = buf?.baseAddress { for i in 0..<cap { base[i] = 0 } }
        w = 0
    }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard let base = buf?.baseAddress, cap > 1 else { return }
        let d = min(max(1, delaySamples), cap - 1)
        let fb = feedback, mx = mix
        var wi = w
        for i in 0..<n {
            let ri = (wi - d + cap) % cap
            let echo = base[ri]
            let dry = s[i]
            base[wi] = dry + echo * fb
            s[i] = dry + echo * mx
            wi += 1; if wi >= cap { wi = 0 }
        }
        w = wi
    }

    deinit { buf?.deallocate() }
}

/// Freeverb-style reverb — 8 parallel comb filters → 4 series allpass. Mono.
final class ReverbBlock: AudioBlock {
    private let combTune = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private let apTune = [556, 441, 341, 225]
    private var comb: [UnsafeMutableBufferPointer<Float>] = []
    private var combIdx: [Int] = []
    private var combStore: [Float] = []
    private var ap: [UnsafeMutableBufferPointer<Float>] = []
    private var apIdx: [Int] = []

    var feedback: Float = 0.84   // room size
    var damp1: Float = 0.2       // damping (0…0.4)
    var mix: Float = 0.25

    init() { super.init(kind: .reverb) }

    override func prepare(sampleRate: Double, maxBlock: Int) {
        freeBuffers()
        let scale = Float(sampleRate) / 44100
        for t in combTune {
            let len = max(1, Int(Float(t) * scale))
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: len); b.initialize(repeating: 0)
            comb.append(b); combIdx.append(0); combStore.append(0)
        }
        for t in apTune {
            let len = max(1, Int(Float(t) * scale))
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: len); b.initialize(repeating: 0)
            ap.append(b); apIdx.append(0)
        }
    }

    override func reset() {
        for b in comb { if let p = b.baseAddress { for i in 0..<b.count { p[i] = 0 } } }
        for b in ap { if let p = b.baseAddress { for i in 0..<b.count { p[i] = 0 } } }
        for i in combIdx.indices { combIdx[i] = 0; combStore[i] = 0 }
        for i in apIdx.indices { apIdx[i] = 0 }
    }

    private func freeBuffers() {
        for b in comb { b.deallocate() }
        for b in ap { b.deallocate() }
        comb = []; combIdx = []; combStore = []; ap = []; apIdx = []
    }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard !comb.isEmpty else { return }
        let fb = feedback, d1 = damp1, d2 = 1 - damp1, mx = mix
        let nComb = comb.count, nAp = ap.count
        for i in 0..<n {
            let input = s[i] * 0.015          // Freeverb fixed input gain
            var out: Float = 0
            for c in 0..<nComb {
                let p = comb[c].baseAddress!, len = comb[c].count
                var idx = combIdx[c]
                let y = p[idx]
                combStore[c] = y * d2 + combStore[c] * d1
                p[idx] = input + combStore[c] * fb
                idx += 1; if idx >= len { idx = 0 }
                combIdx[c] = idx
                out += y
            }
            for a in 0..<nAp {
                let p = ap[a].baseAddress!, len = ap[a].count
                var idx = apIdx[a]
                let bufout = p[idx]
                let y = -out + bufout
                p[idx] = out + bufout * 0.5
                idx += 1; if idx >= len { idx = 0 }
                apIdx[a] = idx
                out = y
            }
            s[i] = s[i] * (1 - mx) + out * mx
        }
    }

    deinit { freeBuffers() }
}

/// Convolution reverb — single-FFT overlap-save (real vDSP FFT). Loads an IR (room/hall/plate),
/// convolves the dry signal with it block-by-block, then mixes wet (with predelay) against dry.
///
/// Geometry: FFT size N = 65536, hop B = 512, so the IR may be up to N − B = 65024 taps
/// (zero-padded to N). The IR spectrum H is computed ONCE in `setIR`; every B accumulated dry
/// samples trigger one conv step (FFT the sliding N-sample window → multiply by H → IFFT → keep
/// the last B samples). A 1-block FIFO decouples arbitrary `process` block sizes from B, costing
/// B samples of latency on the WET path only — the DRY path is always immediate. Predelay (0…250 ms)
/// is a ring buffer on the wet signal. All buffers + the FFT setup are preallocated in `prepare`;
/// the IR swap is an atomic data-copy exactly like `AmpBlock.setIR` (RT-safe, lock/alloc-free).
final class ReverbIRBlock: AudioBlock {
    // Fixed transform geometry.
    private let N = 65536
    private let halfN = 32768
    private let B = 512
    private let log2N: vDSP_Length = 16
    private let maxIR = 65536 - 512        // N − B
    /// Empirically verified vDSP round-trip constant (see tools/ir_reverb_test.swift): the
    /// packed real forward FFT scales by 2, the spectral product by another 2, and the inverse
    /// by N, so the circular convolution = IFFT(X·H) / (4N).
    private let irScale: Float = 1.0 / Float(4 * 65536)

    // Preallocated transform buffers (all allocated once in `prepare`, reused across restarts).
    private var hr: UnsafeMutableBufferPointer<Float>?      // IR spectrum, split-complex realp (halfN)
    private var hi: UnsafeMutableBufferPointer<Float>?      // IR spectrum, split-complex imagp (halfN)
    private var window: UnsafeMutableBufferPointer<Float>?  // sliding input window (N)
    private var xr: UnsafeMutableBufferPointer<Float>?      // window spectrum realp (halfN)
    private var xi: UnsafeMutableBufferPointer<Float>?      // window spectrum imagp (halfN)
    private var yr: UnsafeMutableBufferPointer<Float>?      // product spectrum realp (halfN)
    private var yi: UnsafeMutableBufferPointer<Float>?      // product spectrum imagp (halfN)
    private var timeOut: UnsafeMutableBufferPointer<Float>? // IFFT result, time domain (N)
    private var irPad: UnsafeMutableBufferPointer<Float>?   // zero-padded IR scratch for setIR (N)
    private var inBuf: UnsafeMutableBufferPointer<Float>?   // FIFO input fill block (B)
    private var outBuf: UnsafeMutableBufferPointer<Float>?  // FIFO wet read block (B)
    private var pdRing: UnsafeMutableBufferPointer<Float>?  // predelay ring on the wet path
    private var fftSetup: FFTSetup?

    // Running state (audio-thread only, except where noted).
    private var pdCap = 0
    private var pdWrite = 0
    private var pdDelay = 0
    private var fillPos = 0
    private var readPos = 0
    private var irLen = 0
    private var sr: Float = 48000
    private let irOn = Atomic<Bool>(false)

    /// Wet/dry mix (0…1). Plain value — benign race, like the other blocks' mix knobs.
    var mix: Float = 0.3

    init() { super.init(kind: .irReverb) }

    private func makeBuf(_ count: Int) -> UnsafeMutableBufferPointer<Float> {
        let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        b.initialize(repeating: 0)
        return b
    }

    override func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate)
        if fftSetup == nil { fftSetup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) }
        if hr == nil {
            hr = makeBuf(halfN); hi = makeBuf(halfN)
            window = makeBuf(N)
            xr = makeBuf(halfN); xi = makeBuf(halfN)
            yr = makeBuf(halfN); yi = makeBuf(halfN)
            timeOut = makeBuf(N)
            irPad = makeBuf(N)
            inBuf = makeBuf(B); outBuf = makeBuf(B)
        }
        let needPd = Int(sampleRate * 0.30) + 2     // up to ~250 ms predelay (+ margin)
        if pdRing == nil || pdCap != needPd {
            pdRing?.deallocate()
            pdRing = makeBuf(needPd); pdCap = needPd
        }
        if pdDelay >= pdCap { pdDelay = pdCap - 1 }
        clearRunningState()
    }

    override func reset() { clearRunningState() }

    /// Zero the sliding window, FIFO and predelay; rewind all positions. Does NOT touch H/irOn.
    private func clearRunningState() {
        if let w = window?.baseAddress { for i in 0..<N { w[i] = 0 } }
        if let p = inBuf?.baseAddress { for i in 0..<B { p[i] = 0 } }
        if let p = outBuf?.baseAddress { for i in 0..<B { p[i] = 0 } }
        if let p = pdRing?.baseAddress { for i in 0..<pdCap { p[i] = 0 } }
        fillPos = 0; readPos = 0; pdWrite = 0
    }

    /// Predelay on the wet path (0…250 ms), converted to samples at the prepared sample rate.
    func setPredelay(ms: Float) {
        let cap = pdCap > 1 ? pdCap : 1
        pdDelay = min(max(0, Int(ms / 1000 * sr)), cap - 1)
    }

    /// Load an IR (mono, already at the engine sample rate and pre-normalized by the caller).
    /// Truncate/zero-pad to N, take one forward real FFT → spectrum H, clear running state, then
    /// re-enable. Gated atomically so the audio thread passes dry through during the swap.
    func setIR(_ taps: [Float]) {
        guard let setup = fftSetup,
              let pad = irPad?.baseAddress,
              let hrp = hr?.baseAddress, let hip = hi?.baseAddress else { return }
        irOn.store(false, ordering: .releasing)
        let n = min(taps.count, maxIR)
        guard n >= 1 else { irLen = 0; return }
        for i in 0..<N { pad[i] = i < n ? taps[i] : 0 }
        var split = DSPSplitComplex(realp: hrp, imagp: hip)
        pad.withMemoryRebound(to: DSPComplex.self, capacity: halfN) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfN))
        }
        vDSP_fft_zrip(setup, &split, 1, log2N, FFTDirection(kFFTDirection_Forward))
        irLen = n
        clearRunningState()
        irOn.store(true, ordering: .releasing)
    }

    func clearIR() { irOn.store(false, ordering: .releasing) }

    /// One overlap-save block: slide the window, append the freshly filled inBuf, FFT, multiply
    /// by H, inverse FFT, and write the last B (valid) samples into outBuf. RT-safe: only memmove/
    /// memcpy and vDSP on preallocated buffers, no allocation or locking.
    private func convStep() {
        guard let setup = fftSetup,
              let win = window?.baseAddress,
              let xrp = xr?.baseAddress, let xip = xi?.baseAddress,
              let yrp = yr?.baseAddress, let yip = yi?.baseAddress,
              let hrp = hr?.baseAddress, let hip = hi?.baseAddress,
              let tout = timeOut?.baseAddress,
              let inb = inBuf?.baseAddress, let outb = outBuf?.baseAddress else { return }

        // Slide window left by B, then append the B new dry samples at the tail.
        memmove(win, win + B, (N - B) * MemoryLayout<Float>.size)
        memcpy(win + (N - B), inb, B * MemoryLayout<Float>.size)

        // X = forward real FFT(window).
        var xs = DSPSplitComplex(realp: xrp, imagp: xip)
        win.withMemoryRebound(to: DSPComplex.self, capacity: halfN) {
            vDSP_ctoz($0, 2, &xs, 1, vDSP_Length(halfN))
        }
        vDSP_fft_zrip(setup, &xs, 1, log2N, FFTDirection(kFFTDirection_Forward))

        // Y = X · H. Bins 1…halfN-1 are complex; bin 0 packs DC (realp) and Nyquist (imagp) as reals.
        yrp[0] = xrp[0] * hrp[0]
        yip[0] = xip[0] * hip[0]
        var xc = DSPSplitComplex(realp: xrp + 1, imagp: xip + 1)
        var hc = DSPSplitComplex(realp: hrp + 1, imagp: hip + 1)
        var yc = DSPSplitComplex(realp: yrp + 1, imagp: yip + 1)
        vDSP_zvmul(&xc, 1, &hc, 1, &yc, 1, vDSP_Length(halfN - 1), 1)

        // Inverse real FFT → time, keep the LAST B samples (the valid overlap-save output), scaled.
        var ys = DSPSplitComplex(realp: yrp, imagp: yip)
        vDSP_fft_zrip(setup, &ys, 1, log2N, FFTDirection(kFFTDirection_Inverse))
        tout.withMemoryRebound(to: DSPComplex.self, capacity: halfN) {
            vDSP_ztoc(&ys, 1, $0, 2, vDSP_Length(halfN))
        }
        let sc = irScale
        for j in 0..<B { outb[j] = tout[N - B + j] * sc }
    }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        // IR off → dry passthrough, zero latency (signal is already dry in `s`).
        guard irOn.load(ordering: .acquiring),
              let inb = inBuf?.baseAddress, let outb = outBuf?.baseAddress,
              let pd = pdRing?.baseAddress, pdCap > 1 else { return }
        let mx = mix, dly = pdDelay, cap = pdCap
        var fp = fillPos, rp = readPos, pw = pdWrite
        for i in 0..<n {
            let dry = s[i]
            inb[fp] = dry; fp += 1
            let wet = outb[rp]; rp += 1                 // wet for input from B samples ago
            if fp >= B { convStep(); fp = 0; rp = 0 }    // block full → run one conv step, refill outBuf

            // Predelay the wet tap through the ring, then dry/wet mix (dry stays immediate).
            pd[pw] = wet
            let ri = pw - dly
            let wetDelayed = pd[ri >= 0 ? ri : ri + cap]
            pw += 1; if pw >= cap { pw = 0 }
            s[i] = dry * (1 - mx) + wetDelayed * mx
        }
        fillPos = fp; readPos = rp; pdWrite = pw
    }

    deinit {
        hr?.deallocate(); hi?.deallocate()
        window?.deallocate()
        xr?.deallocate(); xi?.deallocate()
        yr?.deallocate(); yi?.deallocate()
        timeOut?.deallocate()
        irPad?.deallocate()
        inBuf?.deallocate(); outBuf?.deallocate()
        pdRing?.deallocate()
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }
}

/// Feed-forward peak compressor (threshold / ratio / attack / release / makeup).
final class CompressorBlock: AudioBlock {
    var thresholdDb: Float = -18
    var ratio: Float = 4
    var makeup: Float = 1
    private var attackCoef: Float = 0.998
    private var releaseCoef: Float = 0.9998
    private var env: Float = 0
    private var sr: Float = 48000
    private var atkMs: Float = 10, relMs: Float = 120

    init() { super.init(kind: .comp) }
    override func prepare(sampleRate: Double, maxBlock: Int) { sr = Float(sampleRate); updateTimes() }
    override func reset() { env = 0 }

    func setTimes(attackMs: Float, releaseMs: Float) { atkMs = attackMs; relMs = releaseMs; updateTimes() }
    private func updateTimes() {
        attackCoef = expf(-1 / max(1, atkMs / 1000 * sr))
        releaseCoef = expf(-1 / max(1, relMs / 1000 * sr))
    }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        let thr = thresholdDb, slope = 1 - 1 / max(1, ratio), mk = makeup
        var e = env
        for i in 0..<n {
            let x = abs(s[i])
            e = x > e ? attackCoef * (e - x) + x : releaseCoef * (e - x) + x   // peak follower
            let envDb = 20 * log10f(e > 1e-9 ? e : 1e-9)
            let gr = envDb > thr ? (thr - envDb) * slope : 0                    // gain reduction (dB)
            s[i] *= powf(10, gr / 20) * mk
        }
        env = e
    }
}

/// Overdrive / boost — gain → waveshaper → tone (high-cut) → level. The waveshaper is run through
/// an oversampler + ADAA1 to kill the aliasing ("digital fizz") of the hard nonlinearity:
/// soft tanh at 2×, hard clip and fuzz at 8×, each step anti-aliased with ADAA1. The tone high-cut
/// and output level are linear, so they stay at the base rate (post-decimation), unchanged.
///
/// Public interface (drive / level / mode / setTone / prepare / reset / process) is unchanged.
final class DriveBlock: AudioBlock {
    var drive: Float = 1
    var level: Float = 1
    var mode: Int = 0           // 0 soft (tanh), 1 hard clip, 2 fuzz (asymmetric)
    private var toneCoef: Float = 0.3
    private var toneState: Float = 0
    private var sr: Float = 48000
    private var toneHz: Float = 4000

    // Anti-aliasing: 2× path for soft tanh, 8× path for hard clip & fuzz; each shaped through ADAA1.
    private var os2 = Oversampler()
    private var os8 = Oversampler()
    private var adaaTanh = ADAA1()
    private var adaaClip = ADAA1()
    private var adaaFuzz = ADAA1()

    init() { super.init(kind: .drive) }
    override func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate); updateTone()
        os2.prepare(factor: 2, maxBlock: maxBlock)
        os8.prepare(factor: 8, maxBlock: maxBlock)
        adaaTanh.reset(); adaaClip.reset(); adaaFuzz.reset()
    }
    override func reset() {
        toneState = 0
        os2.reset(); os8.reset()
        adaaTanh.reset(); adaaClip.reset(); adaaFuzz.reset()
    }

    func setTone(hz: Float) { toneHz = hz; updateTone() }
    private func updateTone() {
        let fc = min(max(toneHz, 100), sr / 2 - 100)
        toneCoef = 1 - expf(-2 * Float.pi * fc / sr)
    }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        let d = drive, lv = level, tc = toneCoef
        // Anti-aliased waveshaping (gain · shaper) at the oversampled rate, in place.
        switch mode {
        case 1:   // hard clip — 8× OS + ADAA1
            os8.process(s, n) { self.adaaClip.processClip($0 * d) }
        case 2:   // fuzz (asymmetric) — 8× OS + ADAA1
            os8.process(s, n) { self.adaaFuzz.processFuzz($0 * d) }
        default:  // soft tanh — 2× OS + ADAA1
            os2.process(s, n) { self.adaaTanh.processTanh($0 * d) }
        }
        // Tone one-pole high-cut + output level (linear, base rate — unchanged behavior).
        var ts = toneState
        for i in 0..<n { ts += tc * (s[i] - ts); s[i] = ts * lv }
        toneState = ts
    }

    deinit { os2.freeBuffers(); os8.freeBuffers() }
}

/// Clean boost — transparent gain (no clipping/coloration). Goes anywhere in the chain.
final class BoostBlock: AudioBlock {
    var gain: Float = 1   // linear
    init() { super.init(kind: .boost) }
    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        let g = gain
        if g != 1 { for i in 0..<n { s[i] *= g } }
    }
}

/// Tremolo — sine amplitude modulation.
final class TremoloBlock: AudioBlock {
    var rateHz: Float = 5
    var depth: Float = 0.5   // 0…1
    private var sr: Float = 48000
    private var phase: Float = 0
    init() { super.init(kind: .tremolo) }
    override func prepare(sampleRate: Double, maxBlock: Int) { sr = Float(sampleRate) }
    override func reset() { phase = 0 }
    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        let inc = 2 * Float.pi * rateHz / sr, dp = depth
        var ph = phase
        for i in 0..<n {
            let lfo = 1 - dp * 0.5 * (1 - cosf(ph))     // 1 → (1-dp)
            s[i] *= lfo
            ph += inc; if ph > 2 * Float.pi { ph -= 2 * Float.pi }
        }
        phase = ph
    }
}

/// Chorus — LFO-modulated short delay (~12 ms) mixed with dry. Fractional read for smooth pitch sweep.
final class ChorusBlock: AudioBlock {
    var rateHz: Float = 0.8
    var depthMs: Float = 6
    var mix: Float = 0.4
    private var sr: Float = 48000
    private var buf: UnsafeMutableBufferPointer<Float>?
    private var cap = 0, w = 0
    private var phase: Float = 0
    private let baseMs: Float = 12
    init() { super.init(kind: .chorus) }
    override func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate)
        let need = Int(sampleRate * 0.06) + 4
        if buf == nil || cap != need { buf?.deallocate(); let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: need); b.initialize(repeating: 0); buf = b; cap = need }
        w = 0
    }
    override func reset() { if let p = buf?.baseAddress { for i in 0..<cap { p[i] = 0 } }; w = 0; phase = 0 }
    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard let base = buf?.baseAddress, cap > 8 else { return }
        let inc = 2 * Float.pi * rateHz / sr, mx = mix
        let baseS = baseMs / 1000 * sr, depthS = depthMs / 1000 * sr
        var ph = phase, wi = w
        for i in 0..<n {
            let dry = s[i]
            base[wi] = dry
            let delayS = baseS + depthS * (0.5 * (1 - cosf(ph)))
            let rd = Float(wi) - delayS
            let r0 = Int(rd.rounded(.down)), frac = rd - rd.rounded(.down)
            let i0 = ((r0 % cap) + cap) % cap, i1 = (i0 + 1) % cap
            let wet = base[i0] * (1 - frac) + base[i1] * frac
            s[i] = dry * (1 - mx) + wet * mx
            wi += 1; if wi >= cap { wi = 0 }
            ph += inc; if ph > 2 * Float.pi { ph -= 2 * Float.pi }
        }
        phase = ph; w = wi
    }
    deinit { buf?.deallocate() }
}

/// Flanger — very short LFO-modulated delay (~1 ms) with feedback → jet sweep.
final class FlangerBlock: AudioBlock {
    var rateHz: Float = 0.4
    var depthMs: Float = 2
    var feedback: Float = 0.5
    var mix: Float = 0.5
    private var sr: Float = 48000
    private var buf: UnsafeMutableBufferPointer<Float>?
    private var cap = 0, w = 0
    private var phase: Float = 0
    private let baseMs: Float = 1
    init() { super.init(kind: .flanger) }
    override func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate)
        let need = Int(sampleRate * 0.03) + 4
        if buf == nil || cap != need { buf?.deallocate(); let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: need); b.initialize(repeating: 0); buf = b; cap = need }
        w = 0
    }
    override func reset() { if let p = buf?.baseAddress { for i in 0..<cap { p[i] = 0 } }; w = 0; phase = 0 }
    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard let base = buf?.baseAddress, cap > 8 else { return }
        let inc = 2 * Float.pi * rateHz / sr, fb = feedback, mx = mix
        let baseS = baseMs / 1000 * sr, depthS = depthMs / 1000 * sr
        var ph = phase, wi = w
        for i in 0..<n {
            let dry = s[i]
            let delayS = baseS + depthS * (0.5 * (1 - cosf(ph)))
            let rd = Float(wi) - delayS
            let r0 = Int(rd.rounded(.down)), frac = rd - rd.rounded(.down)
            let i0 = ((r0 % cap) + cap) % cap, i1 = (i0 + 1) % cap
            let wet = base[i0] * (1 - frac) + base[i1] * frac
            base[wi] = dry + wet * fb
            s[i] = dry * (1 - mx) + wet * mx
            wi += 1; if wi >= cap { wi = 0 }
            ph += inc; if ph > 2 * Float.pi { ph -= 2 * Float.pi }
        }
        phase = ph; w = wi
    }
    deinit { buf?.deallocate() }
}

/// Ordered chain. `install` sets the fixed block set once; `reorder` swaps the render order
/// live (RT-safe — render reads an int order-buffer + atomic count, never a torn pointer).
final class SignalChain: @unchecked Sendable {
    private var all: [AudioBlock] = []
    private let order: UnsafeMutableBufferPointer<Int>
    private let count = Atomic<Int>(0)
    private let cap: Int

    init(capacity: Int = 24) {
        cap = capacity
        order = .allocate(capacity: capacity)
        order.initialize(repeating: 0)
    }
    deinit { order.deallocate() }

    var blocks: [AudioBlock] { all }

    /// Install the full block set (once, before the engine starts). Initial order = given sequence.
    func install(_ blocks: [AudioBlock]) {
        all = blocks
        let n = min(blocks.count, cap)
        for i in 0..<n { order[i] = i }
        count.store(n, ordering: .releasing)
    }

    /// Reorder by indices into `all` (a permutation). Safe to call live from the main thread.
    func reorder(_ indices: [Int]) {
        let n = min(indices.count, cap)
        for i in 0..<n where indices[i] >= 0 && indices[i] < all.count { order[i] = indices[i] }
        count.store(n, ordering: .releasing)
    }

    func prepare(sampleRate: Double, maxBlock: Int) { for b in all { b.prepare(sampleRate: sampleRate, maxBlock: maxBlock) } }
    func reset() { for b in all { b.reset() } }

    func render(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        let c = count.load(ordering: .acquiring)
        for i in 0..<c { all[order[i]].render(s, n) }
    }
}
