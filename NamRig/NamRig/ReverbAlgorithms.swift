//
//  ReverbAlgorithms.swift
//  NamRig — real, genuinely-different reverb ENGINES (room/plate/spring/hall).
//
//  These are plain mono-in/mono-out DSP engines (NOT AudioBlock subclasses). The chain's
//  existing `ReverbBlock` is meant to hold ONE instance of each and delegate prepare/reset/process
//  to whichever the `algo`/`type` knob selects (see the integration plan in the PR notes):
//      0 room  -> FDNReverb(mode:.room)
//      1 plate -> DattorroPlate
//      2 spring-> SpringReverb
//      3 hall  -> FDNReverb(mode:.hall)
//
//  Every engine:
//    * `prepare(sampleRate:maxBlock:)` pre-allocates ALL delay buffers (zero alloc / locks in process).
//    * `reset()` zeros state.
//    * `process(_:_)` works in place, dry -> wet, using an internal `mix` (0 dry … 1 wet).
//    * params are plain `var`s (benign races, exactly like the other Blocks.swift knobs).
//
//  RT-safety: denormal flush (`flush`) on EVERY recursive comb / allpass / FDN line — multi-second
//  tails would otherwise stall the audio thread with subnormal arithmetic.
//
//  These three classes are duplicated verbatim into tools/reverb_algo_test.swift for headless
//  verification (that harness builds standalone and cannot import the app target).
//

import Foundation
import Accelerate

// ============================================================================================
//  Shared primitives (fileprivate so they don't collide with the rest of the app target)
// ============================================================================================

/// Denormal flush — kill subnormals on recursive lines so long tails don't stall the FPU.
@inline(__always) nonisolated fileprivate func flush(_ x: Float) -> Float { abs(x) < 1e-18 ? 0 : x }

/// A circular delay line with integer and fractional (linear-interpolated) reads. Capacity is
/// allocated once; reads/writes are branch-light and allocation-free. `push` writes the newest
/// sample; `tapInt(d)` returns the sample written `d` steps ago (d ≥ 1), `tapFrac` interpolates.
fileprivate nonisolated final class DL {
    let buf: UnsafeMutableBufferPointer<Float>
    let cap: Int
    var w = 0
    init(_ maxLen: Int) {
        cap = max(4, maxLen)
        buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        buf.initialize(repeating: 0)
    }
    func clear() { for i in 0..<cap { buf[i] = 0 }; w = 0 }
    func free() { buf.deallocate() }

    @inline(__always) func push(_ x: Float) {
        buf[w] = x; w &+= 1; if w >= cap { w = 0 }
    }
    @inline(__always) func tapInt(_ d: Int) -> Float {
        var r = w - d; if r < 0 { r += cap }
        return buf[r]
    }
    @inline(__always) func tapFrac(_ d: Float) -> Float {
        let di = Int(d), f = d - Float(di)
        var r0 = w - di;     if r0 < 0 { r0 += cap }
        var r1 = r0 - 1;     if r1 < 0 { r1 += cap }
        return buf[r0] * (1 - f) + buf[r1] * f
    }
}

@inline(__always) nonisolated fileprivate func clampOff(_ v: Float, _ maxv: Int) -> Int {
    let i = Int(v); return i < 1 ? 1 : (i > maxv ? maxv : i)
}

// ============================================================================================
//  DattorroPlate — Dattorro 1997 figure-8 allpass-tank plate reverb.
//
//  input -> predelay -> bandwidth LP -> 4 input diffusers (142/107/379/277) -> figure-8 tank.
//  The tank is two coupled halves; each half is [modulated allpass -> delay -> damping LP ->
//  allpass -> delay], cross-coupled with `decay`. The FIRST tank allpass of each half is
//  LFO-modulated (mandatory — a static tank rings metallic). The wet signal is the canonical
//  7-tap read from the tank delay lines, collapsed L+R -> mono. All lengths scale by fs/29761.
// ============================================================================================
nonisolated final class DattorroPlate: @unchecked Sendable {
    // ---- params (plain vars) ----
    var predelayMs: Float = 0       // 0…200 ms
    var decay:      Float = 0.5     // tank feedback 0…~0.95 (tail length)
    var damp:       Float = 0.0005  // tone 0 (bright) … ~0.9 (dark)
    var size:       Float = 1       // 0.5…2 plate-size scaler on all delays + taps
    var mod:        Float = 1       // 0…1 LFO excursion (chorus that de-metallises the tank)
    var mix:        Float = 0.3     // 0 dry … 1 wet

    private let baseFs: Float = 29761
    private var fs: Float = 48000
    private var prepared = false

    // Schroeder allpass diffusion gains (Dattorro).
    private let inDiff1: Float = 0.75, inDiff2: Float = 0.625
    private let decDiff1: Float = 0.70                         // first tank allpass (modulated, negated)

    // Base lengths @29761 Hz.
    private let lPre = 0
    private let lDif = [142, 107, 379, 277]                    // input diffusers
    private let lApL1 = 672, lDlL1 = 4453, lApL2 = 1801, lDlL2 = 3720   // left half
    private let lApR1 = 908, lDlR1 = 4217, lApR2 = 2656, lDlR2 = 3163   // right half

    // Buffers.
    private var pd: DL!
    private var dif: [DL] = []
    private var apL1, dlL1, apL2, dlL2: DL!
    private var apR1, dlR1, apR2, dlR2: DL!

    // State.
    private var bwState: Float = 0
    private var dampL: Float = 0, dampR: Float = 0
    private var tailL: Float = 0, tailR: Float = 0
    private var lfo: Float = 0

    private let maxSize: Float = 2.0
    private let maxExc: Float = 24

    func prepare(sampleRate: Double, maxBlock: Int) {
        fs = Float(sampleRate)
        free()
        let sc = fs / baseFs
        func cap(_ baseLen: Int, mod: Bool = false) -> Int {
            Int(Float(baseLen) * sc * maxSize) + (mod ? Int(maxExc) : 0) + 8
        }
        pd = DL(Int(0.2 * fs) + 8)
        dif = lDif.map { DL(cap($0)) }
        apL1 = DL(cap(lApL1, mod: true)); dlL1 = DL(cap(lDlL1)); apL2 = DL(cap(lApL2)); dlL2 = DL(cap(lDlL2))
        apR1 = DL(cap(lApR1, mod: true)); dlR1 = DL(cap(lDlR1)); apR2 = DL(cap(lApR2)); dlR2 = DL(cap(lDlR2))
        prepared = true
        reset()
    }

    func reset() {
        guard prepared else { return }
        pd.clear(); for d in dif { d.clear() }
        apL1.clear(); dlL1.clear(); apL2.clear(); dlL2.clear()
        apR1.clear(); dlR1.clear(); apR2.clear(); dlR2.clear()
        bwState = 0; dampL = 0; dampR = 0; tailL = 0; tailR = 0; lfo = 0
    }

    private func free() {
        pd?.free(); for d in dif { d.free() }; dif = []
        apL1?.free(); dlL1?.free(); apL2?.free(); dlL2?.free()
        apR1?.free(); dlR1?.free(); apR2?.free(); dlR2?.free()
    }
    deinit { free() }

    /// Schroeder allpass step on a delay line `dl` of length `len` (fractional), gain `g`.
    @inline(__always) private func ap(_ dl: DL, _ x: Float, _ len: Float, _ g: Float) -> Float {
        let delayed = dl.tapFrac(len)
        let wn = flush(x - g * delayed)
        dl.push(wn)
        return g * wn + delayed
    }
    @inline(__always) private func apI(_ dl: DL, _ x: Float, _ len: Int, _ g: Float) -> Float {
        let delayed = dl.tapInt(len)
        let wn = flush(x - g * delayed)
        dl.push(wn)
        return g * wn + delayed
    }

    func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard prepared, n > 0 else { return }
        let sc = (fs / baseFs) * min(max(size, 0.5), maxSize)
        let dec = min(max(decay, 0), 0.97)
        let dmp = min(max(damp, 0), 0.95)
        let bw  = min(max(1 - dmp, 0.2), 0.9995)                 // input bandwidth (bright→1)
        let dd2 = min(max(dec + 0.15, 0.25), 0.50)               // decay diffusion 2 (Dattorro)
        let pdS = clampOff(Float(max(0, predelayMs)) / 1000 * fs, pd.cap - 2)
        let exc = min(max(mod, 0), 1) * maxExc * (fs / baseFs)
        let lfoInc = 2 * Float.pi * 0.7 / fs                     // ~0.7 Hz tank chorus

        // Scaled tank lengths.
        let nDif = lDif.map { clampOff(Float($0) * sc, 1 << 28) }
        let nApL1 = Float(lApL1) * sc, nApR1 = Float(lApR1) * sc
        let nDlL1 = clampOff(Float(lDlL1) * sc, dlL1.cap - 2)
        let nApL2 = clampOff(Float(lApL2) * sc, apL2.cap - 2)
        let nDlL2 = clampOff(Float(lDlL2) * sc, dlL2.cap - 2)
        let nDlR1 = clampOff(Float(lDlR1) * sc, dlR1.cap - 2)
        let nApR2 = clampOff(Float(lApR2) * sc, apR2.cap - 2)
        let nDlR2 = clampOff(Float(lDlR2) * sc, dlR2.cap - 2)

        // Scaled output tap offsets (clamped into each buffer).
        @inline(__always) func off(_ v: Int, _ dl: DL) -> Int { clampOff(Float(v) * sc, dl.cap - 2) }
        let a = dlL1!, b = apL2!, c = dlL2!, d = dlR1!, e = apR2!, f = dlR2!
        let yld = (off(266, d), off(2974, d)), yle = off(1913, e), ylf = off(1996, f)
        let yla = off(1990, a), ylb = off(187, b), ylc = off(1066, c)
        let yra = (off(353, a), off(3627, a)), yrb = off(1228, b), yrc = off(2673, c)
        let yrd = off(2111, d), yre = off(335, e), yrf = off(121, f)

        for i in 0..<n {
            let dry = s[i]
            pd.push(dry)
            var x = pd.tapInt(pdS)

            // Input bandwidth one-pole LP.
            bwState = flush(bw * x + (1 - bw) * bwState); x = bwState

            // 4 series input diffusers.
            x = apI(dif[0], x, nDif[0], inDiff1)
            x = apI(dif[1], x, nDif[1], inDiff1)
            x = apI(dif[2], x, nDif[2], inDiff2)
            x = apI(dif[3], x, nDif[3], inDiff2)

            // LFO (sine) for the two modulated tank allpasses.
            let s1 = sinf(lfo), s2 = sinf(lfo + 1.5)
            lfo += lfoInc; if lfo > 2 * Float.pi { lfo -= 2 * Float.pi }
            let lenL1 = max(2, nApL1 + exc * s1)
            let lenR1 = max(2, nApR1 + exc * s2)

            // ---- Left half: in = diffused + decay·tailR ----
            var nL = flush(x + dec * tailR)
            nL = ap(apL1, nL, lenL1, -decDiff1)        // modulated allpass (MUST modulate)
            dlL1.push(flush(nL)); nL = dlL1.tapInt(nDlL1)
            dampL = flush((1 - dmp) * nL + dmp * dampL); nL = dampL
            nL = apI(apL2, nL, nApL2, dd2)
            dlL2.push(flush(nL)); nL = dlL2.tapInt(nDlL2)
            let newTailL = nL

            // ---- Right half: in = diffused + decay·tailL ----
            var nR = flush(x + dec * tailL)
            nR = ap(apR1, nR, lenR1, -decDiff1)        // modulated allpass
            dlR1.push(flush(nR)); nR = dlR1.tapInt(nDlR1)
            dampR = flush((1 - dmp) * nR + dmp * dampR); nR = dampR
            nR = apI(apR2, nR, nApR2, dd2)
            dlR2.push(flush(nR)); nR = dlR2.tapInt(nDlR2)
            let newTailR = nR

            tailL = newTailL; tailR = newTailR

            // 7-tap canonical read per channel, collapse to mono.
            let left =  0.6 * d.tapInt(yld.0) + 0.6 * d.tapInt(yld.1) - 0.6 * e.tapInt(yle)
                      + 0.6 * f.tapInt(ylf)  - 0.6 * a.tapInt(yla)   - 0.6 * b.tapInt(ylb) - 0.6 * c.tapInt(ylc)
            let right = 0.6 * a.tapInt(yra.0) + 0.6 * a.tapInt(yra.1) - 0.6 * b.tapInt(yrb)
                      + 0.6 * c.tapInt(yrc)  - 0.6 * d.tapInt(yrd)   - 0.6 * e.tapInt(yre) - 0.6 * f.tapInt(yrf)
            let wet = 0.5 * (left + right)

            s[i] = dry * (1 - mix) + wet * mix
        }
    }
}

// ============================================================================================
//  SpringReverb — dispersive helical-spring model.
//
//  HP ~80 Hz -> 2..3 detuned springs in parallel. Each spring is a feedback loop containing a
//  cascade of ~90 first-order dispersion allpasses (|a|~0.6, NEGATIVE a so group delay DECREASES
//  with frequency = the descending "boing" chirp) + a damping LP (~tone) + a loop delay (30–55 ms)
//  + a `decay` (0.6–0.85) + a light tanh "clank". Loop gain stays < 1 (the cascade is unity-gain
//  allpass, the LP is DC-unity, tanh is compressive) so it never blows up.
// ============================================================================================
nonisolated final class SpringReverb: @unchecked Sendable {
    // ---- params ----
    var decay:   Float = 0.72   // loop feedback 0.5…0.88
    var tension: Float = 0.6    // dispersion |a| 0.3…0.85 (chirp steepness)
    var springs: Int   = 3      // 1…3
    var tone:    Float = 0.5    // 0 dark … 1 bright (loop LP cutoff)
    var mix:     Float = 0.3

    private var fs: Float = 48000
    private var prepared = false
    private let nAP = 90                                   // dispersion allpasses per spring
    private let maxSprings = 3
    private let loopMs: [Float] = [37.0, 43.7, 52.1]       // detuned loop delays
    private let detune: [Float] = [1.0, 0.97, 1.04]        // per-spring |a| detune

    private var apX: [UnsafeMutableBufferPointer<Float>] = []   // [spring] x[k-1]
    private var apY: [UnsafeMutableBufferPointer<Float>] = []   // [spring] y[k-1]
    private var loop: [DL] = []
    private var lpState: [Float] = []
    private var fb: [Float] = []

    private var hpY: Float = 0, hpX: Float = 0

    func prepare(sampleRate: Double, maxBlock: Int) {
        fs = Float(sampleRate)
        free()
        for sgn in 0..<maxSprings {
            let x = UnsafeMutableBufferPointer<Float>.allocate(capacity: nAP); x.initialize(repeating: 0)
            let y = UnsafeMutableBufferPointer<Float>.allocate(capacity: nAP); y.initialize(repeating: 0)
            apX.append(x); apY.append(y)
            loop.append(DL(Int(loopMs[sgn] / 1000 * fs * 1.5) + 8))
            lpState.append(0); fb.append(0)
        }
        prepared = true
        reset()
    }

    func reset() {
        guard prepared else { return }
        for s in 0..<maxSprings {
            for k in 0..<nAP { apX[s][k] = 0; apY[s][k] = 0 }
            loop[s].clear(); lpState[s] = 0; fb[s] = 0
        }
        hpY = 0; hpX = 0
    }

    private func free() {
        for b in apX { b.deallocate() }; for b in apY { b.deallocate() }
        for d in loop { d.free() }
        apX = []; apY = []; loop = []; lpState = []; fb = []
    }
    deinit { free() }

    func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard prepared, n > 0 else { return }
        let nS = min(max(springs, 1), maxSprings)
        let dec = min(max(decay, 0), 0.9)
        let baseA = -min(max(tension, 0.05), 0.88)                       // NEGATIVE → descending chirp
        let fc = 1200 + min(max(tone, 0), 1) * 5000                      // loop LP cutoff
        let lpC = 1 - expf(-2 * Float.pi * min(fc, fs * 0.45) / fs)
        let hpR = 1 - 2 * Float.pi * 80 / fs                             // ~80 Hz one-pole HP
        let loopN = (0..<maxSprings).map { clampOff(loopMs[$0] / 1000 * fs, loop[$0].cap - 2) }
        let aS = (0..<maxSprings).map { max(-0.88, min(-0.05, baseA * detune[$0])) }
        let outScale = 0.7 / Float(nS)

        for i in 0..<n {
            let dry = s[i]
            // input high-pass (remove sub-bass rumble the springs can't carry)
            let hp = flush(dry - hpX + hpR * hpY)
            hpX = dry; hpY = hp

            var wet: Float = 0
            for sp in 0..<nS {
                let a = aS[sp]
                var v = flush(hp + dec * fb[sp])
                let ax = apX[sp].baseAddress!, ay = apY[sp].baseAddress!
                // dispersion: cascade of first-order allpasses  y = a·x + x[-1] − a·y[-1]
                for k in 0..<nAP {
                    let xn = v
                    let yn = a * xn + ax[k] - a * ay[k]
                    ax[k] = xn; ay[k] = flush(yn)
                    v = yn
                }
                // loop damping LP
                lpState[sp] = flush(lpState[sp] + lpC * (v - lpState[sp]))
                v = lpState[sp]
                // loop delay
                loop[sp].push(v)
                var dlt = loop[sp].tapInt(loopN[sp])
                // light tanh "clank"
                dlt = 0.85 * tanhf(dlt * 1.3) + 0.15 * dlt
                fb[sp] = flush(dlt)
                wet += dlt
            }
            wet *= outScale
            s[i] = dry * (1 - mix) + wet * mix
        }
    }
}

// ============================================================================================
//  FDNReverb — 8-line Jot / Stautner-Puckette Feedback Delay Network (ROOM & HALL).
//
//  Mutually-prime delay lines; lossless Householder feedback via the scalar trick
//  s = (2/N)·Σdᵢ = 0.25·Σdᵢ ; outᵢ = dᵢ − s. Per-line Jot decay gᵢ = 10^(−3·Mᵢ/(T60·fs)) gives
//  a uniform, exact T60. Per-line DC-unity one-pole LP makes highs decay faster (frequency-
//  dependent damping). ROOM: small lines + early-reflection FIR taps (7/11/17/23/29/37/43/53 ms,
//  alternating sign) + light modulation + short T60. HALL: big lines + long T60 + heavier HF
//  damping (highs 2–3× faster) + every line modulated + no ERs.
// ============================================================================================
nonisolated final class FDNReverb: @unchecked Sendable {
    nonisolated enum Mode { case room, hall }

    // ---- params ----
    var mode: Mode = .room
    var size:       Float = 1       // 0.5…2 length scaler
    var decay:      Float = 1.5     // T60 seconds
    var hfDamp:     Float = 0.3     // 0 (no HF loss) … 1 (very dark / fast HF decay)
    var mix:        Float = 0.3
    var predelayMs: Float = 0       // 0…200 ms
    var mod:        Float = 1       // 0…1 line-modulation depth scaler

    private let N = 8
    private var fs: Float = 48000
    private var prepared = false

    // Base line lengths (samples @48k), mutually-prime, per mode.
    private let roomLen = [1153, 1303, 1531, 1733, 1951, 2161, 2371, 2591]   // ~24–54 ms
    private let hallLen = [2399, 2767, 3187, 3571, 3947, 4391, 4799, 5279]   // ~50–110 ms
    private let inSign:  [Float] = [1, -1, 1, -1, 1, -1, 1, -1]
    private let outSign: [Float] = [1, 1, -1, -1, 1, 1, -1, -1]

    private var lines: [DL] = []
    private var damp:  [Float] = []
    private var lfoPh: [Float] = []
    private var pd: DL!

    private let erMs: [Float] = [7, 11, 17, 23, 29, 37, 43, 53]
    private let erSign: [Float] = [1, -1, 1, -1, 1, -1, 1, -1]
    private var er: DL!

    private let maxSize: Float = 2.0
    private let maxMod: Float = 18

    func prepare(sampleRate: Double, maxBlock: Int) {
        fs = Float(sampleRate)
        free()
        let sc = fs / 48000 * maxSize
        for i in 0..<N {
            let m = max(roomLen[i], hallLen[i])
            lines.append(DL(Int(Float(m) * sc) + Int(maxMod) + 8))
            damp.append(0); lfoPh.append(Float(i) * 0.7)
        }
        pd = DL(Int(0.2 * fs) + 8)
        er = DL(Int(0.07 * fs) + 8)
        prepared = true
        reset()
    }

    func reset() {
        guard prepared else { return }
        for d in lines { d.clear() }
        for i in 0..<N { damp[i] = 0; lfoPh[i] = Float(i) * 0.7 }
        pd?.clear(); er?.clear()
    }

    private func free() {
        for d in lines { d.free() }; lines = []; damp = []; lfoPh = []
        pd?.free(); er?.free()
    }
    deinit { free() }

    func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard prepared, n > 0 else { return }
        let isHall = (mode == .hall)
        let base = isHall ? hallLen : roomLen
        let sc = fs / 48000 * min(max(size, 0.5), maxSize)
        let t60 = max(0.05, decay)

        // Per-line length, Jot gain, damping coefficient.
        var M = [Int](repeating: 0, count: N)
        var g = [Float](repeating: 0, count: N)
        for i in 0..<N {
            M[i] = clampOff(Float(base[i]) * sc, lines[i].cap - Int(maxMod) - 2)
            g[i] = powf(10, -3 * Float(M[i]) / (t60 * fs))
        }
        // HF damping: hall damps 2–3× harder (highs decay faster). One-pole DC-unity LP, so the
        // low band keeps the exact Jot T60 while the high band loses extra (1-d)/(1+d) per loop.
        let dCoef = min(max(hfDamp, 0), 0.95) * (isHall ? 0.80 : 0.30)

        // Modulation: every line in hall, gentle in room.
        let modDepth = min(max(mod, 0), 1) * maxMod * (isHall ? 1.0 : 0.35)
        let lfoInc = 2 * Float.pi * 0.9 / fs

        let pdS = clampOff(Float(max(0, predelayMs)) / 1000 * fs, pd.cap - 2)
        let erEnabled = !isHall
        let erTap = erMs.map { clampOff($0 / 1000 * fs, er.cap - 2) }
        let erGain: Float = 0.35
        let wetScale: Float = 0.30

        var y = [Float](repeating: 0, count: N)
        var dlt = [Float](repeating: 0, count: N)

        for i in 0..<n {
            let dry = s[i]
            pd.push(dry)
            let inp = pd.tapInt(pdS)

            // Read line outputs (with per-line modulated fractional read).
            for k in 0..<N {
                let m = Float(M[k]) - modDepth * 0.5 * (1 + sinf(lfoPh[k]))
                lfoPh[k] += lfoInc; if lfoPh[k] > 2 * Float.pi { lfoPh[k] -= 2 * Float.pi }
                y[k] = lines[k].tapFrac(max(1, m))
            }

            // Wet = signed sum of line outputs (+ early reflections in room mode).
            var wet: Float = 0
            for k in 0..<N { wet += outSign[k] * y[k] }
            if erEnabled {
                er.push(inp)
                for t in 0..<erMs.count { wet += erSign[t] * er.tapInt(erTap[t]) * erGain }
            }

            // Feedback path: per-line damping LP then Jot gain.
            for k in 0..<N {
                damp[k] = flush((1 - dCoef) * y[k] + dCoef * damp[k])
                dlt[k] = flush(damp[k] * g[k])
            }
            // Lossless Householder mix: s = (2/N)Σd ; outᵢ = dᵢ − s.
            var sum: Float = 0
            for k in 0..<N { sum += dlt[k] }
            let sH = (2 / Float(N)) * sum
            for k in 0..<N {
                let writeIn = inp * inSign[k] + (dlt[k] - sH)
                lines[k].push(flush(writeIn))
            }

            s[i] = dry * (1 - mix) + wet * wetScale * mix
        }
    }
}
