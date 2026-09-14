//
//  blocks_test.swift — compiles the REAL Blocks.swift / Wah.swift / ReverbAlgorithms.swift (not
//  mirrors) against a stub NAMModel and checks the DSP numerically. Run on the Mac:
//
//    swiftc -O -parse-as-library -default-isolation MainActor \
//      tools/blocks_test.swift NamRig/NamRig/Blocks.swift NamRig/NamRig/Wah.swift \
//      NamRig/NamRig/ReverbAlgorithms.swift -o /tmp/blocks_test && /tmp/blocks_test
//
import Foundation

/// Stand-in for the Obj-C bridge: a "model" that is a mild tanh drive, so AmpBlock has something to run.
nonisolated final class NAMModel: @unchecked Sendable {
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int32) {
        for i in 0..<Int(frames) { output[i] = tanhf(input[i] * 3) }
    }
}

nonisolated let sr = 48000.0
nonisolated func db(_ x: Float) -> Float { x > 1e-9 ? 20 * log10f(x) : -180 }
nonisolated func rms(_ x: ArraySlice<Float>) -> Float { sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }
nonisolated func peak(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }
nonisolated func run(_ b: AudioBlock, _ x: [Float], block: Int = 256) -> [Float] {
    var y = x
    y.withUnsafeMutableBufferPointer { p in
        var i = 0
        while i < p.count { let n = min(block, p.count - i); b.render(p.baseAddress! + i, n); i += n }
    }
    return y
}
nonisolated(unsafe) var fails = 0
nonisolated func check(_ ok: Bool, _ msg: String) { print((ok ? "  ✓ " : "  ✗ ") + msg); if !ok { fails += 1 } }

@main struct Main {
    static func main() {
        let N = Int(sr) * 2
        let sine = (0..<N).map { 0.5 * sinf(2 * .pi * 440 * Float($0) / Float(sr)) }

        print("Gate")
        do {
            let g = GateBlock(); g.prepare(sampleRate: sr, maxBlock: 256); g.reset()
            g.thresholdDb = -40; g.releaseMs = 80; g.rangeDb = -80
            var x = [Float](repeating: 0, count: N)
            var seed: UInt32 = 1
            for i in 0..<N {                                    // −60 dB hiss everywhere, −10 dB note in the middle second
                seed = seed &* 1664525 &+ 1013904223
                x[i] = (Float(seed) / Float(UInt32.max) - 0.5) * 0.002
                if i >= N / 4 && i < 3 * N / 4 { x[i] += 0.3 * sinf(2 * .pi * 220 * Float(i) / Float(sr)) }
            }
            let y = run(g, x)
            let hissIn = rms(x[0..<(N / 4 - 4800)]), hissOut = rms(y[2400..<(N / 4 - 4800)])
            check(db(hissOut) < db(hissIn) - 50, "hiss attenuated \(Int(db(hissIn) - db(hissOut))) dB (want ≥ 50)")
            let noteIn = rms(x[(N / 4 + 4800)..<(3 * N / 4 - 4800)]), noteOut = rms(y[(N / 4 + 4800)..<(3 * N / 4 - 4800)])
            check(abs(db(noteOut) - db(noteIn)) < 0.5, "note passes unchanged (Δ \(String(format: "%.2f", db(noteOut) - db(noteIn))) dB)")
            let openAt = y[(N / 4)..<N].firstIndex { abs($0) > 0.1 }.map { $0 - N / 4 } ?? -1
            check(openAt >= 0 && openAt < 200, "opens within \(openAt) samples (want < 200)")
            let tail = y[(3 * N / 4 + Int(sr * 0.25))..<N]
            check(db(peak(tail)) < -55, "closed again after the note (tail peak \(Int(db(peak(tail)))) dB)")
            check(y.allSatisfy { $0.isFinite }, "finite")
            g.rangeDb = -20
            let y2 = run(g, x)
            let hiss2 = rms(y2[2400..<(N / 4 - 4800)])
            check(abs((db(hissIn) - db(hiss2)) - 20) < 3, "range −20 dB → expander attenuates \(Int(db(hissIn) - db(hiss2))) dB")
        }

        print("Compressor")
        do {
            let c = CompressorBlock(); c.prepare(sampleRate: sr, maxBlock: 256); c.reset()
            c.thresholdDb = -18; c.ratio = 4; c.setTimes(attackMs: 5, releaseMs: 50); c.makeup = 1
            let y = run(c, sine)                                 // −6 dBFS peak sine, 12 dB over → GR = 9 dB
            let outDb = db(peak(y[(N / 2)..<N]))
            check(abs(outDb - (-15)) < 1.0, "−6 dB in → \(String(format: "%.1f", outDb)) dB out (want −15 ± 1)")
            check(c.gainReductionDb < -8 && c.gainReductionDb > -10, "GR meter \(String(format: "%.1f", c.gainReductionDb)) dB")
            let quiet = sine.map { $0 * 0.05 }                 // −32 dB: below knee → unity
            let yq = run(c, quiet)
            check(abs(db(peak(yq[(N / 2)..<N])) - db(peak(quiet[(N / 2)..<N]))) < 0.1, "below threshold untouched")
        }

        print("Delay")
        do {
            let d = DelayBlock(); d.prepare(sampleRate: sr, maxBlock: 256)
            d.delaySamples = 4800; d.feedback = 0.5; d.mix = 1; d.tone = 1; d.reset()
            var imp = [Float](repeating: 0, count: N); imp[0] = 1
            let y = run(d, imp)
            let e1 = y[4700..<4900].enumerated().max { abs($0.element) < abs($1.element) }!
            check(abs(e1.element) > 0.3 && abs(e1.element) <= 1.0, "first echo at \(4700 + e1.offset) (want ≈ 4800), level \(String(format: "%.2f", e1.element))")
            let e2 = peak(y[9500..<9700])
            check(e2 < abs(e1.element), "second echo quieter (\(String(format: "%.2f", e2)))")
            d.reset(); d.feedback = 0.9
            let loud = run(d, sine)
            check(peak(loud[(N - 4800)..<N]) < 2.5, "fb 0.9 bounded (peak \(String(format: "%.2f", peak(loud[(N - 4800)..<N]))))")
            d.reset(); d.feedback = 0.4
            var glide = run(d, Array(sine[0..<24000]))
            d.delaySamples = 12000                               // time jump mid-stream: must glide, never NaN/click
            glide += run(d, Array(sine[0..<24000]))
            check(glide.allSatisfy { $0.isFinite }, "time change finite")
            var maxStep: Float = 0
            for i in 1..<glide.count { maxStep = max(maxStep, abs(glide[i] - glide[i - 1])) }
            check(maxStep < 0.6, "no click on time change (max step \(String(format: "%.2f", maxStep)))")
        }

        print("Chorus / Flanger")
        do {
            let ch = ChorusBlock(); ch.prepare(sampleRate: sr, maxBlock: 256); ch.reset(); ch.mix = 1
            let y = run(ch, sine)
            check(y.allSatisfy { $0.isFinite } && rms(y[(N / 2)..<N]) > 0.1, "chorus finite + audible")
            var diff: Float = 0; for i in N / 2..<N { diff = max(diff, abs(y[i] - sine[i])) }
            check(diff > 0.05, "chorus modulates (max Δ \(String(format: "%.2f", diff)))")
            let fl = FlangerBlock(); fl.prepare(sampleRate: sr, maxBlock: 256); fl.reset(); fl.feedback = 0.95; fl.mix = 0.5
            let z = run(fl, sine)
            check(z.allSatisfy { $0.isFinite } && peak(z[(N / 2)..<N]) < 3, "flanger fb 0.95 bounded (peak \(String(format: "%.2f", peak(z[(N / 2)..<N]))))")
        }

        print("Amp block (HPF + smoothed gains + stub model)")
        do {
            let a = AmpBlock(); a.prepare(sampleRate: sr, maxBlock: 256); a.reset()
            a.setModel(NAMModel()); a.inputGain = 1; a.makeupGain = 0.5
            let y = run(a, sine)
            check(y.allSatisfy { $0.isFinite } && rms(y[(N / 2)..<N]) > 0.1, "runs the model")
            let rumble = (0..<N).map { 0.5 * sinf(2 * .pi * 8 * Float($0) / Float(sr)) }   // 8 Hz thump
            let yr = run(a, rumble)
            check(db(rms(yr[(N / 2)..<N])) < db(rms(rumble[(N / 2)..<N])) - 15, "8 Hz rumble cut \(Int(db(rms(rumble[(N / 2)..<N])) - db(rms(yr[(N / 2)..<N])))) dB before the model")
            a.makeupGain = 2
            let step = run(a, Array(sine[0..<4800]))
            var maxStep: Float = 0; for i in 1..<step.count { maxStep = max(maxStep, abs(step[i] - step[i - 1])) }
            check(maxStep < 0.3, "makeup change zipper-free (max step \(String(format: "%.2f", maxStep)))")
        }

        print("Wah")
        do {
            let w = WahBlock(); w.prepare(sampleRate: sr, maxBlock: 256); w.mix = 1
            func peakHz(_ pos: Float) -> Float {
                w.position = pos; w.reset()
                var best: Float = 0, bestHz: Float = 0
                for hz in stride(from: 300, through: 3000, by: 100) {
                    let t = (0..<9600).map { 0.2 * sinf(2 * .pi * Float(hz) * Float($0) / Float(sr)) }
                    w.reset(); let y = run(w, t); let r = rms(y[4800..<9600])
                    if r > best { best = r; bestHz = Float(hz) }
                }
                return bestHz
            }
            let heel = peakHz(0), mid = peakHz(0.5), toe = peakHz(1)
            check(heel < mid && mid < toe, "resonance sweeps \(Int(heel)) → \(Int(mid)) → \(Int(toe)) Hz")
        }

        print("SignalChain live edit (lock-free set)")
        do {
            let b2 = BoostBlock(), b3 = BoostBlock(), b5 = BoostBlock()
            for b in [b2, b3, b5] { b.prepare(sampleRate: sr, maxBlock: 64) }
            b2.gain = 2; b3.gain = 3; b5.gain = 5; for b in [b2, b3, b5] { b.reset() }
            let ch = SignalChain()
            func one() -> Float { var v: Float = 1; withUnsafeMutablePointer(to: &v) { ch.render($0, 1) }; return v }
            check(one() == 1, "empty chain passes through")
            ch.set([b2, b3, b5]);        check(one() == 30, "set [2,3,5] → ×30")
            ch.set([b5, b2]);            check(one() == 10, "re-set [5,2] → ×10 (block removed live)")
            ch.set([b3, b3]);            check(one() == 9, "same block twice → ×9")
            ch.set([]);                  check(one() == 1, "cleared")
            check(ch.blocks.isEmpty, "blocks list tracks the set")
        }

        print("Smoother")
        do {
            var s = Smoother(0); s.prepare(sampleRate: sr, ms: 5); s.snap(); s.target = 1
            var v: Float = 0; for _ in 0..<240 { v = s.next() }              // 5 ms
            check(abs(v - 0.632) < 0.03, "reaches 63% after 1τ (\(String(format: "%.3f", v)))")
        }

        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
