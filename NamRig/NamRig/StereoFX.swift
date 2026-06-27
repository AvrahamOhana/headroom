//
//  StereoFX.swift
//  NamRig — Tier-1 stereo widening: mono guitar chain → wide stereo image.
//
//  The amp chain (SignalChain in Blocks.swift) stays MONO. After it, these time/space
//  effects turn that single dry signal into a STEREO field so the output sounds big and wide.
//  They are mono-in → stereo-out, so they are NOT AudioBlock subclasses (those are in-place mono).
//
//  WET-ONLY CONTRACT: `processStereo` OVERWRITES outL/outR with this effect's *wet* stereo
//  contribution (already scaled by its mix). The host adds the centered dry exactly ONCE and sums
//  every effect's wet on top — see the integration notes at the bottom of this file. This avoids
//  double-counting the dry when several stereo effects run in parallel, and makes "FX off →
//  bit-identical mono" trivial (the host just writes dry to both channels).
//
//  Threading / RT-safety (identical discipline to Blocks.swift):
//    • ALL buffers are pre-allocated in `prepare`. `processStereo` does zero allocation, zero locks.
//    • Params are plain values (benign races, exactly like the mono blocks' mix/feedback knobs).
//    • Recursive feedback lines flush denormals (reverb tails would otherwise stall the audio thread).
//

import Foundation

/// Equal-power pan law. pan ∈ [−1, 1]; θ = (pan+1)·π/4 so center = (0.707, 0.707),
/// hard left = (1, 0), hard right = (0, 1). Keeps perceived loudness constant across the pan sweep.
@inline(__always)
func equalPowerPan(_ pan: Float) -> (l: Float, r: Float) {
    let p = min(max(pan, -1), 1)
    let theta = (p + 1) * (Float.pi / 4)
    return (cosf(theta), sinf(theta))
}

// ============================================================================================
//  PingPongDelay — mono in → L/R out. Echoes bounce L↔R and decay with feedback.
// ============================================================================================
/// Cross-coupled dual delay line. An impulse appears on L after one delay, R after two, L after
/// three… (full bounce), decaying by `feedback` each hop. `spread` morphs between a centered mono
/// slap (0) and a full L↔R bounce (100) by blending the self-feedback and cross-feedback paths.
final class PingPongDelay: @unchecked Sendable {
    // Params — plain values, set off the audio thread (benign race, like DelayBlock).
    var timeMs: Float = 350       // echo spacing
    var feedbackPct: Float = 35   // 0…~99 — regeneration per hop
    var mixPct: Float = 30        // wet send level (0 = silent wet, 100 = full wet)
    var spreadPct: Float = 100    // 0 = mono slap (centered), 100 = full L↔R bounce

    private var sr: Float = 48000
    private var ringL: UnsafeMutableBufferPointer<Float>?
    private var ringR: UnsafeMutableBufferPointer<Float>?
    private var cap = 0
    private var w = 0             // shared write head

    /// Pre-allocate both delay rings (up to 2 s, like the mono DelayBlock).
    func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate)
        let need = Int(sampleRate * 2) + 2
        if ringL == nil || cap != need {
            ringL?.deallocate(); ringR?.deallocate()
            let a = UnsafeMutableBufferPointer<Float>.allocate(capacity: need); a.initialize(repeating: 0)
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: need); b.initialize(repeating: 0)
            ringL = a; ringR = b; cap = need
        }
        w = 0
    }

    func reset() {
        if let p = ringL?.baseAddress { for i in 0..<cap { p[i] = 0 } }
        if let p = ringR?.baseAddress { for i in 0..<cap { p[i] = 0 } }
        w = 0
    }

    /// Write this effect's WET stereo contribution into outL/outR (overwrite).
    func processStereo(_ inMono: UnsafePointer<Float>,
                       _ outL: UnsafeMutablePointer<Float>,
                       _ outR: UnsafeMutablePointer<Float>,
                       _ n: Int) {
        guard let L = ringL?.baseAddress, let R = ringR?.baseAddress, cap > 1 else {
            for i in 0..<n { outL[i] = 0; outR[i] = 0 }
            return
        }
        let d = min(max(1, Int(timeMs / 1000 * sr)), cap - 1)
        let fb = min(max(feedbackPct * 0.01, 0), 0.99)      // clamp < 1 → never blows up
        let mix = max(mixPct * 0.01, 0)
        let s = min(max(spreadPct * 0.01, 0), 1)
        let selfFb = fb * (1 - s)                            // straight (self) regeneration
        let crossFb = fb * s                                 // bounced (cross) regeneration
        var wi = w
        for i in 0..<n {
            let ri = wi - d
            let rIdx = ri >= 0 ? ri : ri + cap
            let echoL = L[rIdx]
            let echoR = R[rIdx]
            let x = inMono[i]
            // Input feeds L fully; the R feed fades out as spread → 1 (so spread=1 = clean bounce,
            // spread=0 = identical lines on both channels = centered mono slap).
            L[wi] = x + echoL * selfFb + echoR * crossFb
            R[wi] = x * (1 - s) + echoR * selfFb + echoL * crossFb
            outL[i] = echoL * mix
            outR[i] = echoR * mix
            wi += 1; if wi >= cap { wi = 0 }
        }
        w = wi
    }

    deinit { ringL?.deallocate(); ringR?.deallocate() }
}

// ============================================================================================
//  StereoReverb — mono in → decorrelated L/R. Two Freeverb tanks, right tuned +23 samples.
// ============================================================================================
/// Stereo Freeverb: the SAME mono input drives two parallel comb/allpass tanks whose delay
/// lengths differ by the canonical Schroeder/Freeverb `stereospread` (+23 samples on the right),
/// so the two channels are genuinely DEcorrelated (a wide field, not dual-mono). `width` cross-
/// mixes the two tanks (1 = max width / fully separate, 0 = collapsed to mono). All recursive
/// lines flush denormals so a long tail can't stall the audio thread.
final class StereoReverb: @unchecked Sendable {
    // Params — plain values (benign race, like ReverbBlock).
    var decayPct: Float = 70      // room size → comb feedback
    var dampPct: Float = 30       // HF damping in the tail
    var mixPct: Float = 25        // wet send level (0 = silent wet, 100 = full wet)
    var widthPct: Float = 100     // 0 = mono, 100 = full stereo spread

    // Canonical Freeverb tunings @44.1k; right = left + 23 (stereospread). Scaled to SR in prepare.
    private static let combBase = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let apBase   = [556, 441, 341, 225]
    private static let stereoSpread = 23
    private let inputGain: Float = 0.015          // Freeverb fixed input gain
    private let flushEps: Float = 1e-18           // denormal clamp threshold

    // Left tank.
    private var combL: [UnsafeMutableBufferPointer<Float>] = []
    private var combIdxL: [Int] = []
    private var combStoreL: [Float] = []
    private var apL: [UnsafeMutableBufferPointer<Float>] = []
    private var apIdxL: [Int] = []
    // Right tank.
    private var combR: [UnsafeMutableBufferPointer<Float>] = []
    private var combIdxR: [Int] = []
    private var combStoreR: [Float] = []
    private var apR: [UnsafeMutableBufferPointer<Float>] = []
    private var apIdxR: [Int] = []

    func prepare(sampleRate: Double, maxBlock: Int) {
        freeBuffers()
        let scale = Float(sampleRate) / 44100
        func ring(_ tuning: Int) -> UnsafeMutableBufferPointer<Float> {
            let len = max(1, Int(Float(tuning) * scale))
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: len); b.initialize(repeating: 0)
            return b
        }
        for t in Self.combBase {
            combL.append(ring(t));                     combIdxL.append(0); combStoreL.append(0)
            combR.append(ring(t + Self.stereoSpread)); combIdxR.append(0); combStoreR.append(0)
        }
        for t in Self.apBase {
            apL.append(ring(t));                     apIdxL.append(0)
            apR.append(ring(t + Self.stereoSpread)); apIdxR.append(0)
        }
    }

    func reset() {
        for b in combL { if let p = b.baseAddress { for i in 0..<b.count { p[i] = 0 } } }
        for b in combR { if let p = b.baseAddress { for i in 0..<b.count { p[i] = 0 } } }
        for b in apL   { if let p = b.baseAddress { for i in 0..<b.count { p[i] = 0 } } }
        for b in apR   { if let p = b.baseAddress { for i in 0..<b.count { p[i] = 0 } } }
        for i in combIdxL.indices { combIdxL[i] = 0; combStoreL[i] = 0 }
        for i in combIdxR.indices { combIdxR[i] = 0; combStoreR[i] = 0 }
        for i in apIdxL.indices { apIdxL[i] = 0 }
        for i in apIdxR.indices { apIdxR[i] = 0 }
    }

    private func freeBuffers() {
        for b in combL { b.deallocate() }; for b in combR { b.deallocate() }
        for b in apL { b.deallocate() };   for b in apR { b.deallocate() }
        combL = []; combIdxL = []; combStoreL = []; apL = []; apIdxL = []
        combR = []; combIdxR = []; combStoreR = []; apR = []; apIdxR = []
    }

    /// Write this effect's WET stereo contribution into outL/outR (overwrite).
    func processStereo(_ inMono: UnsafePointer<Float>,
                       _ outL: UnsafeMutablePointer<Float>,
                       _ outR: UnsafeMutablePointer<Float>,
                       _ n: Int) {
        guard !combL.isEmpty else { for i in 0..<n { outL[i] = 0; outR[i] = 0 }; return }
        let fb = 0.7 + min(max(decayPct * 0.01, 0), 1) * 0.28      // roomsize → feedback (Freeverb)
        let d1 = min(max(dampPct * 0.01, 0), 1) * 0.4              // damping
        let d2 = 1 - d1
        let mix = max(mixPct * 0.01, 0)
        let width = min(max(widthPct * 0.01, 0), 1)
        let wet1 = width * 0.5 + 0.5                                // self channel (Freeverb width law)
        let wet2 = (1 - width) * 0.5                                // bleed of the opposite tank
        let g = inputGain, eps = flushEps
        let nC = combL.count, nA = apL.count

        for i in 0..<n {
            let input = inMono[i] * g
            var oL: Float = 0, oR: Float = 0

            // Parallel comb banks (one mono input → two differently-tuned tanks).
            for c in 0..<nC {
                // Left.
                let pL = combL[c].baseAddress!, lenL = combL[c].count
                var iL = combIdxL[c]
                let yL = pL[iL]
                var stL = yL * d2 + combStoreL[c] * d1
                if abs(stL) < eps { stL = 0 }                       // denormal flush
                combStoreL[c] = stL
                pL[iL] = input + stL * fb
                iL += 1; if iL >= lenL { iL = 0 }
                combIdxL[c] = iL
                oL += yL
                // Right (tunings offset by +23 → decorrelated).
                let pR = combR[c].baseAddress!, lenR = combR[c].count
                var iR = combIdxR[c]
                let yR = pR[iR]
                var stR = yR * d2 + combStoreR[c] * d1
                if abs(stR) < eps { stR = 0 }
                combStoreR[c] = stR
                pR[iR] = input + stR * fb
                iR += 1; if iR >= lenR { iR = 0 }
                combIdxR[c] = iR
                oR += yR
            }

            // Series allpass diffusers.
            for a in 0..<nA {
                let pL = apL[a].baseAddress!, lenL = apL[a].count
                var iL = apIdxL[a]
                let bL = pL[iL]
                let yL = -oL + bL
                var wL = oL + bL * 0.5
                if abs(wL) < eps { wL = 0 }
                pL[iL] = wL
                iL += 1; if iL >= lenL { iL = 0 }
                apIdxL[a] = iL
                oL = yL

                let pR = apR[a].baseAddress!, lenR = apR[a].count
                var iR = apIdxR[a]
                let bR = pR[iR]
                let yR = -oR + bR
                var wR = oR + bR * 0.5
                if abs(wR) < eps { wR = 0 }
                pR[iR] = wR
                iR += 1; if iR >= lenR { iR = 0 }
                apIdxR[a] = iR
                oR = yR
            }

            // Width cross-mix + wet send level.
            outL[i] = (oL * wet1 + oR * wet2) * mix
            outR[i] = (oR * wet1 + oL * wet2) * mix
        }
    }

    deinit { freeBuffers() }
}

// ============================================================================================
//  INTEGRATION (AudioEngine) — see the handoff report. In brief:
//
//    1. Make the source node STEREO: build a 2-ch non-interleaved AVAudioFormat at the engine SR
//       and connect source → mainMixer with THAT format (instead of monoFormat).
//    2. Run the existing MONO chain on `context.scratch` exactly as today → `s` is the dry mono.
//    3. If stereo FX OFF: write `s` to BOTH output channels (centered) → bit-identical mono. DONE.
//    4. If ON: into two pre-allocated stereo scratch pairs,
//           ping.processStereo(s, ppL, ppR, n)        // wet ping-pong
//           rev.processStereo (s, rvL, rvR, n)        // wet reverb (parallel, same dry)
//       then  outL = s + ppL + rvL ;  outR = s + ppR + rvR   (dry added ONCE, centered)
//       then apply outputGain + finite/clamp, write out[0]=L, out[1]=R.
// ============================================================================================
