//
//  RigPath.swift
//  NamRig — one complete signal path (A or B) made of block INSTANCES: any kind can appear any
//  number of times (two delays, an EQ before and after the amp, even two amps). Each instance owns
//  its DSP object and a `BlockParams` snapshot. The engine "focuses" one path, and inside it one
//  instance per kind: its flat @Observable params (the knobs / MIDI / bindings) mirror the focused
//  instances; tapping a tile refocuses. Both paths' chains render live.
//

import Foundation
import Observation

enum RigPathID: String, Codable, CaseIterable, Identifiable, Sendable {
    case a, b
    var id: Self { self }
    var label: String { rawValue.uppercased() }
    var other: RigPathID { self == .a ? .b : .a }
}

/// Every block parameter (all kinds in one struct — only the instance's own kind's fields matter).
/// Field names match the legacy flat `Preset` keys on purpose: an old preset decodes straight in.
struct BlockParams: Codable, Equatable {
    var model = ""
    var ampOn = true,    ampDrive = 0.0
    var gateOn = true,   gateThr = -60.0, gateRel = 80.0, gateRange = -80.0
    var compOn = true,   compThr = -18.0, compRatio = 4.0, compAtk = 10.0, compRel = 120.0, compMakeup = 0.0
    var driveOn = true,  driveAmt = 4.0,  driveTone = 4000.0, driveLevel = 0.0, driveMode = 0
    var eqOn = true,     bass = 0.0, mid = 0.0, treble = 0.0
    var delayOn = true,  delayTime = 350.0, delayFb = 35.0, delayMix = 30.0, delayTone = 60.0
    var delaySync = false, delayDiv: TempoClock.NoteDivision = .eighth
    var reverbOn = true, reverbDecay = 70.0, reverbDamp = 30.0, reverbMix = 25.0, reverbType = 3
    var boostOn = true,  boostDb = 6.0
    var stompOn = true,  stompModel = 0, stompDrive = 0.5, stompTone = 0.5, stompLevel = 0.8
    var chorusOn = true, chorusRate = 0.8, chorusDepth = 6.0, chorusMix = 40.0
    var flangerOn = true, flangerRate = 0.4, flangerDepth = 2.0, flangerFb = 50.0, flangerMix = 50.0
    var tremoloOn = true, tremoloRate = 5.0, tremoloDepth = 50.0
    var pedalOn = true,  pedalModel = "", pedalDrive = 0.0, pedalLevel = 0.0
    var cabOn = true,    cabIR = ""
    var irReverbOn = true, irReverbMix = 35.0, irReverbPredelay = 0.0, irReverbIR = ""
    var wahOn = true,    wahPos = 0.5, wahAuto = false, wahSense = 50.0, wahMix = 92.0

    func isOn(_ k: BlockKind) -> Bool {
        switch k {
        case .gate: return gateOn; case .comp: return compOn; case .boost: return boostOn; case .drive: return driveOn
        case .stomp: return stompOn; case .wah: return wahOn; case .pedal: return pedalOn; case .amp: return ampOn; case .cab: return cabOn
        case .eq: return eqOn; case .chorus: return chorusOn; case .flanger: return flangerOn; case .tremolo: return tremoloOn
        case .delay: return delayOn; case .reverb: return reverbOn; case .irReverb: return irReverbOn
        }
    }
    mutating func setOn(_ k: BlockKind, _ v: Bool) {
        switch k {
        case .gate: gateOn = v; case .comp: compOn = v; case .boost: boostOn = v; case .drive: driveOn = v
        case .stomp: stompOn = v; case .wah: wahOn = v; case .pedal: pedalOn = v; case .amp: ampOn = v; case .cab: cabOn = v
        case .eq: eqOn = v; case .chorus: chorusOn = v; case .flanger: flangerOn = v; case .tremolo: tremoloOn = v
        case .delay: delayOn = v; case .reverb: reverbOn = v; case .irReverb: irReverbOn = v
        }
    }

    /// Copy one kind's fields from another params set.
    mutating func copy(_ k: BlockKind, from o: BlockParams) {
        switch k {
        case .gate: gateOn = o.gateOn; gateThr = o.gateThr; gateRel = o.gateRel; gateRange = o.gateRange
        case .comp: compOn = o.compOn; compThr = o.compThr; compRatio = o.compRatio; compAtk = o.compAtk; compRel = o.compRel; compMakeup = o.compMakeup
        case .boost: boostOn = o.boostOn; boostDb = o.boostDb
        case .drive: driveOn = o.driveOn; driveAmt = o.driveAmt; driveTone = o.driveTone; driveLevel = o.driveLevel; driveMode = o.driveMode
        case .stomp: stompOn = o.stompOn; stompModel = o.stompModel; stompDrive = o.stompDrive; stompTone = o.stompTone; stompLevel = o.stompLevel
        case .wah: wahOn = o.wahOn; wahPos = o.wahPos; wahAuto = o.wahAuto; wahSense = o.wahSense; wahMix = o.wahMix
        case .pedal: pedalOn = o.pedalOn; pedalModel = o.pedalModel; pedalDrive = o.pedalDrive; pedalLevel = o.pedalLevel
        case .amp: ampOn = o.ampOn; ampDrive = o.ampDrive; model = o.model
        case .cab: cabOn = o.cabOn; cabIR = o.cabIR
        case .eq: eqOn = o.eqOn; bass = o.bass; mid = o.mid; treble = o.treble
        case .chorus: chorusOn = o.chorusOn; chorusRate = o.chorusRate; chorusDepth = o.chorusDepth; chorusMix = o.chorusMix
        case .flanger: flangerOn = o.flangerOn; flangerRate = o.flangerRate; flangerDepth = o.flangerDepth; flangerFb = o.flangerFb; flangerMix = o.flangerMix
        case .tremolo: tremoloOn = o.tremoloOn; tremoloRate = o.tremoloRate; tremoloDepth = o.tremoloDepth
        case .delay: delayOn = o.delayOn; delayTime = o.delayTime; delayFb = o.delayFb; delayMix = o.delayMix; delayTone = o.delayTone; delaySync = o.delaySync; delayDiv = o.delayDiv
        case .reverb: reverbOn = o.reverbOn; reverbDecay = o.reverbDecay; reverbDamp = o.reverbDamp; reverbMix = o.reverbMix; reverbType = o.reverbType
        case .irReverb: irReverbOn = o.irReverbOn; irReverbMix = o.irReverbMix; irReverbPredelay = o.irReverbPredelay; irReverbIR = o.irReverbIR
        }
    }
}

// Tolerant decoder: every field falls back to its default when a key is absent.
extension BlockParams {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func g<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decode(T.self, forKey: k)) ?? def }
        model = g(.model, model)
        ampOn = g(.ampOn, ampOn); ampDrive = g(.ampDrive, ampDrive)
        gateOn = g(.gateOn, gateOn); gateThr = g(.gateThr, gateThr); gateRel = g(.gateRel, gateRel); gateRange = g(.gateRange, gateRange)
        compOn = g(.compOn, compOn); compThr = g(.compThr, compThr); compRatio = g(.compRatio, compRatio); compAtk = g(.compAtk, compAtk); compRel = g(.compRel, compRel); compMakeup = g(.compMakeup, compMakeup)
        driveOn = g(.driveOn, driveOn); driveAmt = g(.driveAmt, driveAmt); driveTone = g(.driveTone, driveTone); driveLevel = g(.driveLevel, driveLevel); driveMode = g(.driveMode, driveMode)
        eqOn = g(.eqOn, eqOn); bass = g(.bass, bass); mid = g(.mid, mid); treble = g(.treble, treble)
        delayOn = g(.delayOn, delayOn); delayTime = g(.delayTime, delayTime); delayFb = g(.delayFb, delayFb); delayMix = g(.delayMix, delayMix); delayTone = g(.delayTone, delayTone)
        delaySync = g(.delaySync, delaySync); delayDiv = g(.delayDiv, delayDiv)
        reverbOn = g(.reverbOn, reverbOn); reverbDecay = g(.reverbDecay, reverbDecay); reverbDamp = g(.reverbDamp, reverbDamp); reverbMix = g(.reverbMix, reverbMix); reverbType = g(.reverbType, reverbType)
        boostOn = g(.boostOn, boostOn); boostDb = g(.boostDb, boostDb)
        stompOn = g(.stompOn, stompOn); stompModel = g(.stompModel, stompModel); stompDrive = g(.stompDrive, stompDrive); stompTone = g(.stompTone, stompTone); stompLevel = g(.stompLevel, stompLevel)
        chorusOn = g(.chorusOn, chorusOn); chorusRate = g(.chorusRate, chorusRate); chorusDepth = g(.chorusDepth, chorusDepth); chorusMix = g(.chorusMix, chorusMix)
        flangerOn = g(.flangerOn, flangerOn); flangerRate = g(.flangerRate, flangerRate); flangerDepth = g(.flangerDepth, flangerDepth); flangerFb = g(.flangerFb, flangerFb); flangerMix = g(.flangerMix, flangerMix)
        tremoloOn = g(.tremoloOn, tremoloOn); tremoloRate = g(.tremoloRate, tremoloRate); tremoloDepth = g(.tremoloDepth, tremoloDepth)
        pedalOn = g(.pedalOn, pedalOn); pedalModel = g(.pedalModel, pedalModel); pedalDrive = g(.pedalDrive, pedalDrive); pedalLevel = g(.pedalLevel, pedalLevel)
        cabOn = g(.cabOn, cabOn); cabIR = g(.cabIR, cabIR)
        irReverbOn = g(.irReverbOn, irReverbOn); irReverbMix = g(.irReverbMix, irReverbMix); irReverbPredelay = g(.irReverbPredelay, irReverbPredelay); irReverbIR = g(.irReverbIR, irReverbIR)
        wahOn = g(.wahOn, wahOn); wahPos = g(.wahPos, wahPos); wahAuto = g(.wahAuto, wahAuto); wahSense = g(.wahSense, wahSense); wahMix = g(.wahMix, wahMix)
    }
}

/// One block in a chain: identity + kind + its own params.
struct BlockInstance: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: BlockKind
    var p = BlockParams()
    var isOn: Bool { p.isOn(kind) }
}

/// A path = an ordered list of block instances.
struct PathState: Codable, Equatable {
    var blocks: [BlockInstance] = PathState.defaultBlocks
    var kinds: [BlockKind] { blocks.map(\.kind) }
    static var defaultBlocks: [BlockInstance] { [BlockInstance(kind: .gate), BlockInstance(kind: .amp)] }
    static func make(_ kinds: [BlockKind], _ tweak: (inout BlockParams) -> Void = { _ in }) -> PathState {
        var s = PathState(blocks: kinds.map { BlockInstance(kind: $0) })
        for i in s.blocks.indices { tweak(&s.blocks[i].p) }
        return s
    }
    func index(of id: UUID) -> Int? { blocks.firstIndex { $0.id == id } }
    func instance(_ id: UUID) -> BlockInstance? { blocks.first { $0.id == id } }
    func first(of kind: BlockKind) -> BlockInstance? { blocks.first { $0.kind == kind } }

    private enum CodingKeys: String, CodingKey { case blocks }
    private enum LegacyKeys: String, CodingKey { case order }
    init() {}
    init(blocks: [BlockInstance]) { self.blocks = blocks }
    /// New shape (`blocks`) or LEGACY flat path (`order` + flat block keys): every legacy block gets
    /// the same flat params (only its own kind's fields matter). Cab is inserted after Amp if missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let b = try? c.decode([BlockInstance].self, forKey: .blocks) { blocks = b; return }
        let flat = (try? BlockParams(from: decoder)) ?? BlockParams()
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        var kinds = ((try? legacy?.decode([String].self, forKey: .order)) ?? []).compactMap { BlockKind(rawValue: $0) }
        if kinds.isEmpty { kinds = [.gate, .amp] }
        if !kinds.contains(.cab), let ai = kinds.firstIndex(of: .amp) { kinds.insert(.cab, at: ai + 1) }
        blocks = kinds.map { BlockInstance(kind: $0, p: flat) }
    }
}

/// Per-instance runtime bookkeeping (what is actually loaded into the DSP object, status text).
struct InstanceMeta {
    var loadedModelID = ""
    var status = "— empty —"
    var irFile = ""
    var irName = "None"
}

/// A path's live block objects + chain + state. `focused[kind]` = the instance the engine's flat
/// params mirror; the typed accessors (`gate`, `delay`, …) return that instance's DSP object, or a
/// never-rendered template when the path has no instance of that kind (so param writes are always safe).
@MainActor @Observable final class RigPath {
    let id: RigPathID
    let chain: SignalChain
    var state = PathState()
    var focused: [BlockKind: UUID] = [:]
    @ObservationIgnored private var objects: [UUID: AudioBlock] = [:]
    @ObservationIgnored private var templates: [BlockKind: AudioBlock] = [:]
    @ObservationIgnored private(set) var meta: [UUID: InstanceMeta] = [:]
    @ObservationIgnored private var sampleRate: Double = 48000
    @ObservationIgnored private var maxBlock = 4096
    static let maxPerKind = 4

    init(id: RigPathID, chain: SignalChain) {
        self.id = id; self.chain = chain
        for k in BlockKind.allCases { templates[k] = Self.makeBlock(k) }
    }

    static func makeBlock(_ k: BlockKind) -> AudioBlock {
        switch k {
        case .gate: return GateBlock(); case .comp: return CompressorBlock(); case .boost: return BoostBlock(); case .drive: return DriveBlock()
        case .stomp: return CircuitDriveBlock(kind: .stomp); case .wah: return WahBlock(); case .pedal: return AmpBlock(kind: .pedal)
        case .amp: return AmpBlock(); case .cab: return CabBlock(kind: .cab); case .eq: return EQBlock(); case .chorus: return ChorusBlock()
        case .flanger: return FlangerBlock(); case .tremolo: return TremoloBlock(); case .delay: return DelayBlock(); case .reverb: return ReverbBlock()
        case .irReverb: return ReverbIRBlock()
        }
    }

    // MARK: instances ↔ DSP objects

    /// Create objects for new instances, drop objects of removed ones, fix the focus map, publish the chain.
    func sync() {
        var live: [UUID: AudioBlock] = [:]
        for inst in state.blocks {
            if let o = objects[inst.id] { live[inst.id] = o }
            else {
                let o = Self.makeBlock(inst.kind); o.prepare(sampleRate: sampleRate, maxBlock: maxBlock); o.reset()
                live[inst.id] = o; meta[inst.id] = InstanceMeta()
            }
        }
        for gone in objects.keys where live[gone] == nil { meta[gone] = nil }
        objects = live
        for k in BlockKind.allCases {
            if let f = focused[k], state.instance(f)?.kind == k { continue }
            focused[k] = state.first(of: k)?.id
        }
        chain.set(state.blocks.compactMap { objects[$0.id] })
    }
    func prepare(sampleRate: Double, maxBlock: Int) {
        self.sampleRate = sampleRate; self.maxBlock = maxBlock
        for o in objects.values { o.prepare(sampleRate: sampleRate, maxBlock: maxBlock) }
        for o in templates.values { o.prepare(sampleRate: sampleRate, maxBlock: maxBlock) }
    }
    func reset() { for o in objects.values { o.reset() } }

    func object(_ id: UUID) -> AudioBlock? { objects[id] }
    func focusedID(_ k: BlockKind) -> UUID? { focused[k] }
    func focusedInstance(_ k: BlockKind) -> BlockInstance? { focused[k].flatMap { state.instance($0) } }
    private func block<T: AudioBlock>(_ k: BlockKind) -> T { (focused[k].flatMap { objects[$0] } as? T) ?? (templates[k] as! T) }

    var gate: GateBlock { block(.gate) }
    var comp: CompressorBlock { block(.comp) }
    var boost: BoostBlock { block(.boost) }
    var drive: DriveBlock { block(.drive) }
    var circuitDrive: CircuitDriveBlock { block(.stomp) }
    var wah: WahBlock { block(.wah) }
    var pedal: AmpBlock { block(.pedal) }
    var amp: AmpBlock { block(.amp) }
    var cab: CabBlock { block(.cab) }
    var eq: EQBlock { block(.eq) }
    var chorus: ChorusBlock { block(.chorus) }
    var flanger: FlangerBlock { block(.flanger) }
    var tremolo: TremoloBlock { block(.tremolo) }
    var delay: DelayBlock { block(.delay) }
    var reverb: ReverbBlock { block(.reverb) }
    var irReverb: ReverbIRBlock { block(.irReverb) }

    // MARK: per-instance meta, addressed through the focused instance of each kind

    private func metaGet<T>(_ k: BlockKind, _ kp: KeyPath<InstanceMeta, T>, _ def: T) -> T { focused[k].flatMap { meta[$0] }?[keyPath: kp] ?? def }
    private func metaSet<T>(_ k: BlockKind, _ kp: WritableKeyPath<InstanceMeta, T>, _ v: T) { guard let id = focused[k] else { return }; meta[id, default: InstanceMeta()][keyPath: kp] = v }

    var loadedModelID: String { get { metaGet(.amp, \.loadedModelID, "") } set { metaSet(.amp, \.loadedModelID, newValue) } }
    var loadedPedalID: String { get { metaGet(.pedal, \.loadedModelID, "") } set { metaSet(.pedal, \.loadedModelID, newValue) } }
    var modelStatus: String { get { metaGet(.amp, \.status, "— empty —") } set { metaSet(.amp, \.status, newValue) } }
    var pedalStatus: String { get { metaGet(.pedal, \.status, "— empty —") } set { metaSet(.pedal, \.status, newValue) } }
    var cabIRFile: String { get { metaGet(.cab, \.irFile, "") } set { metaSet(.cab, \.irFile, newValue) } }
    var cabIRName: String { get { metaGet(.cab, \.irName, "None") } set { metaSet(.cab, \.irName, newValue) } }
    var irReverbFile: String { get { metaGet(.irReverb, \.irFile, "") } set { metaSet(.irReverb, \.irFile, newValue) } }
    var irReverbName: String { get { metaGet(.irReverb, \.irName, "None") } set { metaSet(.irReverb, \.irName, newValue) } }
    /// Status of ANY instance (tiles / editors of non-focused instances).
    func status(of id: UUID) -> String { meta[id]?.status ?? "— empty —" }
}
