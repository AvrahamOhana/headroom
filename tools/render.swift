//
//  render.swift — OFFLINE RIG RENDER. Runs a .wav through the REAL engine pieces (NAM core via the
//  Obj-C++ bridge + the real Blocks.swift) and prints measurements, so tone/noise changes can be
//  verified without a device or ears. Build + run with tools/render.sh:
//
//    tools/render.sh <model.nam> <in.wav> <out.wav> [--no-gate] [--legacy-level] [--drive dB]
//
//  --legacy-level reproduces the OLD auto-level (0.4 / probe-peak, capped at +36 dB) so the
//  before/after noise floor can be compared on the same file.
//
import Foundation
import AVFoundation

nonisolated func db(_ x: Float) -> Float { x > 1e-9 ? 20 * log10f(x) : -180 }

nonisolated func readWav(_ path: String, targetSR: Double) throws -> [Float] {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    let n = Int(buf.frameLength), ch = buf.floatChannelData![0]
    var x = (0..<n).map { ch[$0] }
    let sr = f.fileFormat.sampleRate
    if abs(sr - targetSR) > 1 {
        let ratio = targetSR / sr, outLen = Int(Double(n) * ratio)
        var y = [Float](repeating: 0, count: outLen)
        for i in 0..<outLen { let p = Double(i) / ratio, i0 = Int(p), fr = Float(p - Double(i0)); y[i] = x[min(i0, n - 1)] * (1 - fr) + x[min(i0 + 1, n - 1)] * fr }
        x = y
    }
    return x
}

nonisolated func writeWav(_ path: String, _ x: [Float], sr: Double) throws {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let f = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: fmt.settings)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count))!
    buf.frameLength = AVAudioFrameCount(x.count)
    x.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
    try f.write(from: buf)
}

/// Windowed-RMS statistics: noise floor = 5th percentile window, signal = 95th percentile.
nonisolated func stats(_ x: [Float], sr: Double) -> (peak: Float, rms: Float, floor: Float, signal: Float, maxStep: Float, nan: Int) {
    let w = Int(sr * 0.1)
    var wins: [Float] = []
    var i = 0
    while i + w <= x.count { var s: Float = 0; for k in i..<(i + w) { s += x[k] * x[k] }; wins.append(sqrtf(s / Float(w))); i += w }
    wins.sort()
    var peak: Float = 0, sum: Float = 0, step: Float = 0, nan = 0
    for k in 0..<x.count {
        let v = x[k]
        if !v.isFinite { nan += 1; continue }
        peak = max(peak, abs(v)); sum += v * v
        if k > 0 { step = max(step, abs(v - x[k - 1])) }
    }
    let q: (Double) -> Float = { p in wins.isEmpty ? 0 : wins[min(wins.count - 1, Int(Double(wins.count - 1) * p))] }
    return (peak, sqrtf(sum / Float(max(1, x.count))), q(0.05), q(0.95), step, nan)
}

@main struct Main {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let noGate = args.contains("--no-gate"); args.removeAll { $0 == "--no-gate" }
        let legacy = args.contains("--legacy-level"); args.removeAll { $0 == "--legacy-level" }
        var driveDb: Float = 0, noiseDb: Float = -200, humDb: Float = -200
        if let i = args.firstIndex(of: "--drive"), i + 1 < args.count { driveDb = Float(args[i + 1]) ?? 0; args.removeSubrange(i...(i + 1)) }
        if let i = args.firstIndex(of: "--noise"), i + 1 < args.count { noiseDb = Float(args[i + 1]) ?? -200; args.removeSubrange(i...(i + 1)) }
        if let i = args.firstIndex(of: "--hum"), i + 1 < args.count { humDb = Float(args[i + 1]) ?? -200; args.removeSubrange(i...(i + 1)) }
        guard args.count >= 3 else { print("usage: render <model.nam> <in.wav> <out.wav> [--no-gate] [--legacy-level] [--drive dB]"); exit(2) }
        let sr = 48000.0, blk = 256

        let model = NAMModel()
        try model.loadModel(fromPath: args[0])
        model.prepare(withSampleRate: sr, maxBlockSize: 4096)

        // --- level match: mirrors AudioEngine.loadModel ---
        var probe = [Float](repeating: 0, count: 1024)
        for i in 0..<1024 { probe[i] = 0.1 * sinf(2 * .pi * 440 * Float(i) / Float(sr)) }
        var pOut = [Float](repeating: 0, count: 1024)
        probe.withUnsafeBufferPointer { ip in pOut.withUnsafeMutableBufferPointer { op in model.process(input: ip.baseAddress!, output: op.baseAddress!, frames: 1024) } }
        let probePeak = pOut.reduce(0) { max($0, abs($1)) }
        model.prepare(withSampleRate: sr, maxBlockSize: 4096)
        var makeupDb: Double
        let how: String
        if legacy {
            makeupDb = Double(db(min(64, max(0.05, 0.4 / max(probePeak, 1e-4))))); how = "LEGACY probe (uncapped to +36)"
        } else if model.loudness.isFinite {
            makeupDb = max(-24, min(12, -18 - model.loudness)); how = "loudness metadata \(String(format: "%.1f", model.loudness)) dB"
        } else {
            makeupDb = max(-24, min(12, Double(db(0.4 / max(probePeak, 1e-4))))); how = "probe (capped)"
        }
        print("model: \((args[0] as NSString).lastPathComponent)")
        print("  loudness meta: \(model.loudness.isFinite ? String(format: "%.1f dB", model.loudness) : "none") · probe peak \(String(format: "%.3f", probePeak)) · level via \(how) → trim \(String(format: "%+.1f", makeupDb)) dB")

        let gate = GateBlock(); gate.prepare(sampleRate: sr, maxBlock: blk); gate.reset()
        gate.thresholdDb = -34; gate.releaseMs = 80; gate.rangeDb = -80
        gate.bypass.store(noGate, ordering: .relaxed)
        let amp = AmpBlock(); amp.prepare(sampleRate: sr, maxBlock: blk); amp.reset()
        amp.setModel(model); amp.inputGain = powf(10, driveDb / 20); amp.makeupGain = powf(10, Float(makeupDb) / 20)
        // Let the smoothers settle to their targets before audio (the app does this via prepare/snap).
        amp.reset()

        var x = try readWav(args[1], targetSR: sr)
        if noiseDb > -150 || humDb > -150 {                       // simulate a single-coil DI: hiss + mains hum
            let na = powf(10, noiseDb / 20) * 1.73, ha = powf(10, humDb / 20) * 1.414
            var seed: UInt32 = 12345
            for i in 0..<x.count {
                seed = seed &* 1664525 &+ 1013904223
                x[i] += (Float(seed) / Float(UInt32.max) - 0.5) * 2 * na + ha * sinf(2 * .pi * 50 * Float(i) / Float(sr))
            }
        }
        let inS = stats(x, sr: sr)
        x.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count { let n = min(blk, p.count - i); gate.render(p.baseAddress! + i, n); amp.render(p.baseAddress! + i, n); i += n }
        }
        let outS = stats(x, sr: sr)
        try writeWav(args[2], x, sr: sr)

        func line(_ t: String, _ s: (peak: Float, rms: Float, floor: Float, signal: Float, maxStep: Float, nan: Int)) {
            print(String(format: "  %@  peak %6.1f dB · rms %6.1f dB · floor(5%%) %6.1f dB · signal(95%%) %6.1f dB · SNR %5.1f dB · maxstep %.2f · NaN %d",
                         t, db(s.peak), db(s.rms), db(s.floor), db(s.signal), db(s.signal) - db(s.floor), s.maxStep, s.nan))
        }
        print("input:  \((args[1] as NSString).lastPathComponent)  (\(x.count) samples @ 48k, gate \(noGate ? "OFF" : "ON"), drive \(driveDb) dB)")
        line("IN ", inS); line("OUT", outS)
        print("wrote \(args[2])")
    }
}
