//
//  AudioEngine.swift
//  NamRig — live guitar → block chain → output.
//
//  Render: input → [SignalChain: Gate → Amp → …future fx] → output gain + clamp.
//

import AVFoundation
import Observation
import Synchronization

/// State the real-time render callbacks touch. NOT MainActor-isolated.
final class RenderContext: @unchecked Sendable {
    let ring = FloatRingBuffer(capacity: 16_384)
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let chain = SignalChain()
    var outputGain: Float = 1
    var inPeak: Float = 0
    var outPeak: Float = 0
    var sr: Double = 48000
    var cpuLoad: Float = 0   // DSP time / buffer time (smoothed)
    let analysis = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4096)  // dry-input ring for the tuner
    var analysisW = 0
    init() { analysis.initialize(repeating: 0) }
    deinit { scratch.deallocate(); analysis.deallocate() }
}

@MainActor
@Observable
final class AudioEngine {

    enum RunState: String { case stopped = "Stopped", running = "Running" }

    struct ToneModel: Identifiable, Equatable {
        let id: String      // bundled resource name, or imported/downloaded filename
        let name: String
        let path: String
        let bundled: Bool
        var artworkPath: String? = nil   // local sidecar cover image, if any
        var gear: String? = nil          // TONE3000 gear type (amp / amp-cab / pedal / …)
        var isAmp: Bool { gear?.lowercased().contains("amp") ?? false }
    }

    private(set) var models: [ToneModel] = []
    var selectedModelName: String { models.first { $0.id == selectedModelID }?.name ?? "—" }
    var selectedArtworkPath: String? { models.first { $0.id == selectedModelID }?.artworkPath }
    var selectedPedalArtworkPath: String? { models.first { $0.id == selectedPedalModelID }?.artworkPath }
    // Amp slot shows amps / amp+cabs (+ untagged imports); pedal slot shows pedals (+ untagged imports).
    var ampModels: [ToneModel]   { models.filter { let g = $0.gear?.lowercased(); return g == nil || g!.contains("amp") } }
    var pedalModels: [ToneModel] { models.filter { let g = $0.gear?.lowercased(); return g == nil || g!.contains("pedal") } }

    var modelsDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    var irsDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("IRs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func refreshModels() {
        var list: [ToneModel] = []
        for (res, name) in [("T3K-sweep-v3-FX", "T3K A2")] {
            if let p = Bundle.main.path(forResource: res, ofType: "nam") {
                list.append(ToneModel(id: res, name: name, path: p, bundled: true, gear: "amp"))
            }
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension.lowercased() == "nam" {
                let base = f.deletingPathExtension().lastPathComponent
                let art = modelsDir.appendingPathComponent(base + ".jpg").path
                let gearFile = modelsDir.appendingPathComponent(base + ".gear").path
                let gear = (try? String(contentsOfFile: gearFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                list.append(ToneModel(id: f.lastPathComponent, name: base, path: f.path, bundled: false,
                                      artworkPath: FileManager.default.fileExists(atPath: art) ? art : nil, gear: gear))
            }
        }
        models = list
    }

    /// Copy an external .nam (from Files / a download) into the local library and select it.
    /// If `artworkURL` is given (e.g. a TONE3000 cover), fetch it into a sidecar next to the model.
    func importModel(from url: URL, artworkURL: String? = nil, gear: String? = nil, asPedal: Bool = false) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dest = modelsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest) }
        catch { modelStatus = "❌ Import failed: \(error.localizedDescription)"; return }
        let base = dest.deletingPathExtension().lastPathComponent
        if let gear { try? gear.write(to: modelsDir.appendingPathComponent(base + ".gear"), atomically: true, encoding: .utf8) }
        refreshModels()
        if asPedal { selectedPedalModelID = dest.lastPathComponent } else { selectedModelID = dest.lastPathComponent }
        if let artworkURL, let aurl = URL(string: artworkURL) {
            let imgDest = modelsDir.appendingPathComponent(base + ".jpg")
            Task { @MainActor in
                if let (data, _) = try? await URLSession.shared.data(from: aurl) {
                    try? data.write(to: imgDest)
                    refreshModels()
                }
            }
        }
    }

    func deleteModel(id: String) {
        guard let m = models.first(where: { $0.id == id }), !m.bundled else { return }
        try? FileManager.default.removeItem(atPath: m.path)
        if let art = m.artworkPath { try? FileManager.default.removeItem(atPath: art) }
        try? FileManager.default.removeItem(atPath: modelsDir.appendingPathComponent(m.name + ".gear").path)
        if selectedPedalModelID == id { selectedPedalModelID = nil }
        let wasSelected = selectedModelID == id
        refreshModels()
        if wasSelected { selectedModelID = models.first?.id ?? selectedModelID }
    }

    private(set) var state: RunState = .stopped
    private(set) var sampleRate: Double = 0
    private(set) var ioBufferMs: Double = 0
    private(set) var inputLatencyMs: Double = 0
    private(set) var outputLatencyMs: Double = 0
    private(set) var inputSampleRate: Double = 0
    private(set) var outputSampleRate: Double = 0
    private(set) var lastError: String?
    private(set) var modelStatus = "Loading amp…"
    private(set) var pedalStatus = "— empty —"
    private(set) var cabIRName = "None"
    private var cabIRFile = ""
    private(set) var irReverbName = "None"
    private var irReverbFile = ""
    private(set) var tunerNote = "—"
    private(set) var tunerCents = 0
    private(set) var tunerActive = false
    private(set) var presets: [Preset] = PresetStore.load()
    private(set) var currentPresetIndex = 0
    var currentPresetName: String { presets.indices.contains(currentPresetIndex) ? presets[currentPresetIndex].name : "Init" }

    // UI parameters → blocks / engine.
    var selectedModelID: String = "T3K-sweep-v3-FX" {
        didSet { if oldValue != selectedModelID { loadModel() } }
    }
    var ampEnabled = true {
        didSet { amp.bypass.store(!ampEnabled, ordering: .relaxed) }
    }
    var inputDriveDb: Double = 0 {
        didSet { amp.inputGain = powf(10, Float(inputDriveDb) / 20) }
    }
    var pedalEnabled = false { didSet { pedal.bypass.store(!pedalEnabled, ordering: .relaxed) } }
    var selectedPedalModelID: String? = nil { didSet { if oldValue != selectedPedalModelID { loadPedalModel() } } }
    var pedalDriveDb: Double = 0 { didSet { pedal.inputGain = powf(10, Float(pedalDriveDb) / 20) } }
    var pedalLevelDb: Double = 0 { didSet { pedal.makeupGain = powf(10, Float(pedalLevelDb) / 20) } }
    var selectedPedalName: String { selectedPedalModelID.flatMap { id in models.first { $0.id == id }?.name } ?? "None" }
    var gateEnabled = true {
        didSet { gate.bypass.store(!gateEnabled, ordering: .relaxed) }
    }
    var gateThresholdDb: Double = -34 {
        didSet { gate.threshold = powf(10, Float(gateThresholdDb) / 20) }
    }
    var outputLevelDb: Double = -6 {
        didSet { context.outputGain = powf(10, Float(outputLevelDb) / 20) }
    }
    var eqEnabled = true {
        didSet { eq.bypass.store(!eqEnabled, ordering: .relaxed) }
    }
    var bassDb: Double = 0 { didSet { updateEQ() } }
    var midDb: Double = 0 { didSet { updateEQ() } }
    var trebleDb: Double = 0 { didSet { updateEQ() } }

    var delayEnabled = false { didSet { delay.bypass.store(!delayEnabled, ordering: .relaxed) } }
    var delayTimeMs: Double = 350 { didSet { delay.delaySamples = Int(delayTimeMs / 1000 * preferredSampleRate) } }
    var delayFeedbackPct: Double = 35 { didSet { delay.feedback = Float(delayFeedbackPct / 100) } }
    var delayMixPct: Double = 30 { didSet { delay.mix = Float(delayMixPct / 100) } }

    var reverbEnabled = false { didSet { reverb.bypass.store(!reverbEnabled, ordering: .relaxed) } }
    var reverbDecayPct: Double = 70 { didSet { reverb.feedback = 0.7 + Float(reverbDecayPct / 100) * 0.28 } }
    var reverbDampPct: Double = 30 { didSet { reverb.damp1 = Float(reverbDampPct / 100) * 0.4 } }
    var reverbMixPct: Double = 25 { didSet { reverb.mix = Float(reverbMixPct / 100) } }

    var irReverbEnabled = false { didSet { irReverb.bypass.store(!irReverbEnabled, ordering: .relaxed) } }
    var irReverbMixPct: Double = 35 { didSet { irReverb.mix = Float(irReverbMixPct / 100) } }
    var irReverbPredelayMs: Double = 0 { didSet { irReverb.setPredelay(ms: Float(irReverbPredelayMs)) } }

    var compEnabled = false { didSet { comp.bypass.store(!compEnabled, ordering: .relaxed) } }
    var compThresholdDb: Double = -18 { didSet { comp.thresholdDb = Float(compThresholdDb) } }
    var compRatio: Double = 4 { didSet { comp.ratio = Float(compRatio) } }
    var compAttackMs: Double = 10 { didSet { comp.setTimes(attackMs: Float(compAttackMs), releaseMs: Float(compReleaseMs)) } }
    var compReleaseMs: Double = 120 { didSet { comp.setTimes(attackMs: Float(compAttackMs), releaseMs: Float(compReleaseMs)) } }
    var compMakeupDb: Double = 0 { didSet { comp.makeup = powf(10, Float(compMakeupDb) / 20) } }

    var driveEnabled = false { didSet { drive.bypass.store(!driveEnabled, ordering: .relaxed) } }
    var driveAmount: Double = 4 { didSet { drive.drive = Float(driveAmount) } }
    var driveToneHz: Double = 4000 { didSet { drive.setTone(hz: Float(driveToneHz)) } }
    var driveLevelDb: Double = 0 { didSet { drive.level = powf(10, Float(driveLevelDb) / 20) } }

    var driveMode: Int = 0 { didSet { drive.mode = driveMode } }

    var boostEnabled = false { didSet { boost.bypass.store(!boostEnabled, ordering: .relaxed) } }
    var boostDb: Double = 6 { didSet { boost.gain = powf(10, Float(boostDb) / 20) } }

    var chorusEnabled = false { didSet { chorus.bypass.store(!chorusEnabled, ordering: .relaxed) } }
    var chorusRateHz: Double = 0.8 { didSet { chorus.rateHz = Float(chorusRateHz) } }
    var chorusDepthMs: Double = 6 { didSet { chorus.depthMs = Float(chorusDepthMs) } }
    var chorusMixPct: Double = 40 { didSet { chorus.mix = Float(chorusMixPct / 100) } }

    var flangerEnabled = false { didSet { flanger.bypass.store(!flangerEnabled, ordering: .relaxed) } }
    var flangerRateHz: Double = 0.4 { didSet { flanger.rateHz = Float(flangerRateHz) } }
    var flangerDepthMs: Double = 2 { didSet { flanger.depthMs = Float(flangerDepthMs) } }
    var flangerFeedbackPct: Double = 50 { didSet { flanger.feedback = Float(flangerFeedbackPct / 100) } }
    var flangerMixPct: Double = 50 { didSet { flanger.mix = Float(flangerMixPct / 100) } }

    var tremoloEnabled = false { didSet { tremolo.bypass.store(!tremoloEnabled, ordering: .relaxed) } }
    var tremoloRateHz: Double = 5 { didSet { tremolo.rateHz = Float(tremoloRateHz) } }
    var tremoloDepthPct: Double = 50 { didSet { tremolo.depth = Float(tremoloDepthPct / 100) } }

    var reverbType: Int = 3   // 0 room · 1 plate · 2 spring · 3 hall (voicing label)
    func selectReverbType(_ t: Int) {
        reverbType = t
        switch t {
        case 0: reverbDecayPct = 35; reverbDampPct = 60    // room
        case 1: reverbDecayPct = 88; reverbDampPct = 12    // plate
        case 2: reverbDecayPct = 55; reverbDampPct = 35    // spring
        default: reverbDecayPct = 80; reverbDampPct = 18   // hall
        }
    }

    // Free-order chain — `blockOrder` is a permutation of all block kinds.
    static let defaultOrder: [BlockKind] = [.gate, .comp, .boost, .drive, .pedal, .amp, .eq, .chorus, .flanger, .tremolo, .delay, .reverb, .irReverb]
    private var indexByKind: [BlockKind: Int] = [:]
    var blockOrder: [BlockKind] = [.gate, .comp, .boost, .drive, .pedal, .amp, .eq, .chorus, .flanger, .tremolo, .delay, .reverb, .irReverb]
    func applyOrder() { context.chain.reorder(blockOrder.compactMap { indexByKind[$0] }) }
    func setOrder(_ newOrder: [BlockKind]) { blockOrder = newOrder; applyOrder() }
    var availableToAdd: [BlockKind] { BlockKind.allCases.filter { !blockOrder.contains($0) } }
    func addBlock(_ kind: BlockKind) {
        guard !blockOrder.contains(kind) else { return }
        blockOrder.append(kind); setBlockEnabled(kind, true); applyOrder()
    }
    func removeBlock(_ kind: BlockKind) { blockOrder.removeAll { $0 == kind }; applyOrder() }
    func setBlockEnabled(_ kind: BlockKind, _ on: Bool) {
        switch kind {
        case .gate: gateEnabled = on; case .comp: compEnabled = on; case .boost: boostEnabled = on
        case .drive: driveEnabled = on; case .pedal: pedalEnabled = on; case .amp: ampEnabled = on
        case .eq: eqEnabled = on; case .chorus: chorusEnabled = on; case .flanger: flangerEnabled = on
        case .tremolo: tremoloEnabled = on; case .delay: delayEnabled = on; case .reverb: reverbEnabled = on
        case .irReverb: irReverbEnabled = on
        }
    }
    func isBlockEnabled(_ kind: BlockKind) -> Bool {
        switch kind {
        case .gate: return gateEnabled; case .comp: return compEnabled; case .boost: return boostEnabled
        case .drive: return driveEnabled; case .pedal: return pedalEnabled; case .amp: return ampEnabled
        case .eq: return eqEnabled; case .chorus: return chorusEnabled; case .flanger: return flangerEnabled
        case .tremolo: return tremoloEnabled; case .delay: return delayEnabled; case .reverb: return reverbEnabled
        case .irReverb: return irReverbEnabled
        }
    }

    var modelLoaded: Bool { amp.hasModel }
    var inPeakDb: Float { Self.toDb(context.inPeak) }
    var outPeakDb: Float { Self.toDb(context.outPeak) }
    var cpuPercent: Int { max(0, min(999, Int((context.cpuLoad * 100).rounded()))) }

    /// Buffer round-trip — the part we control, and what you actually feel.
    var roundTripMs: Double { state == .running ? ioBufferMs * 2 : 0 }
    /// AVAudioSession's reported hardware I/O latency (often inflated / route-dependent — reference only).
    var reportedLatencyMs: Double { state == .running ? inputLatencyMs + outputLatencyMs : 0 }

    private let engine = AVAudioEngine()
    private let context = RenderContext()
    private let gate = GateBlock()
    private let comp = CompressorBlock()
    private let drive = DriveBlock()
    private let amp = AmpBlock()
    private let eq = EQBlock()
    private let delay = DelayBlock()
    private let reverb = ReverbBlock()
    private let boost = BoostBlock()
    private let chorus = ChorusBlock()
    private let flanger = FlangerBlock()
    private let tremolo = TremoloBlock()
    private let pedal = AmpBlock(kind: .pedal)
    private let irReverb = ReverbIRBlock()
    private var sinkNode: AVAudioSinkNode?
    private var sourceNode: AVAudioSourceNode?
    private var tunerTimer: Timer?

    private let preferredSampleRate: Double = 48_000
    var preferredBufferFrames: Double = 128 {   // user-tunable in Settings (Low / Balanced / Safe)
        didSet { if preferredBufferFrames != oldValue, state == .running { stop(); start() } }
    }

    init() {
        refreshModels()
        if !models.contains(where: { $0.id == selectedModelID }) { selectedModelID = models.first?.id ?? selectedModelID }
        let chainBlocks: [AudioBlock] = [gate, comp, boost, drive, pedal, amp, eq, chorus, flanger, tremolo, delay, reverb, irReverb]
        context.chain.install(chainBlocks)
        for (i, b) in chainBlocks.enumerated() { indexByKind[b.kind] = i }
        applyOrder()
        context.outputGain = powf(10, Float(outputLevelDb) / 20)
        amp.inputGain = powf(10, Float(inputDriveDb) / 20)
        gate.threshold = powf(10, Float(gateThresholdDb) / 20)
        updateEQ()
        delay.bypass.store(!delayEnabled, ordering: .relaxed)
        delay.delaySamples = Int(delayTimeMs / 1000 * preferredSampleRate)
        delay.feedback = Float(delayFeedbackPct / 100)
        delay.mix = Float(delayMixPct / 100)
        reverb.bypass.store(!reverbEnabled, ordering: .relaxed)
        reverb.feedback = 0.7 + Float(reverbDecayPct / 100) * 0.28
        reverb.damp1 = Float(reverbDampPct / 100) * 0.4
        reverb.mix = Float(reverbMixPct / 100)
        comp.bypass.store(!compEnabled, ordering: .relaxed)
        comp.thresholdDb = Float(compThresholdDb)
        comp.ratio = Float(compRatio)
        comp.setTimes(attackMs: Float(compAttackMs), releaseMs: Float(compReleaseMs))
        comp.makeup = powf(10, Float(compMakeupDb) / 20)
        drive.bypass.store(!driveEnabled, ordering: .relaxed)
        drive.drive = Float(driveAmount)
        drive.setTone(hz: Float(driveToneHz))
        drive.level = powf(10, Float(driveLevelDb) / 20)
        drive.mode = driveMode
        boost.bypass.store(!boostEnabled, ordering: .relaxed); boost.gain = powf(10, Float(boostDb) / 20)
        chorus.bypass.store(!chorusEnabled, ordering: .relaxed); chorus.rateHz = Float(chorusRateHz); chorus.depthMs = Float(chorusDepthMs); chorus.mix = Float(chorusMixPct / 100)
        flanger.bypass.store(!flangerEnabled, ordering: .relaxed); flanger.rateHz = Float(flangerRateHz); flanger.depthMs = Float(flangerDepthMs); flanger.feedback = Float(flangerFeedbackPct / 100); flanger.mix = Float(flangerMixPct / 100)
        tremolo.bypass.store(!tremoloEnabled, ordering: .relaxed); tremolo.rateHz = Float(tremoloRateHz); tremolo.depth = Float(tremoloDepthPct / 100)
        pedal.bypass.store(!pedalEnabled, ordering: .relaxed); pedal.inputGain = powf(10, Float(pedalDriveDb) / 20); pedal.makeupGain = powf(10, Float(pedalLevelDb) / 20)
        irReverb.bypass.store(!irReverbEnabled, ordering: .relaxed); irReverb.mix = Float(irReverbMixPct / 100)
        loadPedalModel()
    }

    private func updateEQ() { eq.setBands(bass: Float(bassDb), mid: Float(midDb), treble: Float(trebleDb)) }

    static func toDb(_ x: Float) -> Float { x > 1e-6 ? 20 * log10(x) : -120 }

    // MARK: - Model

    func loadModel() {
        guard let tm = models.first(where: { $0.id == selectedModelID }) ?? models.first else {
            modelStatus = "❌ no models found"; amp.setModel(nil); return
        }
        let model = NAMModel()
        do {
            try model.loadModel(fromPath: tm.path)
            model.prepare(withSampleRate: preferredSampleRate, maxBlockSize: 4096)
            let probe = selfTest(model)
            model.prepare(withSampleRate: preferredSampleRate, maxBlockSize: 4096)
            amp.setModel(model)
            amp.makeupGain = probe.nan ? 1 : max(0.05, min(64, 0.4 / max(probe.peak, 1e-4)))
            modelStatus = "\(tm.name) · raw \(String(format: "%.3f", probe.peak)) · auto \(String(format: "%+.0f", 20 * log10(amp.makeupGain))) dB"
        } catch {
            amp.setModel(nil)
            modelStatus = "❌ Load failed: \(error.localizedDescription)"
        }
    }

    /// Load the pedal-slot capture (a 2nd neural model in front of the amp). No auto-level — the
    /// user sets Drive/Level so the pedal hits the amp the way they want.
    func loadPedalModel() {
        guard let id = selectedPedalModelID, !id.isEmpty,
              let tm = models.first(where: { $0.id == id }) else {
            pedal.setModel(nil); pedalStatus = "— empty —"; return
        }
        let model = NAMModel()
        do {
            try model.loadModel(fromPath: tm.path)
            model.prepare(withSampleRate: preferredSampleRate, maxBlockSize: 4096)
            pedal.setModel(model)
            pedal.makeupGain = powf(10, Float(pedalLevelDb) / 20)
            pedalStatus = tm.name
        } catch {
            pedal.setModel(nil)
            pedalStatus = "❌ Load failed"
        }
    }

    // MARK: - Cab IR

    func loadCabIR(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let taps = Self.loadIRSamples(url, targetSR: preferredSampleRate), !taps.isEmpty else {
            modelStatus = "❌ Cab IR load failed"; return
        }
        let dest = irsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        cabIRFile = url.lastPathComponent
        cabIRName = url.deletingPathExtension().lastPathComponent
        amp.setIR(taps)
    }
    func clearCabIR() { cabIRFile = ""; cabIRName = "None"; amp.clearIR() }
    private func applyCabIR(_ file: String) {
        guard !file.isEmpty else { clearCabIR(); return }
        let url = irsDir.appendingPathComponent(file)
        if let taps = Self.loadIRSamples(url, targetSR: preferredSampleRate), !taps.isEmpty {
            cabIRFile = file; cabIRName = url.deletingPathExtension().lastPathComponent; amp.setIR(taps)
        } else { clearCabIR() }
    }
    func loadReverbIR(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let taps = Self.loadReverbIRSamples(url, targetSR: preferredSampleRate), !taps.isEmpty else {
            modelStatus = "❌ Reverb IR load failed"; return
        }
        let dest = irsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        irReverbFile = url.lastPathComponent
        irReverbName = url.deletingPathExtension().lastPathComponent
        irReverb.setIR(taps)
    }
    func clearReverbIR() { irReverbFile = ""; irReverbName = "None"; irReverb.clearIR() }
    private func applyReverbIR(_ file: String) {
        guard !file.isEmpty else { clearReverbIR(); return }
        let url = irsDir.appendingPathComponent(file)
        if let taps = Self.loadReverbIRSamples(url, targetSR: preferredSampleRate), !taps.isEmpty {
            irReverbFile = file; irReverbName = url.deletingPathExtension().lastPathComponent; irReverb.setIR(taps)
        } else { clearReverbIR() }
    }
    /// Reverb IR loader — long (≤64000 taps ≈ 1.3 s) and L2/energy-normalized (consistent loudness vs length).
    static func loadReverbIRSamples(_ url: URL, targetSR: Double) -> [Float]? {
        guard var x = loadIRSamples(url, targetSR: targetSR, cap: 64000, normalizeL1: false), !x.isEmpty else { return nil }
        let e = sqrtf(x.reduce(Float(0)) { $0 + $1 * $1 })
        if e > 1e-9 { for i in x.indices { x[i] *= 1 / e } }
        return x
    }

    /// Load a (cab) IR .wav → mono, resampled to the engine rate, ≤`cap` taps, L1-normalized if requested.
    static func loadIRSamples(_ url: URL, targetSR: Double, cap: Int = 2048, normalizeL1: Bool = true) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData, buf.frameLength > 0 else { return nil }
        let n = Int(buf.frameLength)
        var x = (0..<n).map { ch[0][$0] }
        let srcSR = f.fileFormat.sampleRate
        if abs(srcSR - targetSR) > 1 {
            let src = x, ratio = targetSR / srcSR, outLen = max(1, Int(Double(n) * ratio))
            var y = [Float](repeating: 0, count: outLen)
            for i in 0..<outLen {
                let pos = Double(i) / ratio, i0 = Int(pos), fr = Float(pos - Double(i0))
                let a = src[min(i0, n - 1)], b = src[min(i0 + 1, n - 1)]
                y[i] = a + (b - a) * fr
            }
            x = y
        }
        if x.count > cap { x = Array(x[0..<cap]) }
        if normalizeL1 {
            let l1 = x.reduce(Float(0)) { $0 + abs($1) }
            if l1 > 1e-6 { for i in x.indices { x[i] *= 1 / l1 } }
        }
        return x
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

    // MARK: - Presets

    func applyCurrentPreset() { if presets.indices.contains(currentPresetIndex) { apply(presets[currentPresetIndex]) } }

    func loadPreset(at i: Int) {
        guard presets.indices.contains(i) else { return }
        currentPresetIndex = i
        apply(presets[i])
    }
    func nextPreset() { guard !presets.isEmpty else { return }; loadPreset(at: (currentPresetIndex + 1) % presets.count) }
    func prevPreset() { guard !presets.isEmpty else { return }; loadPreset(at: (currentPresetIndex - 1 + presets.count) % presets.count) }

    // MARK: - Live mode + MIDI hooks

    static let liveBankSize = 4
    var bankIndex: Int { presets.isEmpty ? 0 : currentPresetIndex / Self.liveBankSize }
    var sceneInBank: Int { currentPresetIndex % Self.liveBankSize }
    func handleProgramChange(_ pc: Int) { loadPreset(at: pc) }   // loadPreset already range-guards

    /// MIDI CC → engine param (0…1 normalized into the param's range). Reuses the existing didSet→block path.
    func setParam(_ p: MIDIParam, normalized: Double) {
        let r = p.range
        let v = r.lowerBound + (r.upperBound - r.lowerBound) * max(0, min(1, normalized))
        switch p {
        case .ampDrive: inputDriveDb = v;   case .output: outputLevelDb = v;   case .gateThr: gateThresholdDb = v
        case .bass: bassDb = v;             case .mid: midDb = v;              case .treble: trebleDb = v
        case .driveAmt: driveAmount = v;    case .driveLevel: driveLevelDb = v
        case .delayMix: delayMixPct = v;    case .delayFb: delayFeedbackPct = v
        case .reverbMix: reverbMixPct = v;  case .reverbDecay: reverbDecayPct = v
        case .compMakeup: compMakeupDb = v; case .boostDb: boostDb = v
        case .pedalDrive: pedalDriveDb = v; case .pedalLevel: pedalLevelDb = v
        case .chorusMix: chorusMixPct = v;  case .flangerMix: flangerMixPct = v; case .tremoloDepth: tremoloDepthPct = v
        }
    }

    func saveCurrent(as name: String) {
        let p = capture(name: name.isEmpty ? "Preset \(presets.count + 1)" : name)
        presets.append(p); currentPresetIndex = presets.count - 1; PresetStore.save(presets)
    }
    func overwriteCurrent() {
        guard presets.indices.contains(currentPresetIndex) else { return }
        var p = capture(name: presets[currentPresetIndex].name); p.id = presets[currentPresetIndex].id
        presets[currentPresetIndex] = p; PresetStore.save(presets)
    }

    private func capture(name: String) -> Preset {
        Preset(name: name, model: selectedModelID,
               ampOn: ampEnabled, ampDrive: inputDriveDb,
               gateOn: gateEnabled, gateThr: gateThresholdDb,
               compOn: compEnabled, compThr: compThresholdDb, compRatio: compRatio, compAtk: compAttackMs, compRel: compReleaseMs, compMakeup: compMakeupDb,
               driveOn: driveEnabled, driveAmt: driveAmount, driveTone: driveToneHz, driveLevel: driveLevelDb,
               eqOn: eqEnabled, bass: bassDb, mid: midDb, treble: trebleDb,
               delayOn: delayEnabled, delayTime: delayTimeMs, delayFb: delayFeedbackPct, delayMix: delayMixPct,
               reverbOn: reverbEnabled, reverbDecay: reverbDecayPct, reverbDamp: reverbDampPct, reverbMix: reverbMixPct,
               output: outputLevelDb,
               boostOn: boostEnabled, boostDb: boostDb,
               driveMode: driveMode,
               chorusOn: chorusEnabled, chorusRate: chorusRateHz, chorusDepth: chorusDepthMs, chorusMix: chorusMixPct,
               flangerOn: flangerEnabled, flangerRate: flangerRateHz, flangerDepth: flangerDepthMs, flangerFb: flangerFeedbackPct, flangerMix: flangerMixPct,
               tremoloOn: tremoloEnabled, tremoloRate: tremoloRateHz, tremoloDepth: tremoloDepthPct,
               reverbType: reverbType,
               order: blockOrder.map { $0.rawValue },
               pedalOn: pedalEnabled, pedalModel: selectedPedalModelID ?? "", pedalDrive: pedalDriveDb, pedalLevel: pedalLevelDb,
               cabIR: cabIRFile,
               irReverbOn: irReverbEnabled, irReverbMix: irReverbMixPct, irReverbPredelay: irReverbPredelayMs, irReverbIR: irReverbFile)
    }
    private func apply(_ p: Preset) {
        let changed = p.model != selectedModelID
        selectedModelID = p.model
        if !changed { loadModel() }   // same model → didSet didn't reload; force it
        ampEnabled = p.ampOn; inputDriveDb = p.ampDrive
        gateEnabled = p.gateOn; gateThresholdDb = p.gateThr
        compEnabled = p.compOn; compThresholdDb = p.compThr; compRatio = p.compRatio; compAttackMs = p.compAtk; compReleaseMs = p.compRel; compMakeupDb = p.compMakeup
        driveEnabled = p.driveOn; driveAmount = p.driveAmt; driveToneHz = p.driveTone; driveLevelDb = p.driveLevel
        eqEnabled = p.eqOn; bassDb = p.bass; midDb = p.mid; trebleDb = p.treble
        delayEnabled = p.delayOn; delayTimeMs = p.delayTime; delayFeedbackPct = p.delayFb; delayMixPct = p.delayMix
        reverbEnabled = p.reverbOn; reverbDecayPct = p.reverbDecay; reverbDampPct = p.reverbDamp; reverbMixPct = p.reverbMix
        outputLevelDb = p.output
        boostEnabled = p.boostOn; boostDb = p.boostDb
        driveMode = p.driveMode
        chorusEnabled = p.chorusOn; chorusRateHz = p.chorusRate; chorusDepthMs = p.chorusDepth; chorusMixPct = p.chorusMix
        flangerEnabled = p.flangerOn; flangerRateHz = p.flangerRate; flangerDepthMs = p.flangerDepth; flangerFeedbackPct = p.flangerFb; flangerMixPct = p.flangerMix
        tremoloEnabled = p.tremoloOn; tremoloRateHz = p.tremoloRate; tremoloDepthPct = p.tremoloDepth
        reverbType = p.reverbType
        let ord = p.order.compactMap { BlockKind(rawValue: $0) }   // a preset's chain may be a curated subset
        blockOrder = ord.isEmpty ? AudioEngine.defaultOrder : ord
        applyOrder()
        pedalEnabled = p.pedalOn; pedalDriveDb = p.pedalDrive; pedalLevelDb = p.pedalLevel
        selectedPedalModelID = p.pedalModel.isEmpty ? nil : p.pedalModel
        applyCabIR(p.cabIR)
        irReverbEnabled = p.irReverbOn; irReverbMixPct = p.irReverbMix; irReverbPredelayMs = p.irReverbPredelay
        applyReverbIR(p.irReverbIR)
    }

    // MARK: - Audio

    func toggle() { state == .running ? stop() : start() }

    private var starting = false
    func start() {
        guard state == .stopped, !starting else { return }
        starting = true
        lastError = nil
        Task { await requestMicThenStart(); starting = false }
    }

    private func requestMicThenStart() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { lastError = "Microphone access denied. Enable it in Settings → NamRig."; return }
        do {
            try configureSession()
            try startEngine()
            refreshMetrics()
            state = .running
            startTuner()
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
        context.chain.prepare(sampleRate: inputFormat.sampleRate, maxBlock: 4096)
        context.chain.reset()
        context.sr = inputFormat.sampleRate
        context.cpuLoad = 0
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
            let t0 = DispatchTime.now().uptimeNanoseconds

            var inP: Float = 0
            var aw = context.analysisW
            for i in 0..<n {
                let v = s[i]
                context.analysis[aw] = v          // capture dry input for the tuner
                aw = (aw + 1) & 4095
                let a = abs(v); if a > inP { inP = a }
            }
            context.analysisW = aw
            context.inPeak = inP

            // The block chain: gate → amp → (future effects).
            context.chain.render(s, n)

            var outP: Float = 0
            for i in 0..<n { let a = abs(s[i]); if a.isFinite && a > outP { outP = a } }
            context.outPeak = outP

            let og = context.outputGain
            for i in 0..<n {
                var v = s[i] * og
                if !v.isFinite { v = 0 } else if v > 1 { v = 1 } else if v < -1 { v = -1 }
                s[i] = v
            }

            // DSP load = processing time / buffer time (smoothed).
            let bufNs = Double(n) / context.sr * 1e9
            if bufNs > 0 {
                let used = Float(Double(DispatchTime.now().uptimeNanoseconds - t0) / bufNs)
                context.cpuLoad = context.cpuLoad * 0.9 + used * 0.1
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
        inputSampleRate = engine.inputNode.inputFormat(forBus: 0).sampleRate
        outputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    }

    // MARK: - Tuner

    private func startTuner() {
        tunerTimer?.invalidate()
        tunerTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTuner() }
        }
    }

    private func updateTuner() {
        guard state == .running else { return }
        let need = Tuner.framesNeeded, cap = 4096, w = context.analysisW
        var buf = [Float](repeating: 0, count: need)
        for i in 0..<need { buf[i] = context.analysis[((w - need + i) % cap + cap) % cap] }
        if let (freq, clarity) = Tuner.detect(buf, sampleRate: Float(context.sr)), clarity > 0.5 {
            let n = Tuner.note(forFreq: freq)
            tunerNote = n.name; tunerCents = n.cents; tunerActive = true
        } else {
            tunerActive = false
        }
    }

    func stop() {
        guard state == .running else { return }
        tunerTimer?.invalidate(); tunerTimer = nil; tunerActive = false
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
