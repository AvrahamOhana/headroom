//
//  Wah.swift
//  NamRig — a wah block: a resonant bandpass whose centre frequency sweeps ~400 Hz … 2.2 kHz.
//  Drive it with an EXPRESSION PEDAL (map a MIDI CC → the `.wah` param), or switch to AUTO mode
//  where an envelope follower opens the filter with your picking dynamics.
//
//  DSP: a zero-delay-feedback (TPT / Zavalishin) state-variable filter — unconditionally stable
//  under per-sample frequency modulation, which is exactly what a swept wah needs. Bandpass output,
//  mostly-wet. RT-safe: no allocation in process, denormal-flushed integrator state, `nonisolated`
//  so it compiles under the project's `-default-isolation=MainActor`.
//

import Foundation

nonisolated final class WahBlock: AudioBlock {
    var position: Float = 0.5      // 0 heel (dark) … 1 toe (bright) — the pedal
    var auto: Bool = false         // auto-wah: envelope follower drives the sweep
    var sensitivity: Float = 0.5   // auto-wah sensitivity (0…1)
    var mix: Float = 0.92          // mostly wet (a wah is a series filter)

    private var fs: Float = 48000
    private let loHz: Float = 400, hiHz: Float = 2200
    private let q: Float = 4.0     // resonance ("vocal" peak)
    private let wetBoost: Float = 1.6

    // SVF integrator state.
    private var ic1: Float = 0, ic2: Float = 0
    // Envelope follower (auto mode).
    private var env: Float = 0
    private var atk: Float = 0.99, rel: Float = 0.9995

    // No `.wah` default yet — the BlockKind case + chain/UI/MIDI wiring is added at integration time.
    override init(kind: BlockKind) { super.init(kind: kind) }

    override func prepare(sampleRate: Double, maxBlock: Int) {
        fs = Float(sampleRate)
        atk = expf(-1.0 / (0.005 * fs))   // ~5 ms attack
        rel = expf(-1.0 / (0.080 * fs))   // ~80 ms release
        reset()
    }
    override func reset() { ic1 = 0; ic2 = 0; env = 0 }

    /// One TPT-SVF sample → bandpass output. `g = tan(π·fc/fs)`, `k = 1/Q`.
    @inline(__always) private func bandpass(_ x: Float, _ g: Float, _ k: Float) -> Float {
        let a1 = 1 / (1 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3        // bandpass
        let v2 = ic2 + a2 * ic1 + a3 * v3  // lowpass
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        if abs(ic1) < 1e-18 { ic1 = 0 }
        if abs(ic2) < 1e-18 { ic2 = 0 }
        return v1
    }

    override func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        let k = 1 / q
        let mx = min(max(mix, 0), 1)
        let nyq = fs * 0.45
        if auto {
            let sens = 1 + min(max(sensitivity, 0), 1) * 9
            for i in 0..<n {
                let x = s[i]
                let a = abs(x)
                env = a > env ? (atk * env + (1 - atk) * a) : (rel * env + (1 - rel) * a)
                let pos = min(max(env * sens, 0), 1)
                let fc = min(loHz * powf(hiHz / loHz, pos), nyq)
                let g = tanf(Float.pi * fc / fs)
                let y = bandpass(x, g, k) * wetBoost
                s[i] = x * (1 - mx) + y * mx
            }
        } else {
            let pos = min(max(position, 0), 1)
            let fc = min(loHz * powf(hiHz / loHz, pos), nyq)
            let g = tanf(Float.pi * fc / fs)
            for i in 0..<n {
                let y = bandpass(s[i], g, k) * wetBoost
                s[i] = s[i] * (1 - mx) + y * mx
            }
        }
    }
}
