//
//  AudioEngine.swift
//  NamRig — live guitar → drive → noise gate → NAM → DC-block → auto-level → output.
//

import AVFoundation
import Observation
import Synchronization

/// State the real-time render callbacks touch. NOT MainActor-isolated.
final class RenderContext: @unchecked Sendable {
    let ring = FloatRingBuffer(capacity: 16_384)
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let ampEnabled = Atomic<Bool>(true)
    var model: NAMModel?
    var inputGain: Float = 1
    var outputGain: Float = 1
    var makeupGain: Float = 1
    var inPeak: Float = 0
    var outPeak: Float = 0
    var dcX1: Float = 0
    var dcY1: Float = 0
    // Noise gate
    let gateEnabled = Atomic<Bool>(true)
    var gateThreshold: Float = 0.02   // linear (~ −34 dBFS)
    var gateEnv: Float = 0
    var gateGain: Float = 0
    deinit { scratch.deallocate() }
}

@MainActor
@Observable
final class AudioEngine {

    enum RunState: String { case stopped = "Stopped", running = "Running" }

    enum AmpModel: String, CaseIterable, Identifiable {
        case t3k = "T3K-sweep-v3-FX"
        case lstm = "lstm"
        case a1Standard = "wavenet_a1_standard"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .t3k: return "T3K A2"
            case .lstm: return "LSTM"
            case .a1Standard: return "A1 Std"
            }
        }
    }

    private(set) var state: RunState = .stopped
    private(set) var sampleRate: Double = 0
    private(set) var ioBufferMs: Double = 0
    private(set) var inputLatencyMs: Double = 0
    private(set) var outputLatencyMs: Double = 0
    private(set) var lastError: String?
    private(set) var modelStatus = "Loading amp…"

    var selectedModel: AmpModel = .t3k {
        didSet { if oldValue != selectedModel { loadModel() } }
    }
    var ampEnabled = true {
        didSet { context.ampEnabled.store(ampEnabled, ordering: .relaxed) }
    }
    var inputDriveDb: Double = 0 {
        didSet { context.inputGain = powf(10, Float(inputDriveDb) / 20) }
    }
    var outputLevelDb: Double = -6 {
        didSet { context.outputGain = powf(10, Float(outputLevelDb) / 20) }
    }
    var gateEnabled = true {
        didSet { context.gateEnabled.store(gateEnabled, ordering: .relaxed) }
    }
    var gateThresholdDb: Double = -34 {
        didSet { context.gateThreshold = powf(10, Float(gateThresholdDb) / 20) }
    }

    var modelLoaded: Bool { context.model != nil }
    var inPeakDb: Float { Self.toDb(context.inPeak) }
    var outPeakDb: Float { Self.toDb(context.outPeak) }

    var roundTripMs: Double {
        guard state == .running else { return 0 }
        return ioBufferMs * 2 + inputLatencyMs + outputLatencyMs
    }

    private let engine = AVAudioEngine()
    private let context = RenderContext()
    private var sinkNode: AVAudioSinkNode?
    private var sourceNode: AVAudioSourceNode?

    private let preferredSampleRate: Double = 48_000
    private let preferredBufferFrames: Double = 512

    init() {
        context.inputGain = powf(10, Float(inputDriveDb) / 20)
        context.outputGain = powf(10, Float(outputLevelDb) / 20)
        context.gateThreshold = powf(10, Float(gateThresholdDb) / 20)
    }

    static func toDb(_ x: Float) -> Float { x > 1e-6 ? 20 * log10(x) : -120 }

    // MARK: - Model

    func loadModel() {
        let name = selectedModel.rawValue
        guard let path = Bundle.main.path(forResource: name, ofType: "nam") else {
            modelStatus = "❌ \(name).nam not in bundle"; context.model = nil; return
        }
        let model = NAMModel()
        do {
            try model.loadModel(fromPath: path)
            model.prepare(withSampleRate: preferredSampleRate, maxBlockSize: 4096)
            let probe = selfTest(model)
            model.prepare(withSampleRate: preferredSampleRate, maxBlockSize: 4096)
            context.model = model
            let makeup: Float = probe.nan ? 1 : max(0.05, min(64, 0.4 / max(probe.peak, 1e-4)))
            context.makeupGain = makeup
            modelStatus = "\(selectedModel.label) · raw \(String(format: "%.3f", probe.peak)) · auto \(String(format: "%+.0f", 20 * log10(makeup))) dB"
        } catch {
            context.model = nil
            modelStatus = "❌ Load failed: \(error.localizedDescription)"
        }
    }

    private func selfTest(_ model: NAMModel) -> (peak: Float, dc: Float, nan: Bool) {
        let count = 1024
        var input = [Float](repeating: 0, count: count)
        for i in 0..<count { input[i] = 0.1 * sinf(2 * .pi * 440 * Float(i) / Float(preferredSampleRate)) }
        var output = [Float](repeating: 0, count: count)
        input.withUnsafeBufferPointer { ip in
            output.withUnsafeMutableBufferPointer { op in
                model.process(input: ip.baseAddress!, output: op.baseAddress!, frames: Int32(count))
            }
        }
        var peak: Float = 0, sum: Float = 0, nan = false
        for v in output {
            if !v.isFinite { nan = true; continue }
            let a = abs(v); if a > peak { peak = a }
            sum += v
        }
        return (peak, sum / Float(count), nan)
    }

    // MARK: - Audio

    func toggle() { state == .running ? stop() : start() }

    func start() {
        guard state == .stopped else { return }
        lastError = nil
        Task { await requestMicThenStart() }
    }

    private func requestMicThenStart() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { lastError = "Microphone access denied. Enable it in Settings → NamRig."; return }
        do {
            try configureSession()
            try startEngine()
            refreshMetrics()
            state = .running
        } catch {
            lastError = error.localizedDescription
            try? AVAudioSession.sharedInstance().setActive(false)
            state = .stopped
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(preferredSampleRate)
        try session.setPreferredIOBufferDuration(preferredBufferFrames / preferredSampleRate)
        try session.setActive(true)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No audio input detected — plug in your iRig + guitar and try again."])
        }
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1) else {
            throw NSError(domain: "AudioEngine", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create the processing format."])
        }

        context.ring.reset()
        context.dcX1 = 0; context.dcY1 = 0
        context.gateEnv = 0; context.gateGain = 0
        let context = self.context  // capture the RT box (Sendable), never `self`

        let sink = AVAudioSinkNode { _, frameCount, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(.init(mutating: ablPtr))
            guard let first = abl.first, let data = first.mData else { return noErr }
            context.ring.write(data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            return noErr
        }

        let source = AVAudioSourceNode(format: monoFormat) { isSilence, _, frameCount, ablPtr in
            let n = Int(frameCount)
            if n > 4096 || !context.ring.read(into: context.scratch, count: n) {
                isSilence.pointee = true
                return noErr
            }
            let s = context.scratch

            // Drive + input level.
            let ig = context.inputGain
            var inP: Float = 0
            for i in 0..<n { let v = s[i] * ig; s[i] = v; let a = abs(v); if a > inP { inP = a } }
            context.inPeak = inP

            // Noise gate (pre-amp): cut the input below threshold so the amp can't amplify hiss.
            if context.gateEnabled.load(ordering: .relaxed) {
                let thr = context.gateThreshold
                var env = context.gateEnv
                var gg = context.gateGain
                for i in 0..<n {
                    let a = abs(s[i])
                    env = a > env ? a : env * 0.9995              // peak envelope follower
                    let target: Float = env > thr ? 1 : 0
                    gg += (target - gg) * (target > gg ? 0.02 : 0.0006)  // fast open, slow close
                    s[i] *= gg
                }
                context.gateEnv = env
                context.gateGain = gg
            }

            // The amp.
            if context.ampEnabled.load(ordering: .relaxed), let model = context.model {
                model.process(input: s, output: s, frames: Int32(n))
            }

            // DC blocker.
            var x1 = context.dcX1, y1 = context.dcY1
            for i in 0..<n {
                let x = s[i].isFinite ? s[i] : 0
                let y = x - x1 + 0.9975 * y1
                x1 = x; y1 = y
                s[i] = y
            }
            context.dcX1 = x1; context.dcY1 = y1

            var outP: Float = 0
            for i in 0..<n { let a = abs(s[i]); if a.isFinite && a > outP { outP = a } }
            context.outPeak = outP

            // Auto-level × user output + safety clamp.
            let og = context.outputGain * context.makeupGain
            for i in 0..<n {
                var v = s[i] * og
                if !v.isFinite { v = 0 } else if v > 1 { v = 1 } else if v < -1 { v = -1 }
                s[i] = v
            }

            let out = UnsafeMutableAudioBufferListPointer(ablPtr)
            for buffer in out {
                guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                memcpy(dst, s, n * MemoryLayout<Float>.size)
            }
            return noErr
        }

        engine.attach(sink)
        engine.attach(source)
        engine.connect(input, to: sink, format: inputFormat)
        engine.connect(source, to: engine.mainMixerNode, format: monoFormat)
        sinkNode = sink
        sourceNode = source

        engine.prepare()
        try engine.start()
    }

    private func refreshMetrics() {
        let session = AVAudioSession.sharedInstance()
        sampleRate = session.sampleRate
        ioBufferMs = session.ioBufferDuration * 1000
        inputLatencyMs = session.inputLatency * 1000
        outputLatencyMs = session.outputLatency * 1000
    }

    func stop() {
        guard state == .running else { return }
        engine.stop()
        if let sinkNode { engine.detach(sinkNode) }
        if let sourceNode { engine.detach(sourceNode) }
        sinkNode = nil
        sourceNode = nil
        context.inPeak = 0
        context.outPeak = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        state = .stopped
    }
}
