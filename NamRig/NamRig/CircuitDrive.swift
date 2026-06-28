//
//  CircuitDrive.swift
//  NamRig — circuit-derived overdrive / distortion / fuzz pedal library.
//
//  One DSP engine + a data table (`PedalModel`) = the whole library. Unlike the generic
//  `DriveBlock` (one tanh/clip/fuzz shape), `CircuitDriveBlock` models the *topology* of real
//  pedal circuits, and the clip stage genuinely BRANCHES in code — four different algorithms,
//  not value presets:
//
//     • softFeedback  y = x + Vf·tanh(g·x/Vf)        (op-amp + diodes in the FEEDBACK loop: TS).
//                                                      Small signals see gain (1+g); large signals see
//                                                      incremental gain ~1 → a compander → sustain.
//                                                      Keeps the clean ramp underneath → NOT bounded.
//     • softBounded   y = Vf·tanh(g·x/Vf)            (cascaded saturating stages: Big Muff). Drops the
//                                                      +x term so the output SATURATES toward ±Vf →
//                                                      compression / infinite sustain (the Muff's tell).
//     • hardShunt     y = Vf·clip(g·x/Vf)            (diodes to GROUND after the gain stage: RAT, DS-1).
//                                                      Hard clamp at ±Vf → square-ish, strong high-order
//                                                      odd harmonics.
//     • asym          y = x + Vp·tanh(g·x/Vp)  (x≥0) (germanium soft-feedback, different drop per half:
//                      y = x + Vn·tanh(g·x/Vn)  (x<0)  Klon). Clean is intrinsic (slope ~1 for small x);
//                                                      only peaks get even-harmonic grit. Asymmetric →
//                                                      small DC → DC blocker after it.
//
//  Signal flow (per the FX roadmap "Overdrive library" section):
//     input HPF (mid-hump / low cleanup)
//       → optional pre-clip LPF (feedback-cap treble roll into the clipper)
//       → drive gain → FIXED-threshold clipper      [wrapped in Oversampler + ADAA1: 2× soft, 8× hard]
//       → DC blocker (one-pole ~19 Hz, asymmetric models only)
//       → tone biquads (per voicing)
//       → post-clip SMOOTHING LPF (~10 kHz, every model — stops the top-octave fizz from folding
//         DOWN into the audible band through the downstream nonlinear NAM amp)
//       → output level.
//
//  The nonlinearity is the ONLY thing oversampled (the filters are linear → no aliasing, stay at
//  base rate). Everything is pre-allocated in `prepare`; `process` does zero allocation, mirroring
//  the rest of Blocks.swift. Reuses the shared `Biquad`, `ADAA1`, `Oversampler`, `AudioBlock` types.
//
//  PARAM RANGES (documented): `drive`, `tone`, `level` are all normalized 0…1.
//     drive  — 0…1, exponentially mapped to each model's natural linear gain range.
//     tone   — 0…1, mapped per model to its tone control (LPF sweep / tilt / RAT "Filter" / scoop bright).
//     level  — 0…1 output trim; final gain = model.makeup · level (1.0 = full calibrated makeup).
//     model  — Int index into `PedalModel.all` (0…count-1); selects the pedal.
//
//  Legal/naming: all names are ORIGINAL/allusive (Green Screamer, Rodent, Modern Distortion, Centaur
//  Gold, Muffin Fuzz). Modeling circuit behavior is legal; trademarked names/logos are not. See
//  `CircuitDriveBlock.disclaimer`.
//

import Foundation
import Synchronization
import Accelerate

// ============================================================================================
//  Data table
// ============================================================================================

/// How the clip stage is wired — a genuinely different algorithm per case (see file header).
nonisolated enum ClipMode: Sendable { case softFeedback, softBounded, hardShunt, asym }

/// Post-clip tone-stack voicing. Each maps the 0…1 `tone` knob to its own filter behavior.
nonisolated enum ToneType: Sendable {
    case lowpassTilt   // TS: post LPF (swept) + treble roll + a fixed mid-hump
    case ratFilter     // RAT: single LPF that DARKENS as the knob is turned up (inverted sweep)
    case scoopTilt     // DS-1: bass/treble tilt (two shelves) + a fixed mid scoop
    case klonTilt      // Klon: treble-tilt high shelf + a fixed amp-protect LPF
    case muffScoop     // Big Muff: fixed mid SCOOP (~-13.5 dB @1 kHz) + a bright/dark LPF sweep
}

/// One row = one pedal. Pure data; the block reads it to configure filters, gain and the clip branch.
nonisolated struct PedalModel: Sendable {
    let name: String            // safe, original display name
    let inputHz: Float          // pre-clip HPF corner (mid-hump / low cleanup)
    let gainRange: ClosedRange<Float>  // linear clip-stage gain at drive 0…1 (exponential)
    let clip: ClipMode
    let diodeVf: Float          // forward drop, V — 0.3 Ge · 0.6 Si · 1.7 LED
    let asymVf: Float           // negative-half drop for the `asym` branch (== diodeVf if symmetric)
    let feedbackCapHz: Float    // pre-clip LPF (treble roll INTO the clipper); 0 → none
    let tone: ToneType
    let toneLoHz: Float          // tone-knob sweep low corner / low shelf
    let toneHiHz: Float          // tone-knob sweep high corner / high shelf
    let scoopHz: Float           // mid-scoop center (0 → none)
    let scoopDb: Float           // mid-scoop depth (dB)
    let makeup: Float            // output makeup gain (level knob multiplies this)
    let oversample: Int          // 2 / 4 / 8
    let stages: Int              // 1, or 2 for a cascaded soft-clip (Big Muff)
    let needsDC: Bool            // DC blocker after the nonlinearity (asymmetric circuits)

    /// The library, in selector order. Indices are stable (presets store the int).
    //
    //  Gain-staging note: ranges are deliberately TAME. A normal -12 dBFS guitar note peaks ~0.25,
    //  and the clip knee is at x_th = Vf/g; the lower bound is chosen so drive 0 puts the knee at/above
    //  a clean note (the note "breathes" and tracks pick force), and the hi/lo ratio is kept small so
    //  the clean→crunch→square transition spreads across the knob instead of collapsing in the first
    //  10 %. Hotter ranges sound identical to these at the top (a square is a square) but kill pick
    //  dynamics and only add aliasing — so we don't use them.
    static let all: [PedalModel] = [
        // 0 — Green Screamer (TS808): mid-hump HPF → soft Si-in-feedback → MID-FORWARD tone (rolled
        //     highs + a ~720 Hz hump), the classic TS voice. Soft clip keeps it fundamental-dominated.
        PedalModel(name: "Green Screamer", inputHz: 600, gainRange: 1.5...45, clip: .softFeedback,
                   diodeVf: 0.6, asymVf: 0.6, feedbackCapHz: 0, tone: .lowpassTilt,
                   toneLoHz: 700, toneHiHz: 2200, scoopHz: 0, scoopDb: 0,
                   makeup: 0.65, oversample: 2, stages: 1, needsDC: false),

        // 1 — Rodent (RAT): light HPF → high gain + feedback-cap treble roll → hard Si to ground →
        //     "Filter" LPF (darker as it's turned up). Darker top than the TS. 8× OS. REFERENCE voicing.
        PedalModel(name: "Rodent", inputHz: 32, gainRange: 2.5...75, clip: .hardShunt,
                   diodeVf: 0.6, asymVf: 0.6, feedbackCapHz: 2400, tone: .ratFilter,
                   toneLoHz: 700, toneHiHz: 4500, scoopHz: 0, scoopDb: 0,
                   makeup: 0.42, oversample: 8, stages: 1, needsDC: false),

        // 2 — Modern Distortion (DS-1): two-stage gain → hard Si clip → tone LPF + treble tilt + mid
        //     scoop. A touch of bite, but not fizzy (the treble shelf is capped). 8× OS.
        PedalModel(name: "Modern Distortion", inputHz: 50, gainRange: 3...90, clip: .hardShunt,
                   diodeVf: 0.6, asymVf: 0.6, feedbackCapHz: 5000, tone: .scoopTilt,
                   toneLoHz: 1500, toneHiHz: 4500, scoopHz: 600, scoopDb: -7,
                   makeup: 0.42, oversample: 8, stages: 1, needsDC: false),

        // 3 — Centaur Gold (Klon): soft-feedback Ge ASYM clip — the clean ramp is INTRINSIC (slope ~1
        //     for small signals, grit only on peaks), so quiet notes stay clean/transparent. Low gain.
        //     Treble tilt + amp-protect LPF. 4× OS.
        PedalModel(name: "Centaur Gold", inputHz: 40, gainRange: 1...30, clip: .asym,
                   diodeVf: 0.30, asymVf: 0.38, feedbackCapHz: 0, tone: .klonTilt,
                   toneLoHz: 0, toneHiHz: 3000, scoopHz: 0, scoopDb: 0,
                   makeup: 0.50, oversample: 4, stages: 1, needsDC: true),

        // 4 — Muffin Fuzz (Big Muff): two cascaded BOUNDED soft-clip stages → SATURATION / infinite
        //     sustain → mid SCOOP ~-13.5 dB @1 kHz, dark top. Symmetric → no DC. 8× OS.
        PedalModel(name: "Muffin Fuzz", inputHz: 80, gainRange: 4...120, clip: .softBounded,
                   diodeVf: 0.6, asymVf: 0.6, feedbackCapHz: 0, tone: .muffScoop,
                   toneLoHz: 800, toneHiHz: 4500, scoopHz: 1000, scoopDb: -13.5,
                   makeup: 0.50, oversample: 8, stages: 2, needsDC: false),
    ]
}

// ============================================================================================
//  Block
// ============================================================================================

/// Circuit-derived overdrive/distortion/fuzz. Drops in for (or augments) `DriveBlock` — same
/// `init(kind: .drive)` so it can slot into the existing chain, plus a `model` selector.
///
/// Face Fuzz (Fuzz Face) is intentionally NOT in the table: a germanium Fuzz Face is dominated by
/// transistor cutoff + pickup loading (a dynamic, source-impedance-dependent circuit, not a static
/// waveshaper), so it ships as a NAM CAPTURE in the `.pedal` slot, not as a modeled entry here.
final class CircuitDriveBlock: AudioBlock {
    // ---- Public params (all normalized 0…1 except `model`) -----------------------------------
    var model: Int = 0   { didSet { if model != oldValue { recompute(resetFilters: true) } } }
    var drive: Float = 0.5 { didSet { recompute() } }
    var tone:  Float = 0.5 { didSet { recompute() } }
    var level: Float = 0.8 { didSet { recompute() } }

    var modelCount: Int { PedalModel.all.count }
    func modelName(_ i: Int) -> String { PedalModel.all[min(max(0, i), PedalModel.all.count - 1)].name }
    var currentName: String { current.name }

    static let disclaimer =
        "All model names are original. Third-party product names are referenced only to identify " +
        "the inspiring circuits. NamRig is not affiliated with or endorsed by any manufacturer."

    // ---- Cached coefficients (recomputed off the audio thread; benign races, like EQBlock) ----
    private var sr: Float = 48000
    private var g: Float = 1, g2: Float = 1            // stage gains (g2 for the cascaded soft stage)
    private var vf: Float = 0.6, vfNeg: Float = 0.6
    private var outGain: Float = 1
    private var cleanMix: Float = 0, wetMix: Float = 1 // Klon parallel blend
    private var clipMode: ClipMode = .softFeedback
    private var osFactor = 2
    private var stages = 1
    private var needsDC = false
    private var hasPreLP = false
    private var osLatency = 0

    // ---- DSP state (all pre-allocated / value types) -----------------------------------------
    private var inputHP = Biquad()
    private var preLP = Biquad()
    private var bq0 = Biquad(), bq1 = Biquad(), bq2 = Biquad()   // tone stack (always 3, identity if unused)
    private var smoothLP = Biquad()                             // global post-clip anti-fizz LPF (~10 kHz)
    private var dcX1: Float = 0, dcY1: Float = 0
    private var adaaA = ADAA1(), adaaB = ADAA1()

    private var os2 = Oversampler(), os4 = Oversampler(), os8 = Oversampler()

    // Klon parallel-branch scratch + clean delay ring (only path that sums dry + wet).
    private var clean: UnsafeMutableBufferPointer<Float>?
    private var ring: UnsafeMutableBufferPointer<Float>?
    private let ringCap = 128
    private var ringW = 0
    private var maxBlk = 4096

    override init(kind: BlockKind = .drive) { super.init(kind: kind) }

    private var current: PedalModel { PedalModel.all[min(max(0, model), PedalModel.all.count - 1)] }

    // ---- Lifecycle ---------------------------------------------------------------------------
    override func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate)
        maxBlk = max(1, maxBlock)
        os2.prepare(factor: 2, maxBlock: maxBlk)
        os4.prepare(factor: 4, maxBlock: maxBlk)
        os8.prepare(factor: 8, maxBlock: maxBlk)
        if clean == nil {
            clean = .allocate(capacity: maxBlk); clean!.initialize(repeating: 0)
            ring = .allocate(capacity: ringCap); ring!.initialize(repeating: 0)
        } else if clean!.count < maxBlk {
            clean!.deallocate()
            clean = .allocate(capacity: maxBlk); clean!.initialize(repeating: 0)
        }
        recompute(resetFilters: true)
        reset()
    }

    override func reset() {
        inputHP.reset(); preLP.reset(); bq0.reset(); bq1.reset(); bq2.reset(); smoothLP.reset()
        dcX1 = 0; dcY1 = 0
        adaaA.reset(); adaaB.reset()
        os2.reset(); os4.reset(); os8.reset()
        if let p = ring?.baseAddress { for i in 0..<ringCap { p[i] = 0 } }
        ringW = 0
    }

    deinit {
        os2.freeBuffers(); os4.freeBuffers(); os8.freeBuffers()
        clean?.deallocate(); ring?.deallocate()
    }

    // ---- Coefficient build (off audio thread) ------------------------------------------------
    private func setIdentity(_ b: inout Biquad) { b.b0 = 1; b.b1 = 0; b.b2 = 0; b.a1 = 0; b.a2 = 0 }
    private func lerp(_ a: Float, _ b: Float, _ x: Float) -> Float { a + (b - a) * x }

    private func recompute(resetFilters: Bool = false) {
        let m = current
        let d = min(max(0, drive), 1), t = min(max(0, tone), 1)

        // Clip-stage gain — exponential over the model's natural range.
        let lo = m.gainRange.lowerBound, hi = m.gainRange.upperBound
        let gg = lo * powf(hi / lo, d)
        g = gg
        g2 = m.stages == 2 ? max(2, gg * 0.6) : gg    // cascaded 2nd soft stage runs a touch lower
        vf = m.diodeVf
        vfNeg = m.asymVf

        clipMode = m.clip
        osFactor = m.oversample
        stages = m.stages
        needsDC = m.needsDC
        hasPreLP = m.feedbackCapHz > 0
        osLatency = osFactor == 8 ? os8.latencySamples : (osFactor == 4 ? os4.latencySamples : os2.latencySamples)

        // Klon's clean is now INTRINSIC to the soft-feedback asym shape (the +x term), so we run a
        // pure wet path — no parallel-clean blend needed. The ring path stays available but inert.
        cleanMix = 0; wetMix = 1

        outGain = m.makeup * min(max(0, level), 1)

        // Input HPF (mid-hump / low cleanup) + optional pre-clip LPF (feedback-cap treble roll).
        inputHP.setHighpass(freq: min(m.inputHz, sr * 0.45), q: 0.707, sr: sr)
        if hasPreLP { preLP.setLowpass(freq: min(m.feedbackCapHz, sr * 0.45), q: 0.707, sr: sr) }
        else { setIdentity(&preLP) }

        // Tone stack.
        switch m.tone {
        case .lowpassTilt:   // TS — swept LPF darkens toward 0, treble roll, + a fixed ~720 Hz mid-hump.
            bq0.setLowpass(freq: lerp(m.toneLoHz, m.toneHiHz, t), q: 0.707, sr: sr)
            bq1.setHighShelf(freq: 3000, gainDb: -2.5, sr: sr)
            bq2.setPeaking(freq: 720, gainDb: 3, q: 0.7, sr: sr)
        case .ratFilter:     // RAT — turning UP darkens (inverted LPF sweep).
            bq0.setLowpass(freq: lerp(m.toneHiHz, m.toneLoHz, t), q: 0.707, sr: sr)
            setIdentity(&bq1); setIdentity(&bq2)
        case .scoopTilt:     // DS-1 — tone LPF sweep + (capped) treble tilt + fixed mid scoop.
            bq0.setLowpass(freq: lerp(m.toneLoHz, m.toneHiHz, t), q: 0.707, sr: sr)
            bq1.setHighShelf(freq: 3000, gainDb: lerp(-5, 4, t), sr: sr)
            bq2.setPeaking(freq: m.scoopHz, gainDb: m.scoopDb, q: 1.0, sr: sr)
        case .klonTilt:      // Klon — (capped) treble tilt + a fixed amp-protect LPF before the amp.
            bq0.setHighShelf(freq: m.toneHiHz, gainDb: lerp(-3, 4, t), sr: sr)
            bq1.setLowpass(freq: min(8500, sr * 0.45), q: 0.707, sr: sr)
            setIdentity(&bq2)
        case .muffScoop:     // Big Muff — fixed ~-13.5 dB scoop @1 kHz + a bright/dark LPF sweep.
            bq0.setPeaking(freq: m.scoopHz, gainDb: m.scoopDb, q: 0.9, sr: sr)
            bq1.setLowpass(freq: lerp(m.toneLoHz, m.toneHiHz, t), q: 0.707, sr: sr)
            setIdentity(&bq2)
        }

        // Global post-clip smoothing LPF — inaudible in the guitar band, but it removes the top-octave
        // content (genuine HF + residual decimation alias) BEFORE the nonlinear NAM amp folds it down
        // into the audible band as harsh intermodulation "fizz". Applied on EVERY model.
        smoothLP.setLowpass(freq: min(10000, sr * 0.45), q: 0.707, sr: sr)

        if resetFilters { inputHP.reset(); preLP.reset(); bq0.reset(); bq1.reset(); bq2.reset(); smoothLP.reset() }
    }

    // ---- Clip shapers + their antiderivatives (ADAA1, inlined, no closures) -------------------
    // softFeedback: y = x + Vf·tanh(g·x/Vf)  (clean ramp kept underneath → compander, NOT bounded).
    @inline(__always) private func softShapeA(_ x: Float) -> Float { x + vf * tanhf(g * x / vf) }
    @inline(__always) private func softF1A(_ x: Float) -> Float { 0.5 * x * x + (vf * vf / g) * ADAA1.lnCosh(g * x / vf) }
    private func softStepA(_ x: Float) -> Float {
        let p = adaaA.prevX, dx = x - p
        let y = abs(dx) < ADAA1.eps ? softShapeA((x + p) * 0.5) : (softF1A(x) - softF1A(p)) / dx
        adaaA.prevX = x; return y
    }
    @inline(__always) private func softShapeB(_ x: Float) -> Float { x + vf * tanhf(g2 * x / vf) }
    @inline(__always) private func softF1B(_ x: Float) -> Float { 0.5 * x * x + (vf * vf / g2) * ADAA1.lnCosh(g2 * x / vf) }
    private func softStepB(_ x: Float) -> Float {
        let p = adaaB.prevX, dx = x - p
        let y = abs(dx) < ADAA1.eps ? softShapeB((x + p) * 0.5) : (softF1B(x) - softF1B(p)) / dx
        adaaB.prevX = x; return y
    }
    // softBounded: y = Vf·tanh(g·x/Vf)  (drops the +x term → SATURATES toward ±Vf → sustain. Big Muff).
    @inline(__always) private func bndShapeA(_ x: Float) -> Float { vf * tanhf(g * x / vf) }
    @inline(__always) private func bndF1A(_ x: Float) -> Float { (vf * vf / g) * ADAA1.lnCosh(g * x / vf) }
    private func bndStepA(_ x: Float) -> Float {
        let p = adaaA.prevX, dx = x - p
        let y = abs(dx) < ADAA1.eps ? bndShapeA((x + p) * 0.5) : (bndF1A(x) - bndF1A(p)) / dx
        adaaA.prevX = x; return y
    }
    @inline(__always) private func bndShapeB(_ x: Float) -> Float { vf * tanhf(g2 * x / vf) }
    @inline(__always) private func bndF1B(_ x: Float) -> Float { (vf * vf / g2) * ADAA1.lnCosh(g2 * x / vf) }
    private func bndStepB(_ x: Float) -> Float {
        let p = adaaB.prevX, dx = x - p
        let y = abs(dx) < ADAA1.eps ? bndShapeB((x + p) * 0.5) : (bndF1B(x) - bndF1B(p)) / dx
        adaaB.prevX = x; return y
    }
    @inline(__always) private func hardShape(_ x: Float) -> Float { vf * ADAA1.hardClip(g * x / vf) }
    @inline(__always) private func hardF1(_ x: Float) -> Float { (vf * vf / g) * ADAA1.clipF1(g * x / vf) }
    private func hardStep(_ x: Float) -> Float {
        let p = adaaA.prevX, dx = x - p
        let y = abs(dx) < ADAA1.eps ? hardShape((x + p) * 0.5) : (hardF1(x) - hardF1(p)) / dx
        adaaA.prevX = x; return y
    }
    // asym (Klon): soft-feedback per half → clean ramp INTRINSIC, even-harmonic grit only on peaks.
    @inline(__always) private func asymShape(_ x: Float) -> Float {
        x >= 0 ? x + vf * tanhf(g * x / vf) : x + vfNeg * tanhf(g * x / vfNeg)
    }
    @inline(__always) private func asymF1(_ x: Float) -> Float {
        x >= 0 ? 0.5 * x * x + (vf * vf / g) * ADAA1.lnCosh(g * x / vf)
               : 0.5 * x * x + (vfNeg * vfNeg / g) * ADAA1.lnCosh(g * x / vfNeg)
    }
    private func asymStep(_ x: Float) -> Float {
        let p = adaaA.prevX, dx = x - p
        let y = abs(dx) < ADAA1.eps ? asymShape((x + p) * 0.5) : (asymF1(x) - asymF1(p)) / dx
        adaaA.prevX = x; return y
    }

    /// Dispatch the oversampled, ADAA-anti-aliased clip onto `s` at the model's OS factor.
    private func applyClip(_ s: UnsafeMutablePointer<Float>, _ n: Int, _ shape: (Float) -> Float) {
        switch osFactor {
        case 8: os8.process(s, n, shape)
        case 4: os4.process(s, n, shape)
        default: os2.process(s, n, shape)
        }
    }

    // ---- Audio thread ------------------------------------------------------------------------
    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard n > 0, n <= maxBlk else { return }

        // 1) Input HPF (mid-hump) + optional pre-clip LPF (feedback-cap treble roll into the clipper).
        for i in 0..<n { s[i] = inputHP.process(s[i]) }
        if hasPreLP { for i in 0..<n { s[i] = preLP.process(s[i]) } }

        // 2) Drive → fixed-threshold clipper, oversampled + ADAA. The topology BRANCHES here.
        switch clipMode {
        case .softFeedback:
            if stages == 2 { applyClip(s, n) { self.softStepB(self.softStepA($0)) } }
            else           { applyClip(s, n) { self.softStepA($0) } }

        case .softBounded:
            if stages == 2 { applyClip(s, n) { self.bndStepB(self.bndStepA($0)) } }
            else           { applyClip(s, n) { self.bndStepA($0) } }

        case .hardShunt:
            applyClip(s, n) { self.hardStep($0) }

        case .asym:
            // Soft-feedback asym already carries the clean ramp (cleanMix = 0), so this is a pure wet
            // pass. The delay-matched clean ring is retained for the topology but contributes nothing
            // while cleanMix == 0 (kept so a future parallel-clean voicing can re-enable it cheaply).
            if cleanMix > 0, let cl = clean?.baseAddress, let rb = ring?.baseAddress {
                for i in 0..<n { cl[i] = s[i] }
                applyClip(s, n) { self.asymStep($0) }
                let cap = ringCap, L = min(osLatency, ringCap - 1), cmix = cleanMix, wmix = wetMix
                var w = ringW
                for i in 0..<n {
                    rb[w] = cl[i]
                    let rd = w - L
                    let cd = rb[rd >= 0 ? rd : rd + cap]
                    w += 1; if w >= cap { w = 0 }
                    s[i] = cmix * cd + wmix * s[i]
                }
                ringW = w
            } else {
                applyClip(s, n) { self.asymStep($0) }
            }
        }

        // 3) DC blocker (one-pole ~19 Hz) after asymmetric nonlinearities.
        if needsDC {
            var x1 = dcX1, y1 = dcY1
            for i in 0..<n {
                let x = s[i].isFinite ? s[i] : 0
                let y = x - x1 + 0.9975 * y1
                x1 = x; y1 = y; s[i] = y
            }
            dcX1 = x1; dcY1 = y1
        }

        // 4) Tone stack (3 biquads, identity where unused) → 5) global anti-fizz smoothing LPF →
        //    6) output level, with a finite guard.
        let lg = outGain
        for i in 0..<n {
            var v = bq0.process(s[i]); v = bq1.process(v); v = bq2.process(v)
            v = smoothLP.process(v)
            v *= lg
            s[i] = v.isFinite ? v : 0
        }
    }
}
