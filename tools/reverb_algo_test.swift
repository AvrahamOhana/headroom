//
//  reverb_algo_test.swift
//  Headless verification for the three REAL reverb engines in ReverbAlgorithms.swift
//  (DattorroPlate, SpringReverb, FDNReverb). These engine classes are COPIED VERBATIM from
//  ReverbAlgorithms.swift — this tool builds standalone and cannot import the app target.
//
//  Verifies:
//    (a) every engine's impulse response is non-silent + FINITE + bounded over a 4 s tail
//        (proves denormal-safety + stability — no blow-up).
//    (b) Plate — high echo density in the first 50 ms + a smooth, monotonically-decaying tail.
//    (c) Spring — group delay DECREASES with frequency (dispersive descending chirp): analytic
//        first-order-allpass group delay AND an empirical tone-burst arrival-time sweep, both
//        shown to be qualitatively different from a plain (constant-delay) line.
//    (d) FDN — measured T60 matches the target within tolerance, and HALL high band decays
//        faster than the low band (frequency-dependent damping).
//
//  Run:  swift tools/reverb_algo_test.swift
//

import Foundation
import Accelerate

// ============================================================================================
//  ===== BEGIN verbatim copy of ReverbAlgorithms.swift engines =====
// ============================================================================================

@inline(__always) fileprivate func flush(_ x: Float) -> Float { abs(x) < 1e-18 ? 0 : x }

fileprivate final class DL {
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
    @inline(__always) func push(_ x: Float) { buf[w] = x; w &+= 1; if w >= cap { w = 0 } }
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

@inline(__always) fileprivate func clampOff(_ v: Float, _ maxv: Int) -> Int {
    let i = Int(v); return i < 1 ? 1 : (i > maxv ? maxv : i)
}

final class DattorroPlate: @unchecked Sendable {
    var predelayMs: Float = 0
    var decay:      Float = 0.5
    var damp:       Float = 0.0005
    var size:       Float = 1
    var mod:        Float = 1
    var mix:        Float = 0.3

    private let baseFs: Float = 29761
    private var fs: Float = 48000
    private var prepared = false

    private let inDiff1: Float = 0.75, inDiff2: Float = 0.625
    private let decDiff1: Float = 0.70

    private let lDif = [142, 107, 379, 277]
    private let lApL1 = 672, lDlL1 = 4453, lApL2 = 1801, lDlL2 = 3720
    private let lApR1 = 908, lDlR1 = 4217, lApR2 = 2656, lDlR2 = 3163

    private var pd: DL!
    private var dif: [DL] = []
    private var apL1, dlL1, apL2, dlL2: DL!
    private var apR1, dlR1, apR2, dlR2: DL!

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
        let bw  = min(max(1 - dmp, 0.2), 0.9995)
        let dd2 = min(max(dec + 0.15, 0.25), 0.50)
        let pdS = clampOff(Float(max(0, predelayMs)) / 1000 * fs, pd.cap - 2)
        let exc = min(max(mod, 0), 1) * maxExc * (fs / baseFs)
        let lfoInc = 2 * Float.pi * 0.7 / fs

        let nDif = lDif.map { clampOff(Float($0) * sc, 1 << 28) }
        let nApL1 = Float(lApL1) * sc, nApR1 = Float(lApR1) * sc
        let nDlL1 = clampOff(Float(lDlL1) * sc, dlL1.cap - 2)
        let nApL2 = clampOff(Float(lApL2) * sc, apL2.cap - 2)
        let nDlL2 = clampOff(Float(lDlL2) * sc, dlL2.cap - 2)
        let nDlR1 = clampOff(Float(lDlR1) * sc, dlR1.cap - 2)
        let nApR2 = clampOff(Float(lApR2) * sc, apR2.cap - 2)
        let nDlR2 = clampOff(Float(lDlR2) * sc, dlR2.cap - 2)

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

            bwState = flush(bw * x + (1 - bw) * bwState); x = bwState

            x = apI(dif[0], x, nDif[0], inDiff1)
            x = apI(dif[1], x, nDif[1], inDiff1)
            x = apI(dif[2], x, nDif[2], inDiff2)
            x = apI(dif[3], x, nDif[3], inDiff2)

            let s1 = sinf(lfo), s2 = sinf(lfo + 1.5)
            lfo += lfoInc; if lfo > 2 * Float.pi { lfo -= 2 * Float.pi }
            let lenL1 = max(2, nApL1 + exc * s1)
            let lenR1 = max(2, nApR1 + exc * s2)

            var nL = flush(x + dec * tailR)
            nL = ap(apL1, nL, lenL1, -decDiff1)
            dlL1.push(flush(nL)); nL = dlL1.tapInt(nDlL1)
            dampL = flush((1 - dmp) * nL + dmp * dampL); nL = dampL
            nL = apI(apL2, nL, nApL2, dd2)
            dlL2.push(flush(nL)); nL = dlL2.tapInt(nDlL2)
            let newTailL = nL

            var nR = flush(x + dec * tailL)
            nR = ap(apR1, nR, lenR1, -decDiff1)
            dlR1.push(flush(nR)); nR = dlR1.tapInt(nDlR1)
            dampR = flush((1 - dmp) * nR + dmp * dampR); nR = dampR
            nR = apI(apR2, nR, nApR2, dd2)
            dlR2.push(flush(nR)); nR = dlR2.tapInt(nDlR2)
            let newTailR = nR

            tailL = newTailL; tailR = newTailR

            let left =  0.6 * d.tapInt(yld.0) + 0.6 * d.tapInt(yld.1) - 0.6 * e.tapInt(yle)
                      + 0.6 * f.tapInt(ylf)  - 0.6 * a.tapInt(yla)   - 0.6 * b.tapInt(ylb) - 0.6 * c.tapInt(ylc)
            let right = 0.6 * a.tapInt(yra.0) + 0.6 * a.tapInt(yra.1) - 0.6 * b.tapInt(yrb)
                      + 0.6 * c.tapInt(yrc)  - 0.6 * d.tapInt(yrd)   - 0.6 * e.tapInt(yre) - 0.6 * f.tapInt(yrf)
            let wet = 0.5 * (left + right)

            s[i] = dry * (1 - mix) + wet * mix
        }
    }
}

final class SpringReverb: @unchecked Sendable {
    var decay:   Float = 0.72
    var tension: Float = 0.6
    var springs: Int   = 3
    var tone:    Float = 0.5
    var mix:     Float = 0.3

    private var fs: Float = 48000
    private var prepared = false
    private let nAP = 90
    private let maxSprings = 3
    private let loopMs: [Float] = [37.0, 43.7, 52.1]
    private let detune: [Float] = [1.0, 0.97, 1.04]

    private var apX: [UnsafeMutableBufferPointer<Float>] = []
    private var apY: [UnsafeMutableBufferPointer<Float>] = []
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
        let baseA = -min(max(tension, 0.05), 0.88)
        let fc = 1200 + min(max(tone, 0), 1) * 5000
        let lpC = 1 - expf(-2 * Float.pi * min(fc, fs * 0.45) / fs)
        let hpR = 1 - 2 * Float.pi * 80 / fs
        let loopN = (0..<maxSprings).map { clampOff(loopMs[$0] / 1000 * fs, loop[$0].cap - 2) }
        let aS = (0..<maxSprings).map { max(-0.88, min(-0.05, baseA * detune[$0])) }
        let outScale = 0.7 / Float(nS)

        for i in 0..<n {
            let dry = s[i]
            let hp = flush(dry - hpX + hpR * hpY)
            hpX = dry; hpY = hp

            var wet: Float = 0
            for sp in 0..<nS {
                let a = aS[sp]
                var v = flush(hp + dec * fb[sp])
                let ax = apX[sp].baseAddress!, ay = apY[sp].baseAddress!
                for k in 0..<nAP {
                    let xn = v
                    let yn = a * xn + ax[k] - a * ay[k]
                    ax[k] = xn; ay[k] = flush(yn)
                    v = yn
                }
                lpState[sp] = flush(lpState[sp] + lpC * (v - lpState[sp]))
                v = lpState[sp]
                loop[sp].push(v)
                var dlt = loop[sp].tapInt(loopN[sp])
                dlt = 0.85 * tanhf(dlt * 1.3) + 0.15 * dlt
                fb[sp] = flush(dlt)
                wet += dlt
            }
            wet *= outScale
            s[i] = dry * (1 - mix) + wet * mix
        }
    }
}

final class FDNReverb: @unchecked Sendable {
    enum Mode { case room, hall }

    var mode: Mode = .room
    var size:       Float = 1
    var decay:      Float = 1.5
    var hfDamp:     Float = 0.3
    var mix:        Float = 0.3
    var predelayMs: Float = 0
    var mod:        Float = 1

    private let N = 8
    private var fs: Float = 48000
    private var prepared = false

    private let roomLen = [1153, 1303, 1531, 1733, 1951, 2161, 2371, 2591]
    private let hallLen = [2399, 2767, 3187, 3571, 3947, 4391, 4799, 5279]
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

        var M = [Int](repeating: 0, count: N)
        var g = [Float](repeating: 0, count: N)
        for i in 0..<N {
            M[i] = clampOff(Float(base[i]) * sc, lines[i].cap - Int(maxMod) - 2)
            g[i] = powf(10, -3 * Float(M[i]) / (t60 * fs))
        }
        let dCoef = min(max(hfDamp, 0), 0.95) * (isHall ? 0.80 : 0.30)
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

            for k in 0..<N {
                let m = Float(M[k]) - modDepth * 0.5 * (1 + sinf(lfoPh[k]))
                lfoPh[k] += lfoInc; if lfoPh[k] > 2 * Float.pi { lfoPh[k] -= 2 * Float.pi }
                y[k] = lines[k].tapFrac(max(1, m))
            }

            var wet: Float = 0
            for k in 0..<N { wet += outSign[k] * y[k] }
            if erEnabled {
                er.push(inp)
                for t in 0..<erMs.count { wet += erSign[t] * er.tapInt(erTap[t]) * erGain }
            }

            for k in 0..<N {
                damp[k] = flush((1 - dCoef) * y[k] + dCoef * damp[k])
                dlt[k] = flush(damp[k] * g[k])
            }
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

// ============================================================================================
//  ===== END verbatim copy. Verification harness below. =====
// ============================================================================================

let sr: Float = 48000
var pass = true
func check(_ name: String, _ ok: Bool) {
    print("  [\(ok ? "PASS" : "FAIL")] \(name)")
    if !ok { pass = false }
}

func finite(_ x: [Float]) -> Bool { x.allSatisfy { $0.isFinite } }
func peak(_ x: ArraySlice<Float>) -> Float { x.map { abs($0) }.max() ?? 0 }
func peak(_ x: [Float]) -> Float { peak(x[...]) }
func rms(_ x: ArraySlice<Float>) -> Float { x.isEmpty ? 0 : sqrtf(x.map { $0 * $0 }.reduce(0, +) / Float(x.count)) }
func rms(_ x: [Float]) -> Float { rms(x[...]) }

/// Render `input` through a block process closure in odd-sized chunks (exercises block decoupling).
func render(_ proc: (UnsafeMutablePointer<Float>, Int) -> Void, _ input: [Float], block: Int = 411) -> [Float] {
    var x = input
    x.withUnsafeMutableBufferPointer { bp in
        var off = 0
        while off < bp.count {
            let n = min(block, bp.count - off)
            proc(bp.baseAddress! + off, n)
            off += n
        }
    }
    return x
}

func impulse(_ n: Int) -> [Float] { var x = [Float](repeating: 0, count: n); x[0] = 1; return x }

/// One-pole low-pass (DC-unity). Returns the low band.
func lowBand(_ x: [Float], hz: Float) -> [Float] {
    let c = 1 - expf(-2 * Float.pi * hz / sr); var y: Float = 0
    return x.map { y += c * ($0 - y); return y }
}
/// One-pole high band = x − lowpass(x).
func highBand(_ x: [Float], hz: Float) -> [Float] {
    let c = 1 - expf(-2 * Float.pi * hz / sr); var y: Float = 0
    return x.map { y += c * ($0 - y); return $0 - y }
}

/// Schroeder backward-integration T60 from a (band-limited) impulse response.
func schroederT60(_ y: [Float]) -> Float {
    let n = y.count
    var edc = [Double](repeating: 0, count: n)
    var acc: Double = 0
    for i in stride(from: n - 1, through: 0, by: -1) { acc += Double(y[i]) * Double(y[i]); edc[i] = acc }
    let e0 = edc[0]; guard e0 > 0 else { return 0 }
    var t5 = -1.0, t35 = -1.0
    for i in 0..<n {
        let db = 10 * log10(edc[i] / e0 + 1e-30)
        let t = Double(i) / Double(sr)
        if t5 < 0 && db <= -5 { t5 = t }
        if t35 < 0 && db <= -35 { t35 = t; break }
    }
    guard t5 >= 0, t35 > t5 else { return 0 }
    return Float(2.0 * (t35 - t5))    // -5…-35 dB = 30 dB → ×2 → T60
}

let total = Int(sr * 4)   // 4-second tails everywhere

// ============================================================================================
print("\n=== (1) DattorroPlate ===")
do {
    let p = DattorroPlate()
    p.prepare(sampleRate: Double(sr), maxBlock: 512)
    p.predelayMs = 0; p.decay = 0.80; p.damp = 0.05; p.size = 1; p.mod = 1; p.mix = 1
    let y = render({ p.process($0, $1) }, impulse(total))

    let pk = peak(y), rl = rms(y)
    let tailRms = rms(y[(total - 4800)...])           // last 100 ms still ringing?
    print(String(format: "  peak=%.4f  rms=%.5f  tail(end100ms)rms=%.6f", pk, rl, tailRms))
    check("non-silent", rl > 1e-4)
    check("finite + bounded over 4 s", finite(y) && pk < 50)
    check("tail still ringing at ~4 s", tailRms > 1e-6)

    // Echo density: distinct nonzero output taps in the first 50 ms, vs a plain feedback delay
    // (a sparse comb) over the same window — the plate's allpass diffusion must be FAR denser.
    let win = Int(sr * 0.05)
    let thr = pk * 1e-3
    func density(_ z: [Float], _ p: Float) -> Int { z[0..<win].reduce(0) { $0 + (abs($1) > p ? 1 : 0) } }
    let dense = density(y, thr)
    // reference: 20 ms feedback delay (comb) impulse → only a few discrete echoes in 50 ms.
    var comb = impulse(total); let cd = Int(sr * 0.02)
    for i in cd..<comb.count { comb[i] += comb[i - cd] * 0.7 }
    let combDense = density(comb, peak(comb) * 1e-3)
    let buildup = density(y, thr)                                   // first 50 ms
    let buildup150 = y[0..<Int(sr*0.15)].reduce(0) { $0 + (abs($1) > thr ? 1 : 0) }
    print("  echo density first 50 ms = \(dense)  (plain-delay comb = \(combDense));  first 150 ms = \(buildup150)")
    check("high echo density (> 250 taps, >> plain delay)", dense > 250 && dense > combDense * 30)
    check("density builds up over time (150 ms ≫ 50 ms)", buildup150 > buildup * 2)

    // Smooth decaying tail: RMS in 8 windows across the 4 s, must trend down.
    let nb = 8, bs = total / nb
    var env = [Float](); for b in 0..<nb { env.append(rms(y[(b*bs)..<((b+1)*bs)])) }
    print("  tail envelope (8×0.5 s rms): " + env.map { String(format: "%.4f", $0) }.joined(separator: " "))
    var smooth = true
    for b in 1..<nb where env[b] > env[b-1] * 1.30 { smooth = false }   // no big re-swell
    check("tail decays smoothly (monotone-ish)", smooth && env[nb-1] < env[1])
}

// ============================================================================================
print("\n=== (2) SpringReverb ===")
do {
    let p = SpringReverb()
    p.prepare(sampleRate: Double(sr), maxBlock: 512)
    p.decay = 0.78; p.tension = 0.6; p.springs = 3; p.tone = 0.6; p.mix = 1
    let y = render({ p.process($0, $1) }, impulse(total))

    let pk = peak(y), rl = rms(y)
    let tailRms = rms(y[(total - 4800)...])
    print(String(format: "  peak=%.4f  rms=%.5f  tail(end100ms)rms=%.6f", pk, rl, tailRms))
    check("non-silent", rl > 1e-4)
    check("finite + bounded over 4 s", finite(y) && pk < 50)

    // (c) Dispersion = group delay DECREASES with frequency.
    // Analytic first-order allpass group delay (the EXACT cascade used in process), a = −tension.
    let a: Float = -0.6, nAP = 90
    func gdSamples(_ hz: Float) -> Float {
        let w = 2 * Float.pi * hz / sr
        return Float(nAP) * (1 - a*a) / (1 + 2*a*cosf(w) + a*a)
    }
    let freqs: [Float] = [200, 1000, 4000, 8000]
    let gds = freqs.map { gdSamples($0) }
    print("  analytic cascade group delay (samples → ms):")
    for (i, f) in freqs.enumerated() {
        print(String(format: "     %6.0f Hz : %8.2f samp  (%6.3f ms)", f, gds[i], gds[i] / sr * 1000))
    }
    var decreasing = true
    for i in 1..<gds.count where !(gds[i] < gds[i-1]) { decreasing = false }
    let spread = gds.first! / max(gds.last!, 1e-6)
    print(String(format: "  GD(low)/GD(high) spread = %.1f×  (a plain delay would be 1.0×)", spread))
    check("group delay strictly DECREASES with frequency", decreasing)
    check("dispersive (>3× spread vs a flat delay)", spread > 3)

    // Empirical: push windowed tone bursts through the SAME 90-allpass cascade; the energy
    // centroid (arrival time) of the low burst must be LATER than the high burst.
    func cascadeBurst(_ hz: Float) -> Float {
        let len = 8000
        var x = [Float](repeating: 0, count: len)
        let bl = 1200
        for i in 0..<bl {                                   // Hann-windowed sine burst near t=0
            let wnd = 0.5 * (1 - cosf(2 * Float.pi * Float(i) / Float(bl - 1)))
            x[i] = wnd * sinf(2 * Float.pi * hz * Float(i) / sr)
        }
        var xm = [Float](repeating: 0, count: nAP), ym = [Float](repeating: 0, count: nAP)
        var num: Double = 0, den: Double = 0
        for i in 0..<len {
            var v = x[i]
            for k in 0..<nAP { let xn = v; let yn = a*xn + xm[k] - a*ym[k]; xm[k] = xn; ym[k] = yn; v = yn }
            let e = Double(v) * Double(v)
            num += Double(i) * e; den += e
        }
        return den > 0 ? Float(num / den) / sr * 1000 : 0    // centroid in ms
    }
    let cLow = cascadeBurst(300), cHigh = cascadeBurst(5000)
    print(String(format: "  empirical arrival centroid: 300 Hz = %.3f ms,  5000 Hz = %.3f ms", cLow, cHigh))
    check("low freq arrives LATER than high (descending chirp)", cLow > cHigh + 0.2)

    // 1-spring variant must also stay finite + bounded
    p.reset(); p.springs = 1
    let y1 = render({ p.process($0, $1) }, impulse(total))
    check("1-spring variant finite + bounded", finite(y1) && peak(y1) < 50 && rms(y1) > 1e-4)
}

// ============================================================================================
print("\n=== (3) FDNReverb — ROOM ===")
do {
    let p = FDNReverb()
    p.mode = .room
    p.prepare(sampleRate: Double(sr), maxBlock: 512)
    let target: Float = 0.8
    p.decay = target; p.hfDamp = 0.3; p.size = 1; p.predelayMs = 0; p.mod = 1; p.mix = 1
    let y = render({ p.process($0, $1) }, impulse(total))

    let pk = peak(y), rl = rms(y)
    print(String(format: "  peak=%.4f  rms=%.5f", pk, rl))
    check("non-silent", rl > 1e-4)
    check("finite + bounded over 4 s", finite(y) && pk < 50)

    let t60 = schroederT60(lowBand(y, hz: 500))
    let err = abs(t60 - target) / target
    print(String(format: "  target T60 = %.2f s,  measured (low band) = %.2f s  (err %.0f%%)", target, t60, err*100))
    check("measured T60 matches target (±35%)", err < 0.35)
}

print("\n=== (4) FDNReverb — HALL ===")
do {
    let p = FDNReverb()
    p.mode = .hall
    p.prepare(sampleRate: Double(sr), maxBlock: 512)
    let target: Float = 2.5
    p.decay = target; p.hfDamp = 0.6; p.size = 1; p.predelayMs = 0; p.mod = 1; p.mix = 1
    let y = render({ p.process($0, $1) }, impulse(total))

    let pk = peak(y), rl = rms(y)
    // A 2.5 s T60 is ~−96 dB by 4 s (correctly near-silent) — so probe the MID tail (~2 s) to prove
    // the multi-second decay develops without the denormal stall (the 4 s finite check covers the rest).
    let midRms = rms(y[Int(sr*1.9)..<Int(sr*2.0)])
    print(String(format: "  peak=%.4f  rms=%.5f  mid-tail(~2 s)rms=%.6f", pk, rl, midRms))
    check("non-silent", rl > 1e-4)
    check("finite + bounded over 4 s", finite(y) && pk < 50)
    check("multi-second tail still ringing at ~2 s", midRms > 1e-6)

    let t60lo = schroederT60(lowBand(y, hz: 500))
    let errLo = abs(t60lo - target) / target
    print(String(format: "  target T60 = %.2f s,  measured low-band = %.2f s  (err %.0f%%)", target, t60lo, errLo*100))
    check("low-band T60 matches target (±35%)", errLo < 0.35)

    let t60hi = schroederT60(highBand(y, hz: 4000))
    let ratio = t60hi > 0 ? t60lo / t60hi : 0
    print(String(format: "  high-band (>4 kHz) T60 = %.2f s   →  low/high decay ratio = %.2f×", t60hi, ratio))
    check("HALL highs decay faster than lows (ratio > 1.5)", ratio > 1.5)
}

print("\n\(pass ? "ALL TESTS PASSED" : "SOME TESTS FAILED")")
exit(pass ? 0 : 1)
