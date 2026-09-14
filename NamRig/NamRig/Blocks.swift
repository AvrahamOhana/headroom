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
    case stomp = "Stomp"
    case wah = "Wah"
    case pedal = "Pedal"
    case amp = "Amp"
    case cab = "Cab"
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

/// One-pole parameter smoother (~`ms` to reach 1−1/e). Kills zipper noise on gain/mix knobs that
/// the UI or MIDI moves abruptly. Value type; call `set` from the audio thread each sample.
struct Smoother {
    private(set) var value: Float
    var target: Float
    private var coef: Float = 0.999

    init(_ v: Float = 0) { value = v; target = v }
    mutating func prepare(sampleRate: Double, ms: Float = 5) { coef = expf(-1 / (ms / 1000 * Float(sampleRate))) }
    mutating func snap() { value = target }
    @inline(__always) mutating func next() -> Float { value += (target - value) * (1 - coef); return value }
    /// True when the smoother is settled — lets a block take a cheaper constant-gain path.
    var settled: Bool { abs(target - value) < 1e-6 }
}

/// Noise gate / downward expander — hysteresis (opens at `threshold`, closes 6 dB lower), a hold
/// time so sustained notes never chatter, a `range` floor (how far the gate attenuates — a soft
/// expander at −20 dB, a hard mute at −90 dB), and sample-rate-correct attack/release. The detector
/// is high-passed so pick thumps / hum don't pump the gate.
final class GateBlock: AudioBlock {
    var thresholdDb: Float = -40 { didSet { updateCoefs() } }
    var releaseMs: Float = 80 { didSet { updateCoefs() } }
    var rangeDb: Float = -80 { didSet { updateCoefs() } }
    var holdMs: Float = 40 { didSet { updateCoefs() } }

    private var sr: Float = 48000
    private var openThr: Float = 0.01, closeThr: Float = 0.005, floorGain: Float = 0
    private var detAtk: Float = 0.9, detRel: Float = 0.999
    private var gAtk: Float = 0.9, gRel: Float = 0.999
    private var holdSamples = 2000
    private var detHP: Float = 0.99
    private var env: Float = 0, g: Float = 0, hpX1: Float = 0, hpY1: Float = 0
    private var holdCount = 0
    private var open = false

    init() { super.init(kind: .gate) }
    override func prepare(sampleRate: Double, maxBlock: Int) { sr = Float(sampleRate); updateCoefs() }
    override func reset() { env = 0; g = 0; hpX1 = 0; hpY1 = 0; holdCount = 0; open = false }

    private func updateCoefs() {
        openThr = powf(10, thresholdDb / 20)
        closeThr = powf(10, (thresholdDb - 6) / 20)
        floorGain = powf(10, min(rangeDb, 0) / 20)
        detAtk = expf(-1 / (0.0005 * sr))                       // 0.5 ms detector attack
        detRel = expf(-1 / (0.020 * sr))                        // 20 ms detector release
        gAtk = expf(-1 / (0.0015 * sr))                         // 1.5 ms gate open
        gRel = expf(-1 / (max(5, releaseMs) / 1000 * sr))
        holdSamples = Int(max(0, holdMs) / 1000 * sr)
        detHP = expf(-2 * Float.pi * 120 / sr)                  // 120 Hz sidechain high-pass
    }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        var e = env, gg = g, x1 = hpX1, y1 = hpY1, hc = holdCount, isOpen = open
        let oT = openThr, cT = closeThr, fl = floorGain
        let dA = detAtk, dR = detRel, gA = gAtk, gR = gRel, hp = detHP, hold = holdSamples
        for i in 0..<n {
            let x = s[i]
            let y = x - x1 + hp * y1; x1 = x; y1 = y                       // sidechain HPF
            let a = abs(y)
            e = a > e ? dA * e + (1 - dA) * a : dR * e + (1 - dR) * a
            if e > oT { isOpen = true; hc = hold }
            else if isOpen && e < cT { if hc > 0 { hc -= 1 } else { isOpen = false } }
            let target: Float = isOpen ? 1 : fl
            gg = target > gg ? gA * gg + (1 - gA) * target : gR * gg + (1 - gR) * target
            s[i] = x * gg
        }
        env = e; g = gg; hpX1 = x1; hpY1 = y1; holdCount = hc; open = isOpen
    }
}

/// Amp — drives the input into a NAM model, then DC-blocks + level-matches the output.
/// The input is rumble-filtered (30 Hz, 2nd order) before the network — high-gain captures
/// amplify sub-bass thumps and mains hum into audible mud/noise otherwise. Both gains are smoothed.
final class AmpBlock: AudioBlock {
    // Model swap is RT-safe: the audio thread reads a raw pointer atomically and NEVER does ARC on
    // it, so it can't race the main thread's release of an old model. `keepAlive` (main-thread-only)
    // retains the current + recent models so none is freed while possibly in-flight.
    private let modelPtr = Atomic<UInt>(0)
    private var keepAlive: [NAMModel] = []
    var inputGain: Float = 1 { didSet { inSm.target = inputGain } }
    var makeupGain: Float = 1 { didSet { mkSm.target = makeupGain } }
    private var inSm = Smoother(1), mkSm = Smoother(1)
    private var preHP = Biquad()
    private var dcX1: Float = 0
    private var dcY1: Float = 0

    override init(kind: BlockKind = .amp) { super.init(kind: kind) }

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
        inSm.prepare(sampleRate: sampleRate, ms: 8); mkSm.prepare(sampleRate: sampleRate, ms: 20)
        inSm.snap(); mkSm.snap()
        preHP.setHighpass(freq: 30, q: 0.707, sr: Float(sampleRate))
    }

    override func reset() { dcX1 = 0; dcY1 = 0; preHP.reset(); inSm.snap(); mkSm.snap() }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n { s[i] = preHP.process(s[i]) * inSm.next() }

        // Use the model pointer WITHOUT ARC — it stays alive via `keepAlive`, so no use-after-free on swap.
        let p = modelPtr.load(ordering: .acquiring)
        if p != 0, let raw = UnsafeRawPointer(bitPattern: p) {
            Unmanaged<NAMModel>.fromOpaque(raw).takeUnretainedValue().process(input: s, output: s, frames: Int32(n))
        }

        // DC blocker (~19 Hz one-pole high-pass) + smoothed makeup, in one pass.
        var x1 = dcX1, y1 = dcY1
        for i in 0..<n {
            let x = s[i].isFinite ? s[i] : 0
            let y = x - x1 + 0.9975 * y1
            x1 = x; y1 = y
            s[i] = y * mkSm.next()
        }
        dcX1 = x1; dcY1 = y1
    }
}

/// Cab IR — standalone post-amp convolution block (extracted from AmpBlock so "Cab" is its own
/// reorderable chain block). 2048-tap mono IR via vDSP overlap; RT-safe data-copy swap.
nonisolated final class CabBlock: AudioBlock {
    private let maxIR = 2048
    private var maxBlk = 4096
    private var irRev: UnsafeMutableBufferPointer<Float>?
    private var irHist: UnsafeMutableBufferPointer<Float>?
    private var irScratch: UnsafeMutableBufferPointer<Float>?
    private var irLen = 0
    private let irOn = Atomic<Bool>(false)

    override init(kind: BlockKind = .cab) { super.init(kind: kind) }

    override func prepare(sampleRate: Double, maxBlock: Int) {
        maxBlk = max(maxBlock, 1)
        if irRev == nil {
            irRev = .allocate(capacity: maxIR); irRev!.initialize(repeating: 0)
            irHist = .allocate(capacity: maxIR); irHist!.initialize(repeating: 0)
            irScratch = .allocate(capacity: maxIR + maxBlk); irScratch!.initialize(repeating: 0)
        }
    }
    override func reset() { if let h = irHist?.baseAddress { for i in 0..<maxIR { h[i] = 0 } } }

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
        guard irOn.load(ordering: .acquiring), irLen > 1, n <= maxBlk,
              let rev = irRev?.baseAddress, let h = irHist?.baseAddress, let scr = irScratch?.baseAddress else { return }
        let need = irLen - 1
        memcpy(scr, h, need * MemoryLayout<Float>.size)
        memcpy(scr + need, s, n * MemoryLayout<Float>.size)
        vDSP_conv(scr, 1, rev, 1, s, 1, vDSP_Length(n), vDSP_Length(irLen))
        memcpy(h, scr + n, need * MemoryLayout<Float>.size)
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

    /// Pure delay the oversampler adds, in base-rate samples (nearest integer of (N−1)/factor).
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

/// 4-point Hermite interpolation — smooth fractional delay reads (no linear-interp HF dulling / zipper).
@inline(__always) nonisolated func hermite(_ xm1: Float, _ x0: Float, _ x1: Float, _ x2: Float, _ t: Float) -> Float {
    let c = (x1 - xm1) * 0.5
    let v = x0 - x1
    let w = c + v
    let a = w + v + (x2 - x0) * 0.5
    let b = w + a
    return ((a * t - b) * t + c) * t + x0
}

/// Feedback delay — tape-style. Time changes glide (pitch-bend, never click), the feedback loop is
/// darkened by `tone` (one-pole low-pass) + high-passed (no low-end build-up) + soft-saturated so
/// repeats decay musically instead of piling up harshly. Hermite fractional read.
final class DelayBlock: AudioBlock {
    private var buf: UnsafeMutableBufferPointer<Float>?
    private var cap = 0
    private var w = 0
    var delaySamples = 16800 { didSet { timeSm.target = Float(delaySamples) } }
    var feedback: Float = 0.35
    var mix: Float = 0.30 { didSet { mixSm.target = mix } }
    var tone: Float = 0.6 { didSet { updateTone() } }   // 0 dark … 1 bright
    private var timeSm = Smoother(16800), mixSm = Smoother(0.3)
    private var sr: Float = 48000
    private var lpCoef: Float = 0.5, hpCoef: Float = 0.99
    private var lpState: Float = 0, hpX1: Float = 0, hpY1: Float = 0

    init() { super.init(kind: .delay) }

    override func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate)
        let need = Int(sampleRate * 2) + 8     // up to 2 s
        if buf == nil || cap != need {
            buf?.deallocate()
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: need)
            b.initialize(repeating: 0)
            buf = b; cap = need
        }
        w = 0
        timeSm.prepare(sampleRate: sampleRate, ms: 60); timeSm.snap()
        mixSm.prepare(sampleRate: sampleRate, ms: 10); mixSm.snap()
        hpCoef = expf(-2 * Float.pi * 110 / sr)
        updateTone()
    }
    private func updateTone() {
        let fc = 1200 * powf(10, min(max(tone, 0), 1))        // 1.2 kHz … 12 kHz
        lpCoef = 1 - expf(-2 * Float.pi * fc / sr)
    }

    override func reset() {
        if let base = buf?.baseAddress { for i in 0..<cap { base[i] = 0 } }
        w = 0; lpState = 0; hpX1 = 0; hpY1 = 0; timeSm.snap(); mixSm.snap()
    }
    /// Jump to the new time immediately (preset change) instead of tape-gliding through the tail.
    func snapTime() { timeSm.snap() }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard let base = buf?.baseAddress, cap > 8 else { return }
        let fb = min(feedback, 1.1), lp = lpCoef, hp = hpCoef, maxD = Float(cap - 4)
        var wi = w, ls = lpState, x1 = hpX1, y1 = hpY1
        for i in 0..<n {
            let d = min(max(2, timeSm.next()), maxD)
            let rd = Float(wi) - d
            var r0 = Int(rd.rounded(.down)); let t = rd - Float(r0)
            r0 = ((r0 % cap) + cap) % cap
            let rm1 = r0 == 0 ? cap - 1 : r0 - 1
            let r1 = r0 + 1 == cap ? 0 : r0 + 1
            let r2 = r1 + 1 == cap ? 0 : r1 + 1
            let echo = hermite(base[rm1], base[r0], base[r1], base[r2], t)
            // Feedback conditioning: low-pass (tone) → high-pass → soft clip.
            ls += lp * (echo - ls)
            let hpv = ls - x1 + hp * y1; x1 = ls; y1 = hpv
            let fbv = tanhf(hpv * fb)
            let dry = s[i]
            base[wi] = dry + fbv
            s[i] = dry + echo * mixSm.next()
            wi += 1; if wi >= cap { wi = 0 }
        }
        w = wi; lpState = ls; hpX1 = x1; hpY1 = y1
    }

    deinit { buf?.deallocate() }
}

/// Freeverb-style reverb — 8 parallel comb filters → 4 series allpass. Mono.
/// Reverb — delegates to one of four genuinely-different algorithms (see ReverbAlgorithms.swift),
/// selected by `algo`: 0 room → FDN .room · 1 plate → Dattorro · 2 spring → SpringReverb · 3 hall → FDN .hall.
/// Each engine works in place and applies its own wet/dry `mix`. Switching `algo` is glitch-light
/// (not crossfaded) — change type while the tail is quiet.
final class ReverbBlock: AudioBlock {
    private let plate = DattorroPlate()
    private let spring = SpringReverb()
    private let fdn = FDNReverb()
    private let algo = Atomic<Int>(3)   // 0 room · 1 plate · 2 spring · 3 hall

    init() { super.init(kind: .reverb) }

    override func prepare(sampleRate: Double, maxBlock: Int) {
        plate.prepare(sampleRate: sampleRate, maxBlock: maxBlock)
        spring.prepare(sampleRate: sampleRate, maxBlock: maxBlock)
        fdn.prepare(sampleRate: sampleRate, maxBlock: maxBlock)
    }

    override func reset() { plate.reset(); spring.reset(); fdn.reset() }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        switch algo.load(ordering: .relaxed) {
        case 1: plate.process(s, n)
        case 2: spring.process(s, n)
        default: fdn.process(s, n)          // room/hall via fdn.mode, set in configure(_:)
        }
    }

    /// Map the user knobs (0…100) onto the selected algorithm's natural params. Main-thread only.
    func configure(type: Int, decayPct: Double, dampPct: Double, mixPct: Double) {
        let dec = Float(decayPct / 100), dmp = Float(dampPct / 100), mx = Float(mixPct / 100)
        plate.mix = mx; spring.mix = mx; fdn.mix = mx
        switch type {
        case 1:                              // plate
            plate.decay = 0.4 + dec * 0.55
            plate.damp  = dmp * 0.5
        case 2:                              // spring
            spring.decay = 0.5 + dec * 0.38
            spring.tone  = 1 - dmp
        case 3:                              // hall
            fdn.mode = .hall
            fdn.decay = 1.5 + dec * 4.5
            fdn.hfDamp = dmp
        default:                             // room
            fdn.mode = .room
            fdn.decay = 0.3 + dec * 1.2
            fdn.hfDamp = dmp
        }
        algo.store(type, ordering: .relaxed)
    }
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

/// Feed-forward compressor with a 6 dB soft knee. The gain computer runs in the log domain and
/// the attack/release smooth the GAIN REDUCTION (not the raw peak), which is what makes studio
/// compressors feel transparent on a guitar instead of pumping. `gainReductionDb` is exposed for metering.
final class CompressorBlock: AudioBlock {
    var thresholdDb: Float = -18
    var ratio: Float = 4
    var makeup: Float = 1 { didSet { mkSm.target = makeup } }
    private(set) var gainReductionDb: Float = 0
    private let kneeDb: Float = 6
    private var attackCoef: Float = 0.998
    private var releaseCoef: Float = 0.9998
    private var detRel: Float = 0.9995
    private var env: Float = 0
    private var grDb: Float = 0
    private var mkSm = Smoother(1)
    private var sr: Float = 48000
    private var atkMs: Float = 10, relMs: Float = 120

    init() { super.init(kind: .comp) }
    override func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate); updateTimes()
        mkSm.prepare(sampleRate: sampleRate, ms: 10); mkSm.snap()
    }
    override func reset() { env = 0; grDb = 0; gainReductionDb = 0; mkSm.snap() }

    func setTimes(attackMs: Float, releaseMs: Float) { atkMs = attackMs; relMs = releaseMs; updateTimes() }
    private func updateTimes() {
        attackCoef = expf(-1 / max(1, atkMs / 1000 * sr))
        releaseCoef = expf(-1 / max(1, relMs / 1000 * sr))
        detRel = expf(-1 / (0.008 * sr))     // 8 ms peak-hold so the gain computer sees the waveform's level, not its ripple
    }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        let thr = thresholdDb, r = max(1, ratio), k = kneeDb, halfK = kneeDb * 0.5
        let aC = attackCoef, rC = releaseCoef, dR = detRel
        var gr = grDb, e = env
        for i in 0..<n {
            let x = abs(s[i])
            e = x > e ? x : e * dR                                                     // peak detector
            let xDb = 20 * log10f(e > 1e-7 ? e : 1e-7)
            let over = xDb - thr
            let want: Float
            if over <= -halfK { want = 0 }
            else if over >= halfK { want = -over * (1 - 1 / r) }
            else { let t = over + halfK; want = -(1 - 1 / r) * t * t / (2 * k) }      // soft knee
            gr = want < gr ? aC * gr + (1 - aC) * want : rC * gr + (1 - rC) * want    // smooth the GR
            s[i] *= powf(10, gr / 20) * mkSm.next()
        }
        grDb = gr; env = e; gainReductionDb = gr
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

/// Clean boost — transparent, smoothed gain (no clipping/coloration). Goes anywhere in the chain.
final class BoostBlock: AudioBlock {
    var gain: Float = 1 { didSet { sm.target = gain } }
    private var sm = Smoother(1)
    init() { super.init(kind: .boost) }
    override func prepare(sampleRate: Double, maxBlock: Int) { sm.prepare(sampleRate: sampleRate, ms: 8); sm.snap() }
    override func reset() { sm.snap() }
    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        if sm.settled { let g = sm.value; if g != 1 { for i in 0..<n { s[i] *= g } } }
        else { for i in 0..<n { s[i] *= sm.next() } }
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

/// Hermite read at fractional delay `d` samples behind write index `wi` in a ring of `cap`.
@inline(__always) nonisolated func ringReadHermite(_ base: UnsafeMutablePointer<Float>, _ cap: Int, _ wi: Int, _ d: Float) -> Float {
    let rd = Float(wi) - d
    var r0 = Int(rd.rounded(.down)); let t = rd - Float(r0)
    r0 = ((r0 % cap) + cap) % cap
    let rm1 = r0 == 0 ? cap - 1 : r0 - 1
    let r1 = r0 + 1 == cap ? 0 : r0 + 1
    let r2 = r1 + 1 == cap ? 0 : r1 + 1
    return hermite(base[rm1], base[r0], base[r1], base[r2], t)
}

/// Chorus — two modulated voices (LFOs 180° apart, the second slightly shallower) summed with dry,
/// Hermite fractional reads, and a 150 Hz high-pass on the wet path so the low end stays tight.
/// Two anti-phase voices cancel the "pitch wobble" of a single-voice chorus → lush, not seasick.
final class ChorusBlock: AudioBlock {
    var rateHz: Float = 0.8
    var depthMs: Float = 6
    var mix: Float = 0.4 { didSet { mixSm.target = mix } }
    private var mixSm = Smoother(0.4)
    private var sr: Float = 48000
    private var buf: UnsafeMutableBufferPointer<Float>?
    private var cap = 0, w = 0
    private var phase: Float = 0
    private var hpCoef: Float = 0.98, hpX1: Float = 0, hpY1: Float = 0
    private let baseMs: Float = 14
    init() { super.init(kind: .chorus) }
    override func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate)
        let need = Int(sampleRate * 0.06) + 8
        if buf == nil || cap != need { buf?.deallocate(); let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: need); b.initialize(repeating: 0); buf = b; cap = need }
        w = 0
        hpCoef = expf(-2 * Float.pi * 150 / sr)
        mixSm.prepare(sampleRate: sampleRate, ms: 10); mixSm.snap()
    }
    override func reset() { if let p = buf?.baseAddress { for i in 0..<cap { p[i] = 0 } }; w = 0; phase = 0; hpX1 = 0; hpY1 = 0; mixSm.snap() }
    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard let base = buf?.baseAddress, cap > 8 else { return }
        let inc = 2 * Float.pi * rateHz / sr, hp = hpCoef
        let baseS = baseMs / 1000 * sr, depthS = depthMs / 1000 * sr
        var ph = phase, wi = w, x1 = hpX1, y1 = hpY1
        for i in 0..<n {
            let dry = s[i]
            base[wi] = dry
            let l1 = 0.5 * (1 - cosf(ph)), l2 = 0.5 * (1 + cosf(ph))
            let v1 = ringReadHermite(base, cap, wi, baseS + depthS * l1)
            let v2 = ringReadHermite(base, cap, wi, baseS * 0.8 + depthS * 0.7 * l2)
            let wetRaw = (v1 + v2) * 0.5
            let wet = wetRaw - x1 + hp * y1; x1 = wetRaw; y1 = wet
            let mx = mixSm.next()
            s[i] = dry * (1 - mx * 0.5) + wet * mx
            wi += 1; if wi >= cap { wi = 0 }
            ph += inc; if ph > 2 * Float.pi { ph -= 2 * Float.pi }
        }
        phase = ph; w = wi; hpX1 = x1; hpY1 = y1
    }
    deinit { buf?.deallocate() }
}

/// Flanger — short LFO-modulated delay with regeneration. Feedback is tanh-limited (never runs away
/// at 95 %) and high-passed (no bass boom in the jet), Hermite fractional reads, triangle-ish LFO.
final class FlangerBlock: AudioBlock {
    var rateHz: Float = 0.4
    var depthMs: Float = 2
    var feedback: Float = 0.5
    var mix: Float = 0.5 { didSet { mixSm.target = mix } }
    private var mixSm = Smoother(0.5)
    private var sr: Float = 48000
    private var buf: UnsafeMutableBufferPointer<Float>?
    private var cap = 0, w = 0
    private var phase: Float = 0
    private var hpCoef: Float = 0.98, hpX1: Float = 0, hpY1: Float = 0
    private let baseMs: Float = 0.6
    init() { super.init(kind: .flanger) }
    override func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate)
        let need = Int(sampleRate * 0.03) + 8
        if buf == nil || cap != need { buf?.deallocate(); let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: need); b.initialize(repeating: 0); buf = b; cap = need }
        w = 0
        hpCoef = expf(-2 * Float.pi * 90 / sr)
        mixSm.prepare(sampleRate: sampleRate, ms: 10); mixSm.snap()
    }
    override func reset() { if let p = buf?.baseAddress { for i in 0..<cap { p[i] = 0 } }; w = 0; phase = 0; hpX1 = 0; hpY1 = 0; mixSm.snap() }
    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard let base = buf?.baseAddress, cap > 8 else { return }
        let inc = 2 * Float.pi * rateHz / sr, fb = min(feedback, 0.98), hp = hpCoef
        let baseS = baseMs / 1000 * sr, depthS = depthMs / 1000 * sr
        var ph = phase, wi = w, x1 = hpX1, y1 = hpY1
        for i in 0..<n {
            let dry = s[i]
            // Sine-shaped-triangle LFO: perceptually even sweep across the log-frequency comb.
            let tri = abs(ph / Float.pi - 1)                        // 1 → 0 → 1
            let lfo = 0.5 * (1 - cosf(Float.pi * tri))
            let wet = ringReadHermite(base, cap, wi, baseS + depthS * lfo)
            let fbHP = wet - x1 + hp * y1; x1 = wet; y1 = fbHP
            base[wi] = dry + tanhf(fbHP * fb)
            let mx = mixSm.next()
            s[i] = dry * (1 - mx) + wet * mx
            wi += 1; if wi >= cap { wi = 0 }
            ph += inc; if ph > 2 * Float.pi { ph -= 2 * Float.pi }
        }
        phase = ph; w = wi; hpX1 = x1; hpY1 = y1
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
