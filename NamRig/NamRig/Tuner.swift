//
//  Tuner.swift
//  NamRig — YIN monophonic pitch detection + note naming for the chromatic tuner.
//  Runs off the audio thread (on a timer), reading the dry-input analysis buffer.
//

import Foundation

enum Tuner {
    static let minLag = 48     // ~1000 Hz ceiling
    static let maxLag = 768    // ~62.5 Hz floor (covers low E and some drop tunings)
    static let window = 2048
    static var framesNeeded: Int { window + maxLag }

    /// YIN pitch detection. `x` must hold at least `framesNeeded` samples (oldest → newest).
    static func detect(_ x: [Float], sampleRate: Float) -> (freq: Float, clarity: Float)? {
        guard x.count >= window + maxLag else { return nil }

        var rms: Float = 0
        for i in 0..<window { rms += x[i] * x[i] }
        if (rms / Float(window)).squareRoot() < 0.003 { return nil }   // below noise floor

        // 1) difference function
        var d = [Float](repeating: 0, count: maxLag)
        for tau in minLag..<maxLag {
            var sum: Float = 0
            for i in 0..<window {
                let diff = x[i] - x[i + tau]
                sum += diff * diff
            }
            d[tau] = sum
        }
        // 2) cumulative mean normalized difference
        var cmnd = [Float](repeating: 1, count: maxLag)
        var running: Float = 0
        for tau in 1..<maxLag {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }
        // 3) first dip below threshold (octave-safe), else global min
        let threshold: Float = 0.15
        var best = -1
        var tau = minLag
        while tau < maxLag - 1 {
            if cmnd[tau] < threshold {
                while tau + 1 < maxLag && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                best = tau; break
            }
            tau += 1
        }
        if best < 0 {
            var lo: Float = 1, loTau = -1
            for t in minLag..<maxLag where cmnd[t] < lo { lo = cmnd[t]; loTau = t }
            guard lo < 0.3 else { return nil }
            best = loTau
        }
        // 4) parabolic interpolation
        var t = Float(best)
        if best > minLag && best < maxLag - 1 {
            let a = cmnd[best - 1], b = cmnd[best], c = cmnd[best + 1]
            let denom = a + c - 2 * b
            if abs(denom) > 1e-9 { t += (a - c) / (2 * denom) }
        }
        let freq = sampleRate / t
        guard freq > 40, freq < 1200 else { return nil }
        return (freq, 1 - cmnd[best])
    }

    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Frequency → nearest note name (with octave) + cents offset (−50…+50).
    static func note(forFreq freq: Float) -> (name: String, cents: Int) {
        let midi = 69 + 12 * log2f(freq / 440)
        let nearest = Int(midi.rounded())
        let cents = Int(((midi - Float(nearest)) * 100).rounded())
        let name = names[((nearest % 12) + 12) % 12]
        return ("\(name)\(nearest / 12 - 1)", cents)
    }
}
