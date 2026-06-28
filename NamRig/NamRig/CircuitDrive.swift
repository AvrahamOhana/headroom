//
//  CircuitDrive.swift
//  NamRig — circuit-derived overdrive / distortion / fuzz pedal library.
//
//  One DSP engine + a data table (`PedalModel`) = the whole library. Unlike the generic
//  `DriveBlock` (one tanh/clip/fuzz shape), `CircuitDriveBlock` models the *topology* of real
//  pedal circuits, and the clip stage genuinely BRANCHES in code — three different algorithms,
//  not value presets:
//
//     • softFeedback  y = x + Vf·tanh(g·x/Vf)        (op-amp + diodes in the FEEDBACK loop: TS,
//                                                      cascaded for the Big Muff). Small signals see
//                                                      gain (1+g); large signals see incremental gain
//                                                      ~1 → a compander → sustain. NOT bounded-limiting.
//     • hardShunt     y = Vf·clip(g·x/Vf)            (diodes to GROUND after the gain stage: RAT, DS-1).
//                                                      Hard clamp at ±Vf → square-ish, strong high-order
//                                                      odd harmonics.
//     • asym          y = x≥0 ? Vp·tanh(g·x/Vp)      (germanium, different drop per half: Klon). Produces
//                            : Vn·tanh(g·x/Vn)        a DC offset → DC blocker after it.
//
//  Signal flow (per the FX roadmap "Overdrive library" section):
//     input HPF (mid-hump / low cleanup)
//       → optional pre-clip LPF (feedback-cap treble roll into the clipper)
//       → drive gain → FIXED-threshold clipper      [wrapped in Oversampler + ADAA1: 2× soft, 8× hard]
//       → DC blocker (one-pole ~19 Hz, asymmetric models only)
//       → tone biquads (per voicing)
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
nonisolated enum ClipMode: Sendable { case softFeedback, hardShunt, asym }

/// Post-clip tone-stack voicing. Each maps the 0…1 `tone` knob to its own filter behavior.
nonisolated enum ToneType: Sendable {
    case lowpassTilt   // TS: post LPF (swept) + mild high-shelf tilt
    case ratFilter     // RAT: single LPF that DARKENS as the knob is turned up (inverted sweep)
    case scoopTilt     // DS-1: bass/treble tilt (two shelves) + a fixed mid scoop
    case klonTilt      // Klon: treble-tilt high shelf only
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
    static let all: [PedalModel] = [
        // 0 — Green Screamer (TS808): mid-hump HPF → soft Si-in-feedback → the BRIGHTEST/most open
        //     top of the library (soft clip keeps it fundamental-dominated) + slight presence tilt.
        PedalModel(name: "Green Screamer", inputHz: 720, gainRange: 2...90, clip: .softFeedback,
                   diodeVf: 0.6, asymVf: 0.6, feedbackCapHz: 0, tone: .lowpassTilt,
                   toneLoHz: 2500, toneHiHz: 8000, scoopHz: 0, scoopDb: 0,
                   makeup: 0.55, oversample: 2, stages: 1, needsDC: false),

        // 1 — Rodent (RAT): light HPF → very-high gain + feedback-cap treble roll → hard Si to ground →
        //     "Filter" LPF (darker as it's turned up). Darker top than the TS. 8× OS.
        PedalModel(name: "Rodent", inputHz: 32, gainRange: 6...800, clip: .hardShunt,
                   diodeVf: 0.6, asymVf: 0.6, feedbackCapHz: 2400, tone: .ratFilter,
                   toneLoHz: 700, toneHiHz: 4500, scoopHz: 0, scoopDb: 0,
                   makeup: 0.32, oversample: 8, stages: 1, needsDC: false),

        // 2 — Modern Distortion (DS-1): two-stage gain → hard Si clip → tone LPF + treble tilt + mid
        //     scoop. Darker top than the TS. 8× OS.
        PedalModel(name: "Modern Distortion", inputHz: 50, gainRange: 8...500, clip: .hardShunt,
                   diodeVf: 0.6, asymVf: 0.6, feedbackCapHz: 5000, tone: .scoopTilt,
                   toneLoHz: 1500, toneHiHz: 4000, scoopHz: 600, scoopDb: -7,
                   makeup: 0.36, oversample: 8, stages: 1, needsDC: false),

        // 3 — Centaur Gold (Klon): parallel CLEAN + clipped(Ge soft asym) branches, treble tilt.
        //     Clean branch is delay-matched to the OS/ADAA wet (no comb). 4× OS.
        PedalModel(name: "Centaur Gold", inputHz: 40, gainRange: 3...120, clip: .asym,
                   diodeVf: 0.30, asymVf: 0.38, feedbackCapHz: 0, tone: .klonTilt,
                   toneLoHz: 0, toneHiHz: 3000, scoopHz: 0, scoopDb: 0,
                   makeup: 0.70, oversample: 4, stages: 1, needsDC: true),

        // 4 — Muffin Fuzz (Big Muff): two cascaded soft-clip stages → mid SCOOP ~-13.5 dB @1 kHz. 8× OS.
        PedalModel(name: "Muffin Fuzz", inputHz: 80, gainRange: 10...300, clip: .softFeedback,
                   diodeVf: 0.6, asymVf: 0.6, feedbackCapHz: 0, tone: .muffScoop,
                   toneLoHz: 800, toneHiHz: 6000, scoopHz: 1000, scoopDb: -13.5,
                   makeup: 0.40, oversample: 8, stages: 2, needsDC: true),
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
        inputHP.reset(); preLP.reset(); bq0.reset(); bq1.reset(); bq2.reset()
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

        // Klon parallel blend (drive raises the clipped amount on top of an always-present clean).
        if m.clip == .asym { cleanMix = 1; wetMix = lerp(0.0, 0.8, d) }
        else { cleanMix = 0; wetMix = 1 }

        outGain = m.makeup * min(max(0, level), 1)

        // Input HPF (mid-hump / low cleanup) + optional pre-clip LPF (feedback-cap treble roll).
        inputHP.setHighpass(freq: min(m.inputHz, sr * 0.45), q: 0.707, sr: sr)
        if hasPreLP { preLP.setLowpass(freq: min(m.feedbackCapHz, sr * 0.45), q: 0.707, sr: sr) }
        else { setIdentity(&preLP) }

        // Tone stack.
        switch m.tone {
        case .lowpassTilt:   // TS — swept LPF darkens toward 0, plus a mild brightness tilt.
            bq0.setLowpass(freq: lerp(m.toneLoHz, m.toneHiHz, t), q: 0.707, sr: sr)
            bq1.setHighShelf(freq: 2000, gainDb: 3, sr: sr)
            setIdentity(&bq2)
        case .ratFilter:     // RAT — turning UP darkens (inverted LPF sweep).
            bq0.setLowpass(freq: lerp(m.toneHiHz, m.toneLoHz, t), q: 0.707, sr: sr)
            setIdentity(&bq1); setIdentity(&bq2)
        case .scoopTilt:     // DS-1 — tone LPF sweep + treble tilt + fixed mid scoop.
            bq0.setLowpass(freq: lerp(m.toneLoHz, m.toneHiHz, t), q: 0.707, sr: sr)
            bq1.setHighShelf(freq: 3000, gainDb: lerp(-6, 6, t), sr: sr)
            bq2.setPeaking(freq: m.scoopHz, gainDb: m.scoopDb, q: 1.0, sr: sr)
        case .klonTilt:      // Klon — treble tilt.
            bq0.setHighShelf(freq: m.toneHiHz, gainDb: lerp(-3, 8, t), sr: sr)
            setIdentity(&bq1); setIdentity(&bq2)
        case .muffScoop:     // Big Muff — fixed ~-13.5 dB scoop @1 kHz + a bright/dark LPF sweep.
            bq0.setPeaking(freq: m.scoopHz, gainDb: m.scoopDb, q: 0.9, sr: sr)
            bq1.setLowpass(freq: lerp(m.toneLoHz, m.toneHiHz, t), q: 0.707, sr: sr)
            setIdentity(&bq2)
        }

        if resetFilters { inputHP.reset(); preLP.reset(); bq0.reset(); bq1.reset(); bq2.reset() }
    }

    // ---- Clip shapers + their antiderivatives (ADAA1, inlined, no closures) -------------------
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
    @inline(__always) private func hardShape(_ x: Float) -> Float { vf * ADAA1.hardClip(g * x / vf) }
    @inline(__always) private func hardF1(_ x: Float) -> Float { (vf * vf / g) * ADAA1.clipF1(g * x / vf) }
    private func hardStep(_ x: Float) -> Float {
        let p = adaaA.prevX, dx = x - p
        let y = abs(dx) < ADAA1.eps ? hardShape((x + p) * 0.5) : (hardF1(x) - hardF1(p)) / dx
        adaaA.prevX = x; return y
    }
    @inline(__always) private func asymShape(_ x: Float) -> Float {
        x >= 0 ? vf * tanhf(g * x / vf) : vfNeg * tanhf(g * x / vfNeg)
    }
    @inline(__always) private func asymF1(_ x: Float) -> Float {
        x >= 0 ? (vf * vf / g) * ADAA1.lnCosh(g * x / vf) : (vfNeg * vfNeg / g) * ADAA1.lnCosh(g * x / vfNeg)
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

        case .hardShunt:
            applyClip(s, n) { self.hardStep($0) }

        case .asym:
            // Parallel CLEAN + clipped (Klon). Capture clean, clip in place (OS adds `osLatency`
            // samples of delay to the wet), then DELAY-MATCH the clean copy through the ring and sum.
            if let cl = clean?.baseAddress, let rb = ring?.baseAddress {
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

        // 4) Tone stack (3 biquads, identity where unused) + 5) output level, with a finite guard.
        let lg = outGain
        for i in 0..<n {
            var v = bq0.process(s[i]); v = bq1.process(v); v = bq2.process(v)
            v *= lg
            s[i] = v.isFinite ? v : 0
        }
    }
}
