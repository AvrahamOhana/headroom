//
//  AudioEngine.swift
//  NamRig — live guitar → block chain → output.
//
//  Render: input → [SignalChain: Gate → Amp → …future fx] → output gain + clamp.
//

import AVFoundation
import Observation
import Synchronization
#if os(macOS)
import CoreAudio
#endif

/// State the real-time render callbacks touch. NOT MainActor-isolated.
final class RenderContext: @unchecked Sendable {
    let ring = FloatRingBuffer(capacity: 16_384)
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let chainA = SignalChain()
    let chainB = SignalChain()
    var outputGain: Float = 1 { didSet { outSm.target = outputGain } }
    var outSm = Smoother(1)
    var inPeak: Float = 0
    var outPeak: Float = 0
    var sr: Double = 48000
    var cpuLoad: Float = 0   // DSP time / buffer time (smoothed)
    let analysis = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4096)  // dry-input ring for the tuner
    var analysisW = 0

    // End-of-chain phrase looper (records / plays the final processed tone).
    let looper = LooperEngine()

    // Dual path (A ∥ B): two complete chains fed the same input, each with level × equal-power pan
    // (4 smoothed gains) into the stereo output. Bit-identical mono path when dualEnabled is false.
    var dualEnabled = false
    var gAL = Smoother(0.7), gAR = Smoother(0.7), gBL = Smoother(0.7), gBR = Smoother(0.7)
    let bufB = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let bufR = UnsafeMutablePointer<Float>.allocate(capacity: 4096)   // right channel after the A/B mix
    let mid = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let midPre = UnsafeMutablePointer<Float>.allocate(capacity: 4096)

    // Tier-1 stereo output stage (mono chain → wide stereo). Bit-identical mono when stereoEnabled is false.
    let ping = PingPongDelay()
    let rev = StereoReverb()
    var stereoEnabled = false
    let ppL = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let ppR = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let rvL = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    let rvR = UnsafeMutablePointer<Float>.allocate(capacity: 4096)

    init() {
        analysis.initialize(repeating: 0)
        ppL.initialize(repeating: 0, count: 4096); ppR.initialize(repeating: 0, count: 4096)
        rvL.initialize(repeating: 0, count: 4096); rvR.initialize(repeating: 0, count: 4096)
        bufB.initialize(repeating: 0, count: 4096); bufR.initialize(repeating: 0, count: 4096)
        mid.initialize(repeating: 0, count: 4096); midPre.initialize(repeating: 0, count: 4096)
    }
    deinit {
        scratch.deallocate(); analysis.deallocate()
        ppL.deallocate(); ppR.deallocate(); rvL.deallocate(); rvR.deallocate()
        bufB.deallocate(); bufR.deallocate(); mid.deallocate(); midPre.deallocate()
    }
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
        // Factory-bundled captures. Only ship models you OWN or that are explicitly
        // licensed for commercial redistribution (e.g. your own NAM training, or a CC0
        // capture). Do NOT bundle third-party TONE3000 captures. To add one, drop
        // `YourModel.nam` in NamRig/Models and add ("YourModel", "Display Name") below.
        let bundled: [(String, String)] = [("Bugera V5", "Bugera V5")]
        for (res, name) in bundled {
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
    enum ModelSlot { case amp, pedal }
    func importModel(from url: URL, artworkURL: String? = nil, gear: String? = nil, slot: ModelSlot = .amp) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dest = modelsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest) }
        catch { P.modelStatus = "❌ Import failed: \(error.localizedDescription)"; return }
        let base = dest.deletingPathExtension().lastPathComponent
        if let gear { try? gear.write(to: modelsDir.appendingPathComponent(base + ".gear"), atomically: true, encoding: .utf8) }
        refreshModels()
        switch slot {
        case .amp: selectedModelID = dest.lastPathComponent
        case .pedal: selectedPedalModelID = dest.lastPathComponent
        }
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
    // Per-path status (the focused path's), see RigPath.
    var modelStatus: String { P.modelStatus }
    var pedalStatus: String { P.pedalStatus }
    var cabIRName: String { P.cabIRName }
    var irReverbName: String { P.irReverbName }
    private(set) var tunerNote = "—"
    private(set) var tunerCents = 0
    private(set) var tunerActive = false
    private(set) var presets: [Preset] = PresetStore.load()
    private(set) var currentPresetIndex = 0
    var currentPresetName: String { presets.indices.contains(currentPresetIndex) ? presets[currentPresetIndex].name : "Init" }

    // UI parameters → blocks / engine.
    var selectedModelID: String = "Bugera V5" {
        didSet { if oldValue != selectedModelID { loadModel() } }
    }
    var ampEnabled = true {
        didSet { P.amp.bypass.store(!ampEnabled, ordering: .relaxed) }
    }
    var inputDriveDb: Double = 0 {
        didSet { P.amp.inputGain = powf(10, Float(inputDriveDb) / 20); paramDidChange?(.ampDrive, paramNormalized(.ampDrive)) }
    }
    var pedalEnabled = false { didSet { P.pedal.bypass.store(!pedalEnabled, ordering: .relaxed) } }
    var selectedPedalModelID: String? = nil { didSet { if oldValue != selectedPedalModelID { loadPedalModel() } } }
    var pedalDriveDb: Double = 0 { didSet { P.pedal.inputGain = powf(10, Float(pedalDriveDb) / 20); paramDidChange?(.pedalDrive, paramNormalized(.pedalDrive)) } }
    var pedalLevelDb: Double = 0 { didSet { P.pedal.makeupGain = powf(10, Float(pedalLevelDb) / 20); paramDidChange?(.pedalLevel, paramNormalized(.pedalLevel)) } }
    var selectedPedalName: String { selectedPedalModelID.flatMap { id in models.first { $0.id == id }?.name } ?? "None" }
    var gateEnabled = true {
        didSet { P.gate.bypass.store(!gateEnabled, ordering: .relaxed) }
    }
    var gateThresholdDb: Double = -34 { didSet { P.gate.thresholdDb = Float(gateThresholdDb); paramDidChange?(.gateThr, paramNormalized(.gateThr)) } }
    var gateReleaseMs: Double = 80 { didSet { P.gate.releaseMs = Float(gateReleaseMs) } }
    var gateRangeDb: Double = -80 { didSet { P.gate.rangeDb = Float(gateRangeDb) } }

    // Wah — expression-pedal target (map a CC → MIDIParam.wah) or auto-envelope.
    var wahEnabled = false { didSet { P.wah.bypass.store(!wahEnabled, ordering: .relaxed) } }
    var wahPosition: Double = 0.5 { didSet { P.wah.position = Float(wahPosition); paramDidChange?(.wah, paramNormalized(.wah)) } }
    var wahAuto = false { didSet { P.wah.auto = wahAuto } }
    var wahSense: Double = 50 { didSet { P.wah.sensitivity = Float(wahSense / 100) } }
    var wahMix: Double = 92 { didSet { P.wah.mix = Float(wahMix / 100) } }
    var outputLevelDb: Double = -6 {
        didSet { if !muted { context.outputGain = powf(10, Float(outputLevelDb) / 20) }; paramDidChange?(.output, paramNormalized(.output)) }
    }
    /// Instant MUTE / panic — silences output WITHOUT tearing down the engine (no restart hitch). Transient (not saved).
    var muted = false { didSet { context.outputGain = muted ? 0 : powf(10, Float(outputLevelDb) / 20) } }
    func toggleMute() { muted.toggle() }
    /// Set by a MIDI footswitch; the UI observes it to present/dismiss the tuner.
    var tunerRequested = false
    // Tier-1 stereo output stage (per-preset). `stereoWidth` drives both the ping-pong spread and the reverb width.
    var stereoOn = false { didSet { context.stereoEnabled = stereoOn } }
    var stereoPingMix: Double = 25 { didSet { context.ping.mixPct = Float(stereoPingMix) } }
    var stereoPingTime: Double = 350 { didSet { context.ping.timeMs = Float(stereoPingTime) } }
    var stereoPingFb: Double = 30 { didSet { context.ping.feedbackPct = Float(stereoPingFb) } }
    var stereoSpace: Double = 18 { didSet { context.rev.mixPct = Float(stereoSpace) } }
    var stereoWidth: Double = 100 { didSet { context.ping.spreadPct = Float(stereoWidth); context.rev.widthPct = Float(stereoWidth) } }

    // End-of-chain phrase looper.
    var loopLevel: Double = 100 { didSet { context.looper.loopLevel = Float(loopLevel / 100); paramDidChange?(.loopLevel, paramNormalized(.loopLevel)) } }
    private(set) var looperStateLabel = "Idle"
    var looperHasLoop: Bool { context.looper.hasLoop }
    func toggleLooper() { context.looper.toggle(); looperStateLabel = context.looper.stateName }
    func stopLooper() { context.looper.stopPlayback(); looperStateLabel = context.looper.stateName }
    func clearLooper() { context.looper.clear(); looperStateLabel = context.looper.stateName }
    var eqEnabled = true {
        didSet { P.eq.bypass.store(!eqEnabled, ordering: .relaxed) }
    }
    var bassDb: Double = 0 { didSet { updateEQ(); paramDidChange?(.bass, paramNormalized(.bass)) } }
    var midDb: Double = 0 { didSet { updateEQ(); paramDidChange?(.mid, paramNormalized(.mid)) } }
    var trebleDb: Double = 0 { didSet { updateEQ(); paramDidChange?(.treble, paramNormalized(.treble)) } }

    var delayEnabled = false { didSet { P.delay.bypass.store(!delayEnabled, ordering: .relaxed) } }
    var delayTimeMs: Double = 350 { didSet { P.delay.delaySamples = Int(delayTimeMs / 1000 * preferredSampleRate) } }
    var delayFeedbackPct: Double = 35 { didSet { P.delay.feedback = Float(delayFeedbackPct / 100); paramDidChange?(.delayFb, paramNormalized(.delayFb)) } }
    var delayMixPct: Double = 30 { didSet { P.delay.mix = Float(delayMixPct / 100); paramDidChange?(.delayMix, paramNormalized(.delayMix)) } }
    var delayTonePct: Double = 60 { didSet { P.delay.tone = Float(delayTonePct / 100); paramDidChange?(.delayTone, paramNormalized(.delayTone)) } }
    var compGainReductionDb: Float { P.comp.gainReductionDb }

    // Tap-tempo (Tempo.swift) — when delaySync is on, the delay time follows BPM × note division.
    var tempo = TempoClock()
    var bpm: Double {
        get { tempo.bpm }
        set { tempo.bpm = newValue; if delaySync { applyTempoToDelay() } }
    }
    var delaySync = false { didSet { if delaySync { applyTempoToDelay() } } }
    var delayDivision: TempoClock.NoteDivision = .eighth { didSet { if delaySync { applyTempoToDelay() } } }
    func tapTempo() { tempo.tap(at: ProcessInfo.processInfo.systemUptime); if delaySync { applyTempoToDelay() } }
    private func applyTempoToDelay() { delayTimeMs = min(max(tempo.ms(delayDivision), 50), 1000) }

    var reverbEnabled = false { didSet { P.reverb.bypass.store(!reverbEnabled, ordering: .relaxed) } }
    var reverbDecayPct: Double = 70 { didSet { updateReverb(); paramDidChange?(.reverbDecay, paramNormalized(.reverbDecay)) } }
    var reverbDampPct: Double = 30 { didSet { updateReverb() } }
    var reverbMixPct: Double = 25 { didSet { updateReverb(); paramDidChange?(.reverbMix, paramNormalized(.reverbMix)) } }

    var irReverbEnabled = false { didSet { P.irReverb.bypass.store(!irReverbEnabled, ordering: .relaxed) } }
    var irReverbMixPct: Double = 35 { didSet { P.irReverb.mix = Float(irReverbMixPct / 100) } }
    var irReverbPredelayMs: Double = 0 { didSet { P.irReverb.setPredelay(ms: Float(irReverbPredelayMs)) } }
    var cabEnabled = true { didSet { P.cab.bypass.store(!cabEnabled, ordering: .relaxed) } }

    var compEnabled = false { didSet { P.comp.bypass.store(!compEnabled, ordering: .relaxed) } }
    var compThresholdDb: Double = -18 { didSet { P.comp.thresholdDb = Float(compThresholdDb); paramDidChange?(.compThr, paramNormalized(.compThr)) } }
    var compRatio: Double = 4 { didSet { P.comp.ratio = Float(compRatio) } }
    var compAttackMs: Double = 10 { didSet { P.comp.setTimes(attackMs: Float(compAttackMs), releaseMs: Float(compReleaseMs)) } }
    var compReleaseMs: Double = 120 { didSet { P.comp.setTimes(attackMs: Float(compAttackMs), releaseMs: Float(compReleaseMs)) } }
    var compMakeupDb: Double = 0 { didSet { P.comp.makeup = powf(10, Float(compMakeupDb) / 20); paramDidChange?(.compMakeup, paramNormalized(.compMakeup)) } }

    var driveEnabled = false { didSet { P.drive.bypass.store(!driveEnabled, ordering: .relaxed) } }
    var driveAmount: Double = 4 { didSet { P.drive.drive = Float(driveAmount); paramDidChange?(.driveAmt, paramNormalized(.driveAmt)) } }
    var driveToneHz: Double = 4000 { didSet { P.drive.setTone(hz: Float(driveToneHz)) } }
    var driveLevelDb: Double = 0 { didSet { P.drive.level = powf(10, Float(driveLevelDb) / 20); paramDidChange?(.driveLevel, paramNormalized(.driveLevel)) } }

    var driveMode: Int = 0 { didSet { P.drive.mode = driveMode } }

    var stompEnabled = false { didSet { P.circuitDrive.bypass.store(!stompEnabled, ordering: .relaxed) } }
    var stompModel: Int = 0 { didSet { P.circuitDrive.model = stompModel } }
    var stompDrive: Double = 0.5 { didSet { P.circuitDrive.drive = Float(stompDrive); paramDidChange?(.stompDrive, paramNormalized(.stompDrive)) } }
    var stompTone: Double = 0.5 { didSet { P.circuitDrive.tone = Float(stompTone) } }
    var stompLevel: Double = 0.8 { didSet { P.circuitDrive.level = Float(stompLevel) } }
    var stompModelCount: Int { P.circuitDrive.modelCount }
    func stompModelName(_ i: Int) -> String { P.circuitDrive.modelName(i) }

    var boostEnabled = false { didSet { P.boost.bypass.store(!boostEnabled, ordering: .relaxed) } }
    var boostDb: Double = 6 { didSet { P.boost.gain = powf(10, Float(boostDb) / 20); paramDidChange?(.boostDb, paramNormalized(.boostDb)) } }

    var chorusEnabled = false { didSet { P.chorus.bypass.store(!chorusEnabled, ordering: .relaxed) } }
    var chorusRateHz: Double = 0.8 { didSet { P.chorus.rateHz = Float(chorusRateHz) } }
    var chorusDepthMs: Double = 6 { didSet { P.chorus.depthMs = Float(chorusDepthMs) } }
    var chorusMixPct: Double = 40 { didSet { P.chorus.mix = Float(chorusMixPct / 100); paramDidChange?(.chorusMix, paramNormalized(.chorusMix)) } }

    var flangerEnabled = false { didSet { P.flanger.bypass.store(!flangerEnabled, ordering: .relaxed) } }
    var flangerRateHz: Double = 0.4 { didSet { P.flanger.rateHz = Float(flangerRateHz) } }
    var flangerDepthMs: Double = 2 { didSet { P.flanger.depthMs = Float(flangerDepthMs) } }
    var flangerFeedbackPct: Double = 50 { didSet { P.flanger.feedback = Float(flangerFeedbackPct / 100) } }
    var flangerMixPct: Double = 50 { didSet { P.flanger.mix = Float(flangerMixPct / 100); paramDidChange?(.flangerMix, paramNormalized(.flangerMix)) } }

    var tremoloEnabled = false { didSet { P.tremolo.bypass.store(!tremoloEnabled, ordering: .relaxed) } }
    var tremoloRateHz: Double = 5 { didSet { P.tremolo.rateHz = Float(tremoloRateHz) } }
    var tremoloDepthPct: Double = 50 { didSet { P.tremolo.depth = Float(tremoloDepthPct / 100); paramDidChange?(.tremoloDepth, paramNormalized(.tremoloDepth)) } }

    var reverbType: Int = 3 { didSet { updateReverb() } }   // 0 room · 1 plate · 2 spring · 3 hall (real algorithm)
    func selectReverbType(_ t: Int) {
        reverbType = t
        switch t {
        case 0: reverbDecayPct = 35; reverbDampPct = 60    // room  → FDN .room
        case 1: reverbDecayPct = 88; reverbDampPct = 12    // plate → Dattorro
        case 2: reverbDecayPct = 55; reverbDampPct = 35    // spring
        default: reverbDecayPct = 80; reverbDampPct = 18   // hall  → FDN .hall
        }
    }
    /// Map the reverb knobs onto whichever real algorithm `reverbType` selects (plate/spring/FDN room+hall).
    private func updateReverb() {
        P.reverb.configure(type: reverbType, decayPct: reverbDecayPct, dampPct: reverbDampPct, mixPct: reverbMixPct)
    }

    // Free-order chain (of the FOCUSED path) — `blockOrder` is a curated subset of block kinds.
    static let defaultOrder: [BlockKind] = [.gate, .comp, .boost, .drive, .pedal, .amp, .cab, .eq, .chorus, .flanger, .tremolo, .delay, .reverb, .irReverb]
    var blockOrder: [BlockKind] = [.gate, .comp, .boost, .drive, .pedal, .amp, .cab, .eq, .chorus, .flanger, .tremolo, .delay, .reverb, .irReverb]
    func applyOrder() { P.chain.reorder(blockOrder.compactMap { P.indexByKind[$0] }) }

    // MARK: - Dual path (A ∥ B) + focus

    var dualOn = false { didSet { context.dualEnabled = dualOn } }
    var pathALevelDb: Double = 0 { didSet { updateDualMix(); paramDidChange?(.ampALevel, paramNormalized(.ampALevel)) } }
    var pathBLevelDb: Double = 0 { didSet { updateDualMix(); paramDidChange?(.ampBLevel, paramNormalized(.ampBLevel)) } }
    var pathAPan: Double = -0.7 { didSet { updateDualMix() } }   // −1 L … +1 R
    var pathBPan: Double = 0.7 { didSet { updateDualMix() } }
    private func updateDualMix() {
        let gA = powf(10, Float(pathALevelDb) / 20), gB = powf(10, Float(pathBLevelDb) / 20)
        let pA = equalPowerPan(Float(pathAPan)), pB = equalPowerPan(Float(pathBPan))
        context.gAL.target = gA * pA.l; context.gAR.target = gA * pA.r
        context.gBL.target = gB * pB.l; context.gBR.target = gB * pB.r
    }

    /// Make `id` the path the flat params edit. Snapshots the old path, applies the new one (no
    /// model reloads when the blocks already hold that model — cheap enough to do per MIDI message).
    func setFocus(_ id: RigPathID) {
        guard id != focusRaw else { return }
        P.state = capturePath()
        focusRaw = id
        applyPath(P.state, force: false)
    }
    /// Run `body` with `id` focused, then restore the previous focus.
    func withFocus(_ id: RigPathID, _ body: () -> Void) {
        let prev = focusRaw
        setFocus(id); body(); setFocus(prev)
    }
    func order(of id: RigPathID) -> [BlockKind] { id == focusRaw ? blockOrder : path(id).state.kinds }
    func isBlockEnabled(_ kind: BlockKind, in id: RigPathID) -> Bool { id == focusRaw ? isBlockEnabled(kind) : path(id).state.isOn(kind) }
    func setBlockEnabled(_ kind: BlockKind, _ on: Bool, in id: RigPathID) { withFocus(id) { setBlockEnabled(kind, on) } }
    func availableToAdd(in id: RigPathID) -> [BlockKind] { BlockKind.allCases.filter { !order(of: id).contains($0) } }
    func addBlock(_ kind: BlockKind, in id: RigPathID) { withFocus(id) { addBlock(kind) } }
    func removeBlock(_ kind: BlockKind, in id: RigPathID) { withFocus(id) { removeBlock(kind) } }
    /// Drag & drop: move `kind` from one path to (before `before` in) another, or reorder within a path.
    /// Across paths the block's settings travel with it.
    func moveBlock(_ kind: BlockKind, from: RigPathID, to: RigPathID, before: BlockKind?) {
        if from == to {
            withFocus(to) {
                var o = blockOrder; o.removeAll { $0 == kind }
                if let b = before, let i = o.firstIndex(of: b) { o.insert(kind, at: i) } else { o.append(kind) }
                setOrder(o)
            }
            return
        }
        guard !order(of: to).contains(kind) else { return }
        withFocus(from) { path(from).state = capturePath(); removeBlock(kind) }
        let src = path(from).state
        withFocus(to) {
            var st = capturePath(); st.copy(kind, from: src)
            applyPath(st, force: false)
            var o = blockOrder
            if let b = before, let i = o.firstIndex(of: b) { o.insert(kind, at: i) } else { o.append(kind) }
            setOrder(o)
        }
    }
    func setOrder(_ newOrder: [BlockKind]) { blockOrder = newOrder; applyOrder() }
    var availableToAdd: [BlockKind] { BlockKind.allCases.filter { !blockOrder.contains($0) } }
    func addBlock(_ kind: BlockKind) {
        guard !blockOrder.contains(kind) else { return }
        // Drive-family / pre-amp blocks belong in FRONT of the amp; everything else appends to the tail.
        let preAmp: Set<BlockKind> = [.gate, .comp, .boost, .drive, .stomp, .wah, .pedal]
        if preAmp.contains(kind), let ampIdx = blockOrder.firstIndex(of: .amp) {
            blockOrder.insert(kind, at: ampIdx)
        } else {
            blockOrder.append(kind)
        }
        setBlockEnabled(kind, true); applyOrder()
    }
    func removeBlock(_ kind: BlockKind) { blockOrder.removeAll { $0 == kind }; applyOrder() }
    func setBlockEnabled(_ kind: BlockKind, _ on: Bool) {
        switch kind {
        case .gate: gateEnabled = on; case .comp: compEnabled = on; case .boost: boostEnabled = on
        case .drive: driveEnabled = on; case .stomp: stompEnabled = on; case .wah: wahEnabled = on; case .pedal: pedalEnabled = on; case .amp: ampEnabled = on; case .cab: cabEnabled = on
        case .eq: eqEnabled = on; case .chorus: chorusEnabled = on; case .flanger: flangerEnabled = on
        case .tremolo: tremoloEnabled = on; case .delay: delayEnabled = on; case .reverb: reverbEnabled = on
        case .irReverb: irReverbEnabled = on
        }
    }
    func isBlockEnabled(_ kind: BlockKind) -> Bool {
        switch kind {
        case .gate: return gateEnabled; case .comp: return compEnabled; case .boost: return boostEnabled
        case .drive: return driveEnabled; case .stomp: return stompEnabled; case .wah: return wahEnabled; case .pedal: return pedalEnabled; case .amp: return ampEnabled; case .cab: return cabEnabled
        case .eq: return eqEnabled; case .chorus: return chorusEnabled; case .flanger: return flangerEnabled
        case .tremolo: return tremoloEnabled; case .delay: return delayEnabled; case .reverb: return reverbEnabled
        case .irReverb: return irReverbEnabled
        }
    }

    var modelLoaded: Bool { P.amp.hasModel }
    var inPeakDb: Float { Self.toDb(context.inPeak) }
    var outPeakDb: Float { Self.toDb(context.outPeak) }
    var cpuPercent: Int { max(0, min(999, Int((context.cpuLoad * 100).rounded()))) }

    /// Buffer round-trip — the part we control, and what you actually feel.
    var roundTripMs: Double { state == .running ? ioBufferMs * 2 : 0 }
    /// AVAudioSession's reported hardware I/O latency (often inflated / route-dependent — reference only).
    var reportedLatencyMs: Double { state == .running ? inputLatencyMs + outputLatencyMs : 0 }

    private let engine = AVAudioEngine()
    private let context = RenderContext()
    // Two complete paths. The flat params above always mirror the FOCUSED path (`P`); the other
    // path keeps its own block instances + `state` snapshot and renders live when dual is on.
    private let pathA: RigPath
    private let pathB: RigPath
    private var focusRaw: RigPathID = .a
    var focus: RigPathID { focusRaw }
    private var P: RigPath { focusRaw == .a ? pathA : pathB }
    func path(_ id: RigPathID) -> RigPath { id == .a ? pathA : pathB }
    /// Which path MIDI param/toggle mappings act on (nil = whichever is focused).
    var midiPath: RigPathID? = .a
    private var sinkNode: AVAudioSinkNode?
    private var sourceNode: AVAudioSourceNode?
    private var tunerTimer: Timer?

    private let preferredSampleRate: Double = 48_000
    var preferredBufferFrames: Double = 128 {   // user-tunable in Settings (Low / Balanced / Safe)
        didSet { if preferredBufferFrames != oldValue, state == .running { stop(); start() } }
    }

    init() {
        pathA = RigPath(id: .a, chain: context.chainA)
        pathB = RigPath(id: .b, chain: context.chainB)
        refreshModels()
        if !models.contains(where: { $0.id == selectedModelID }) { selectedModelID = models.first?.id ?? selectedModelID }
        // Configure BOTH paths' blocks from the default state, then leave A focused.
        var initial = capturePath(); initial.model = selectedModelID
        pathB.state = initial
        focusRaw = .b; applyPath(initial, force: false)
        focusRaw = .a; applyPath(initial, force: false)
        context.outputGain = powf(10, Float(outputLevelDb) / 20)
        updateDualMix()
        applyOrder()
    }

    private func updateEQ() { P.eq.setBands(bass: Float(bassDb), mid: Float(midDb), treble: Float(trebleDb)) }

    static func toDb(_ x: Float) -> Float { x > 1e-6 ? 20 * log10(x) : -120 }

    // MARK: - Model

    /// Load a capture + level-match it. Prefers the trainer's own loudness metadata (target −18 dB,
    /// like the official plugin); falls back to a sine probe. Makeup is capped at +12 dB either way —
    /// a quiet capture boosted +36 dB is pure hiss.
    private func loadNAM(path: String) throws -> (model: NAMModel, makeupDb: Double, how: String) {
        let model = NAMModel()
        try model.loadModel(fromPath: path)
        model.prepare(withSampleRate: preferredSampleRate, maxBlockSize: 4096)
        var makeupDb: Double
        let how: String
        if model.loudness.isFinite {
            makeupDb = -18 - model.loudness; how = "loudness \(String(format: "%.1f", model.loudness)) dB"
        } else {
            let probe = selfTest(model)
            model.prepare(withSampleRate: preferredSampleRate, maxBlockSize: 4096)
            makeupDb = probe.nan ? 0 : Double(20 * log10(0.4 / max(probe.peak, 1e-4))); how = "probe"
        }
        return (model, max(-24, min(12, makeupDb)), how)
    }

    func loadModel(force: Bool = false) {
        guard let tm = models.first(where: { $0.id == selectedModelID }) ?? models.first else {
            P.modelStatus = "❌ no models found"; P.amp.setModel(nil); P.loadedModelID = ""; return
        }
        if !force && P.loadedModelID == tm.id { return }
        P.loadedModelID = tm.id
        do {
            let r = try loadNAM(path: tm.path)
            P.amp.setModel(r.model)
            P.amp.makeupGain = powf(10, Float(r.makeupDb) / 20)
            P.modelStatus = "\(tm.name) · \(r.how) · trim \(String(format: "%+.0f", r.makeupDb)) dB"
        } catch {
            P.amp.setModel(nil)
            P.modelStatus = "❌ Load failed: \(error.localizedDescription)"
        }
    }

    /// Load the pedal-slot capture (a 2nd neural model in front of the amp). No auto-level — the
    /// user sets Drive/Level so the pedal hits the amp the way they want.
    func loadPedalModel(force: Bool = false) {
        guard let id = selectedPedalModelID, !id.isEmpty,
              let tm = models.first(where: { $0.id == id }) else {
            P.pedal.setModel(nil); P.pedalStatus = "— empty —"; P.loadedPedalID = ""; return
        }
        if !force && P.loadedPedalID == id { return }
        P.loadedPedalID = id
        let model = NAMModel()
        do {
            try model.loadModel(fromPath: tm.path)
            model.prepare(withSampleRate: preferredSampleRate, maxBlockSize: 4096)
            P.pedal.setModel(model)
            P.pedal.makeupGain = powf(10, Float(pedalLevelDb) / 20)
            P.pedalStatus = tm.name
        } catch {
            P.pedal.setModel(nil)
            P.pedalStatus = "❌ Load failed"
        }
    }

    // MARK: - Cab IR

    func loadCabIR(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let taps = Self.loadIRSamples(url, targetSR: preferredSampleRate), !taps.isEmpty else {
            P.modelStatus = "❌ Cab IR load failed"; return
        }
        let dest = irsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        P.cabIRFile = url.lastPathComponent
        P.cabIRName = url.deletingPathExtension().lastPathComponent
        P.cab.setIR(taps)
    }
    func clearCabIR() { P.cabIRFile = ""; P.cabIRName = "None"; P.cab.clearIR() }
    private func applyCabIR(_ file: String, force: Bool = false) {
        guard !file.isEmpty else { clearCabIR(); return }
        if !force && P.cabIRFile == file { return }
        let url = irsDir.appendingPathComponent(file)
        if let taps = Self.loadIRSamples(url, targetSR: preferredSampleRate), !taps.isEmpty {
            P.cabIRFile = file; P.cabIRName = url.deletingPathExtension().lastPathComponent; P.cab.setIR(taps)
        } else { clearCabIR() }
    }
    func loadReverbIR(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let taps = Self.loadReverbIRSamples(url, targetSR: preferredSampleRate), !taps.isEmpty else {
            P.modelStatus = "❌ Reverb IR load failed"; return
        }
        let dest = irsDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        P.irReverbFile = url.lastPathComponent
        P.irReverbName = url.deletingPathExtension().lastPathComponent
        P.irReverb.setIR(taps)
    }
    func clearReverbIR() { P.irReverbFile = ""; P.irReverbName = "None"; P.irReverb.clearIR() }
    private func applyReverbIR(_ file: String, force: Bool = false) {
        guard !file.isEmpty else { clearReverbIR(); return }
        if !force && P.irReverbFile == file { return }
        let url = irsDir.appendingPathComponent(file)
        if let taps = Self.loadReverbIRSamples(url, targetSR: preferredSampleRate), !taps.isEmpty {
            P.irReverbFile = file; P.irReverbName = url.deletingPathExtension().lastPathComponent; P.irReverb.setIR(taps)
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

    /// Fired after a preset is applied (MIDI out: Program Change + the preset's own send list).
    var presetDidLoad: ((Int, Preset) -> Void)?
    /// Fired when a MIDI-mappable param moves from the UI (controller feedback).
    var paramDidChange: ((MIDIParam, Double) -> Void)?

    func loadPreset(at i: Int) {
        guard presets.indices.contains(i) else { return }
        currentPresetIndex = i
        apply(presets[i])
        presetDidLoad?(i, presets[i])
    }
    /// Per-preset MIDI-out list (messages sent to external gear when this preset loads).
    var currentMidiOut: [MIDIOutMessage] {
        get { presets.indices.contains(currentPresetIndex) ? presets[currentPresetIndex].midiOut : [] }
        set { guard presets.indices.contains(currentPresetIndex) else { return }; presets[currentPresetIndex].midiOut = newValue; PresetStore.save(presets) }
    }
    func nextPreset() { guard !presets.isEmpty else { return }; loadPreset(at: (currentPresetIndex + 1) % presets.count) }
    func prevPreset() { guard !presets.isEmpty else { return }; loadPreset(at: (currentPresetIndex - 1 + presets.count) % presets.count) }

    // MARK: - Live mode + MIDI hooks

    static let liveBankSize = 4
    var bankIndex: Int { presets.isEmpty ? 0 : currentPresetIndex / Self.liveBankSize }
    var sceneInBank: Int { currentPresetIndex % Self.liveBankSize }
    /// Stage-friendly tag: bank number + scene letter, e.g. "0A", "1C".
    var presetTag: String { "\(bankIndex)\(["A", "B", "C", "D"][min(max(sceneInBank, 0), 3)])" }
    // Index-parameterized tag/scene so the setlist + LiveView can label ANY preset (not just current).
    func bank(for i: Int) -> Int { i / Self.liveBankSize }
    func scene(for i: Int) -> Int { ((i % Self.liveBankSize) + Self.liveBankSize) % Self.liveBankSize }
    func tag(for i: Int) -> String { "\(bank(for: i))\(["A", "B", "C", "D"][min(max(scene(for: i), 0), 3)])" }
    func handleProgramChange(_ pc: Int) { loadPreset(at: pc) }   // loadPreset already range-guards
    /// MIDI block toggle — routed to `midiPath` like params.
    func midiSetBlockEnabled(_ kind: BlockKind, _ on: Bool) { setBlockEnabled(kind, on, in: midiPath ?? focusRaw) }
    func midiIsBlockEnabled(_ kind: BlockKind) -> Bool { isBlockEnabled(kind, in: midiPath ?? focusRaw) }

    /// MIDI CC → engine param (0…1 normalized into the param's range). Reuses the existing didSet→block path.
    func setParam(_ p: MIDIParam, normalized: Double) {
        if let mp = midiPath, mp != focusRaw { withFocus(mp) { setParam(p, normalized: normalized) }; return }
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
        case .wah: wahPosition = v;         case .delayTone: delayTonePct = v;  case .compThr: compThresholdDb = v
        case .stompDrive: stompDrive = v;   case .loopLevel: loopLevel = v
        case .ampALevel: pathALevelDb = v;  case .ampBLevel: pathBLevelDb = v
        }
    }
    /// Current value of a MIDI-mappable param, normalized 0…1 (for controller feedback / MIDI out).
    func paramNormalized(_ p: MIDIParam) -> Double {
        let r = p.range
        let v: Double
        switch p {
        case .ampDrive: v = inputDriveDb;   case .output: v = outputLevelDb;   case .gateThr: v = gateThresholdDb
        case .bass: v = bassDb;             case .mid: v = midDb;              case .treble: v = trebleDb
        case .driveAmt: v = driveAmount;    case .driveLevel: v = driveLevelDb
        case .delayMix: v = delayMixPct;    case .delayFb: v = delayFeedbackPct
        case .reverbMix: v = reverbMixPct;  case .reverbDecay: v = reverbDecayPct
        case .compMakeup: v = compMakeupDb; case .boostDb: v = boostDb
        case .pedalDrive: v = pedalDriveDb; case .pedalLevel: v = pedalLevelDb
        case .chorusMix: v = chorusMixPct;  case .flangerMix: v = flangerMixPct; case .tremoloDepth: v = tremoloDepthPct
        case .wah: v = wahPosition;         case .delayTone: v = delayTonePct;  case .compThr: v = compThresholdDb
        case .stompDrive: v = stompDrive;   case .loopLevel: v = loopLevel
        case .ampALevel: v = pathALevelDb;  case .ampBLevel: v = pathBLevelDb
        }
        return max(0, min(1, (v - r.lowerBound) / (r.upperBound - r.lowerBound)))
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

    // MARK: Setlist editing (live-gig management) — all persist immediately.
    func renamePreset(at i: Int, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard presets.indices.contains(i), !n.isEmpty else { return }
        presets[i].name = n; PresetStore.save(presets)
    }
    func duplicatePreset(at i: Int) {
        guard presets.indices.contains(i) else { return }
        var copy = presets[i]; copy.id = UUID(); copy.name = presets[i].name + " copy"
        presets.insert(copy, at: i + 1)
        if i < currentPresetIndex { currentPresetIndex += 1 }
        PresetStore.save(presets)
    }
    func deletePreset(at i: Int) {
        guard presets.indices.contains(i), presets.count > 1 else { return }
        presets.remove(at: i)
        if currentPresetIndex >= presets.count { currentPresetIndex = presets.count - 1 }
        else if i < currentPresetIndex { currentPresetIndex -= 1 }
        PresetStore.save(presets)
    }
    func movePreset(from source: IndexSet, to destination: Int) {
        let keepID = presets.indices.contains(currentPresetIndex) ? presets[currentPresetIndex].id : nil
        // Manual move — Array.move(fromOffsets:toOffset:) is a SwiftUI extension, unavailable in the engine.
        let sorted = source.sorted()
        let items = sorted.map { presets[$0] }
        for i in sorted.reversed() { presets.remove(at: i) }
        let removedBelow = sorted.filter { $0 < destination }.count
        let insertAt = min(max(destination - removedBelow, 0), presets.count)
        presets.insert(contentsOf: items, at: insertAt)
        if let id = keepID, let idx = presets.firstIndex(where: { $0.id == id }) { currentPresetIndex = idx }
        PresetStore.save(presets)
    }

    /// Snapshot the FOCUSED path's params.
    func capturePath() -> PathState {
        var s = PathState()
        s.model = selectedModelID
        s.ampOn = ampEnabled; s.ampDrive = inputDriveDb
        s.gateOn = gateEnabled; s.gateThr = gateThresholdDb; s.gateRel = gateReleaseMs; s.gateRange = gateRangeDb
        s.compOn = compEnabled; s.compThr = compThresholdDb; s.compRatio = compRatio; s.compAtk = compAttackMs; s.compRel = compReleaseMs; s.compMakeup = compMakeupDb
        s.driveOn = driveEnabled; s.driveAmt = driveAmount; s.driveTone = driveToneHz; s.driveLevel = driveLevelDb; s.driveMode = driveMode
        s.eqOn = eqEnabled; s.bass = bassDb; s.mid = midDb; s.treble = trebleDb
        s.delayOn = delayEnabled; s.delayTime = delayTimeMs; s.delayFb = delayFeedbackPct; s.delayMix = delayMixPct; s.delayTone = delayTonePct
        s.delaySync = delaySync; s.delayDiv = delayDivision
        s.reverbOn = reverbEnabled; s.reverbDecay = reverbDecayPct; s.reverbDamp = reverbDampPct; s.reverbMix = reverbMixPct; s.reverbType = reverbType
        s.boostOn = boostEnabled; s.boostDb = boostDb
        s.stompOn = stompEnabled; s.stompModel = stompModel; s.stompDrive = stompDrive; s.stompTone = stompTone; s.stompLevel = stompLevel
        s.chorusOn = chorusEnabled; s.chorusRate = chorusRateHz; s.chorusDepth = chorusDepthMs; s.chorusMix = chorusMixPct
        s.flangerOn = flangerEnabled; s.flangerRate = flangerRateHz; s.flangerDepth = flangerDepthMs; s.flangerFb = flangerFeedbackPct; s.flangerMix = flangerMixPct
        s.tremoloOn = tremoloEnabled; s.tremoloRate = tremoloRateHz; s.tremoloDepth = tremoloDepthPct
        s.order = blockOrder.map { $0.rawValue }
        s.pedalOn = pedalEnabled; s.pedalModel = selectedPedalModelID ?? ""; s.pedalDrive = pedalDriveDb; s.pedalLevel = pedalLevelDb
        s.cabOn = cabEnabled; s.cabIR = P.cabIRFile
        s.irReverbOn = irReverbEnabled; s.irReverbMix = irReverbMixPct; s.irReverbPredelay = irReverbPredelayMs; s.irReverbIR = P.irReverbFile
        s.wahOn = wahEnabled; s.wahPos = wahPosition; s.wahAuto = wahAuto; s.wahSense = wahSense; s.wahMix = wahMix
        return s
    }

    /// Push a PathState into the FOCUSED path's flat params (→ its blocks). `force` reloads models /
    /// IRs even if already loaded (preset load = fresh state); focus switches pass false.
    private func applyPath(_ s: PathState, force: Bool) {
        let feedback = paramDidChange; paramDidChange = nil
        defer { paramDidChange = feedback; P.delay.snapTime() }
        selectedModelID = s.model
        if force { loadModel(force: true) }
        ampEnabled = s.ampOn; inputDriveDb = s.ampDrive
        gateEnabled = s.gateOn; gateThresholdDb = s.gateThr; gateReleaseMs = s.gateRel; gateRangeDb = s.gateRange
        compEnabled = s.compOn; compThresholdDb = s.compThr; compRatio = s.compRatio; compAttackMs = s.compAtk; compReleaseMs = s.compRel; compMakeupDb = s.compMakeup
        driveEnabled = s.driveOn; driveAmount = s.driveAmt; driveToneHz = s.driveTone; driveLevelDb = s.driveLevel; driveMode = s.driveMode
        eqEnabled = s.eqOn; bassDb = s.bass; midDb = s.mid; trebleDb = s.treble
        delayEnabled = s.delayOn; delayTimeMs = s.delayTime; delayFeedbackPct = s.delayFb; delayMixPct = s.delayMix; delayTonePct = s.delayTone
        delayDivision = s.delayDiv; delaySync = s.delaySync
        reverbEnabled = s.reverbOn; reverbDecayPct = s.reverbDecay; reverbDampPct = s.reverbDamp; reverbMixPct = s.reverbMix; reverbType = s.reverbType
        boostEnabled = s.boostOn; boostDb = s.boostDb
        stompEnabled = s.stompOn; stompModel = s.stompModel; stompDrive = s.stompDrive; stompTone = s.stompTone; stompLevel = s.stompLevel
        chorusEnabled = s.chorusOn; chorusRateHz = s.chorusRate; chorusDepthMs = s.chorusDepth; chorusMixPct = s.chorusMix
        flangerEnabled = s.flangerOn; flangerRateHz = s.flangerRate; flangerDepthMs = s.flangerDepth; flangerFeedbackPct = s.flangerFb; flangerMixPct = s.flangerMix
        tremoloEnabled = s.tremoloOn; tremoloRateHz = s.tremoloRate; tremoloDepthPct = s.tremoloDepth
        var ord = s.kinds
        if ord.isEmpty { ord = AudioEngine.defaultOrder }
        blockOrder = ord
        applyOrder()
        pedalEnabled = s.pedalOn; pedalDriveDb = s.pedalDrive; pedalLevelDb = s.pedalLevel
        selectedPedalModelID = s.pedalModel.isEmpty ? nil : s.pedalModel
        if force { loadPedalModel(force: true) }
        cabEnabled = s.cabOn
        applyCabIR(s.cabIR, force: force)
        irReverbEnabled = s.irReverbOn; irReverbMixPct = s.irReverbMix; irReverbPredelayMs = s.irReverbPredelay
        applyReverbIR(s.irReverbIR, force: force)
        wahEnabled = s.wahOn; wahPosition = s.wahPos; wahAuto = s.wahAuto; wahSense = s.wahSense; wahMix = s.wahMix
    }

    private func capture(name: String) -> Preset {
        P.state = capturePath()
        var p = Preset(name: name, a: pathA.state, b: pathB.state)
        p.dualOn = dualOn; p.levelA = pathALevelDb; p.levelB = pathBLevelDb; p.panA = pathAPan; p.panB = pathBPan
        p.output = outputLevelDb
        p.stereoOn = stereoOn; p.stereoPingMix = stereoPingMix; p.stereoPingTime = stereoPingTime; p.stereoPingFb = stereoPingFb; p.stereoSpace = stereoSpace; p.stereoWidth = stereoWidth
        p.bpm = tempo.bpm
        if presets.indices.contains(currentPresetIndex) { p.midiOut = presets[currentPresetIndex].midiOut }
        return p
    }
    private func apply(_ p: Preset) {
        let keep = focusRaw
        pathA.state = p.a; pathB.state = p.b
        focusRaw = .b; applyPath(p.b, force: true)
        focusRaw = .a; applyPath(p.a, force: true)
        if keep == .b { focusRaw = .b; applyPath(p.b, force: false) }
        dualOn = p.dualOn
        pathALevelDb = p.levelA; pathBLevelDb = p.levelB; pathAPan = p.panA; pathBPan = p.panB
        outputLevelDb = p.output
        stereoOn = p.stereoOn; stereoPingMix = p.stereoPingMix; stereoPingTime = p.stereoPingTime; stereoPingFb = p.stereoPingFb; stereoSpace = p.stereoSpace; stereoWidth = p.stereoWidth
        if p.bpm > 0 { tempo.bpm = p.bpm }
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
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false)
            #endif
            state = .stopped
        }
    }

    #if os(iOS)
    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(preferredSampleRate)
        try session.setPreferredIOBufferDuration(preferredBufferFrames / preferredSampleRate)
        try session.setActive(true)
    }
    #else
    // macOS: no AVAudioSession. The interface is chosen per I/O unit (CoreAudio HAL) and the
    // buffer size is a device property. Selections persist by device NAME (IDs change per boot).
    var inputDeviceName: String? {
        get { UserDefaults.standard.string(forKey: "macInputDevice") }
        set { UserDefaults.standard.set(newValue, forKey: "macInputDevice"); if state == .running { stop(); start() } }
    }
    var outputDeviceName: String? {
        get { UserDefaults.standard.string(forKey: "macOutputDevice") }
        set { UserDefaults.standard.set(newValue, forKey: "macOutputDevice"); if state == .running { stop(); start() } }
    }
    var inputDevices: [AudioDevice] { AudioDevices.inputs }
    var outputDevices: [AudioDevice] { AudioDevices.outputs }
    private var activeInputDevice: AudioDeviceID? = nil
    private var activeOutputDevice: AudioDeviceID? = nil

    private func configureSession() throws {
        let inDev = AudioDevices.inputs.first { $0.name == inputDeviceName }?.id ?? AudioDevices.defaultDevice(input: true)
        let outDev = AudioDevices.outputs.first { $0.name == outputDeviceName }?.id ?? AudioDevices.defaultDevice(input: false)
        guard let inDev else {
            throw NSError(domain: "AudioEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "No audio input device — plug in your interface and pick it in Settings → Audio."])
        }
        // Touch the nodes so their HAL units exist, then point them at the devices BEFORE formats are read.
        _ = engine.inputNode; _ = engine.outputNode
        AudioDevices.assign(inDev, to: engine.inputNode)
        if let outDev { AudioDevices.assign(outDev, to: engine.outputNode) }
        AudioDevices.setBufferFrames(UInt32(preferredBufferFrames), on: inDev)
        if let outDev, outDev != inDev { AudioDevices.setBufferFrames(UInt32(preferredBufferFrames), on: outDev) }
        activeInputDevice = inDev; activeOutputDevice = outDev
    }
    #endif

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No audio input detected — plug in your iRig + guitar and try again."])
        }
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 2) else {
            throw NSError(domain: "AudioEngine", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create the stereo output format."])
        }

        context.ring.reset()
        context.chainA.prepare(sampleRate: inputFormat.sampleRate, maxBlock: 4096)
        context.chainA.reset()
        context.chainB.prepare(sampleRate: inputFormat.sampleRate, maxBlock: 4096); context.chainB.reset()
        context.gAL.prepare(sampleRate: inputFormat.sampleRate, ms: 10); context.gAR.prepare(sampleRate: inputFormat.sampleRate, ms: 10)
        context.gBL.prepare(sampleRate: inputFormat.sampleRate, ms: 10); context.gBR.prepare(sampleRate: inputFormat.sampleRate, ms: 10)
        context.gAL.snap(); context.gAR.snap(); context.gBL.snap(); context.gBR.snap()
        context.looper.prepare(sampleRate: inputFormat.sampleRate, maxBlock: 4096)
        context.ping.prepare(sampleRate: inputFormat.sampleRate, maxBlock: 4096)
        context.rev.prepare(sampleRate: inputFormat.sampleRate, maxBlock: 4096)
        context.ping.reset(); context.rev.reset()
        context.rev.decayPct = 60; context.rev.dampPct = 35
        context.stereoEnabled = stereoOn
        context.ping.mixPct = Float(stereoPingMix); context.ping.timeMs = Float(stereoPingTime)
        context.ping.feedbackPct = Float(stereoPingFb); context.ping.spreadPct = Float(stereoWidth)
        context.rev.mixPct = Float(stereoSpace); context.rev.widthPct = Float(stereoWidth)
        context.sr = inputFormat.sampleRate
        context.cpuLoad = 0
        context.outSm.prepare(sampleRate: inputFormat.sampleRate, ms: 10); context.outSm.snap()
        let context = self.context  // capture the RT box (Sendable), never `self`

        let sink = AVAudioSinkNode { _, frameCount, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(.init(mutating: ablPtr))
            guard let first = abl.first, let data = first.mData else { return noErr }
            context.ring.write(data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            return noErr
        }

        let source = AVAudioSourceNode(format: stereoFormat) { isSilence, _, frameCount, ablPtr in
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

            let out = UnsafeMutableAudioBufferListPointer(ablPtr)
            if context.dualEnabled {
                // ---- Dual: the same input feeds A and B; each is a full chain; level × pan → L/R ----
                let bB = context.bufB, R = context.bufR, mid = context.mid, midPre = context.midPre
                memcpy(bB, s, n * MemoryLayout<Float>.size)
                context.chainA.render(s, n)
                context.chainB.render(bB, n)
                for i in 0..<n {
                    let a = s[i], b = bB[i]
                    let l = a * context.gAL.next() + b * context.gBL.next()
                    R[i] = a * context.gAR.next() + b * context.gBR.next()
                    s[i] = l
                }
                for i in 0..<n { mid[i] = 0.5 * (s[i] + R[i]) }
                memcpy(midPre, mid, n * MemoryLayout<Float>.size)
                context.looper.process(mid, n)                             // loop = the mid; playback added to both sides
                for i in 0..<n { let d = mid[i] - midPre[i]; s[i] += d; R[i] += d; mid[i] = 0.5 * (s[i] + R[i]) }

                var outP: Float = 0
                for i in 0..<n { let a = max(abs(s[i]), abs(R[i])); if a.isFinite && a > outP { outP = a } }
                context.outPeak = outP

                if context.stereoEnabled {
                    context.ping.processStereo(mid, context.ppL, context.ppR, n)
                    context.rev.processStereo(mid, context.rvL, context.rvR, n)
                } else {
                    for i in 0..<n { context.ppL[i] = 0; context.ppR[i] = 0; context.rvL[i] = 0; context.rvR[i] = 0 }
                }
                if out.count >= 2, let dL = out[0].mData?.assumingMemoryBound(to: Float.self), let dR = out[1].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<n {
                        let og = context.outSm.next()
                        var l = (s[i] + context.ppL[i] + context.rvL[i]) * og
                        var r = (R[i] + context.ppR[i] + context.rvR[i]) * og
                        if !l.isFinite { l = 0 } else if l > 1 { l = 1 } else if l < -1 { l = -1 }
                        if !r.isFinite { r = 0 } else if r > 1 { r = 1 } else if r < -1 { r = -1 }
                        dL[i] = l; dR[i] = r
                    }
                } else if let d0 = out.first?.mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<n {
                        var v = mid[i] * context.outSm.next()
                        if !v.isFinite { v = 0 } else if v > 1 { v = 1 } else if v < -1 { v = -1 }
                        d0[i] = v
                    }
                }
                let bufNs = Double(n) / context.sr * 1e9
                if bufNs > 0 { context.cpuLoad = context.cpuLoad * 0.9 + Float(Double(DispatchTime.now().uptimeNanoseconds - t0) / bufNs) * 0.1 }
                return noErr
            }

            // The block chain (mono).
            context.chainA.render(s, n)
            context.looper.process(s, n)   // end-of-chain looper: record / play the final tone

            var outP: Float = 0
            for i in 0..<n { let a = abs(s[i]); if a.isFinite && a > outP { outP = a } }
            context.outPeak = outP

            // Output stage: mono → (optional) wide stereo. Wet-only ping-pong + decorrelated reverb summed
            // on top of the centered dry; bit-identical mono on both channels when stereo is OFF.
            if context.stereoEnabled, out.count >= 2,
               let dL = out[0].mData?.assumingMemoryBound(to: Float.self),
               let dR = out[1].mData?.assumingMemoryBound(to: Float.self) {
                context.ping.processStereo(s, context.ppL, context.ppR, n)   // wet only
                context.rev.processStereo(s, context.rvL, context.rvR, n)    // wet only
                for i in 0..<n {
                    let og = context.outSm.next()
                    var l = (s[i] + context.ppL[i] + context.rvL[i]) * og
                    var r = (s[i] + context.ppR[i] + context.rvR[i]) * og
                    if !l.isFinite { l = 0 } else if l > 1 { l = 1 } else if l < -1 { l = -1 }
                    if !r.isFinite { r = 0 } else if r > 1 { r = 1 } else if r < -1 { r = -1 }
                    dL[i] = l; dR[i] = r
                }
            } else {
                for i in 0..<n {
                    var v = s[i] * context.outSm.next()
                    if !v.isFinite { v = 0 } else if v > 1 { v = 1 } else if v < -1 { v = -1 }
                    s[i] = v
                }
                for buffer in out {
                    guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    memcpy(dst, s, n * MemoryLayout<Float>.size)
                }
            }

            // DSP load = processing time / buffer time (smoothed).
            let bufNs = Double(n) / context.sr * 1e9
            if bufNs > 0 {
                let used = Float(Double(DispatchTime.now().uptimeNanoseconds - t0) / bufNs)
                context.cpuLoad = context.cpuLoad * 0.9 + used * 0.1
            }
            return noErr
        }

        engine.attach(sink)
        engine.attach(source)
        engine.connect(input, to: sink, format: inputFormat)
        engine.connect(source, to: engine.mainMixerNode, format: stereoFormat)
        sinkNode = sink
        sourceNode = source

        engine.prepare()
        try engine.start()
    }

    private func refreshMetrics() {
        inputSampleRate = engine.inputNode.inputFormat(forBus: 0).sampleRate
        outputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        sampleRate = session.sampleRate
        ioBufferMs = session.ioBufferDuration * 1000
        inputLatencyMs = session.inputLatency * 1000
        outputLatencyMs = session.outputLatency * 1000
        #else
        sampleRate = inputSampleRate
        if let d = activeInputDevice, sampleRate > 0 {
            ioBufferMs = Double(AudioDevices.bufferFrames(of: d)) / sampleRate * 1000
            inputLatencyMs = Double(AudioDevices.latencyFrames(of: d, input: true)) / sampleRate * 1000
        }
        if let d = activeOutputDevice, outputSampleRate > 0 {
            outputLatencyMs = Double(AudioDevices.latencyFrames(of: d, input: false)) / outputSampleRate * 1000
        }
        #endif
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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
        state = .stopped
    }
}
