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
    var model: NAMModel?
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

        if let m = model { m.process(input: s, output: s, frames: Int32(n)) }

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

/// Overdrive / boost — gain → tanh soft-clip → tone (high-cut) → level.
final class DriveBlock: AudioBlock {
    var drive: Float = 1
    var level: Float = 1
    var mode: Int = 0           // 0 soft (tanh), 1 hard clip, 2 fuzz (asymmetric)
    private var toneCoef: Float = 0.3
    private var toneState: Float = 0
    private var sr: Float = 48000
    private var toneHz: Float = 4000

    init() { super.init(kind: .drive) }
    override func prepare(sampleRate: Double, maxBlock: Int) { sr = Float(sampleRate); updateTone() }
    override func reset() { toneState = 0 }

    func setTone(hz: Float) { toneHz = hz; updateTone() }
    private func updateTone() {
        let fc = min(max(toneHz, 100), sr / 2 - 100)
        toneCoef = 1 - expf(-2 * Float.pi * fc / sr)
    }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        let d = drive, lv = level, tc = toneCoef
        var ts = toneState
        switch mode {
        case 1:   // hard clip
            for i in 0..<n { let x = max(-1, min(1, s[i] * d)); ts += tc * (x - ts); s[i] = ts * lv }
        case 2:   // fuzz — asymmetric soft clip
            for i in 0..<n { let v = s[i] * d; let x = v >= 0 ? tanhf(v) : 0.8 * tanhf(0.7 * v); ts += tc * (x - ts); s[i] = ts * lv }
        default:  // soft tanh
            for i in 0..<n { let x = tanhf(s[i] * d); ts += tc * (x - ts); s[i] = ts * lv }
        }
        toneState = ts
    }
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
