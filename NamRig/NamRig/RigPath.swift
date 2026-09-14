//
//  RigPath.swift
//  NamRig — one complete signal path (A or B). Each path owns a full set of block INSTANCES and a
//  `PathState` snapshot of every block parameter + its order. The engine "focuses" one path at a
//  time: its flat @Observable params (the knobs / MIDI / bindings) always mirror the focused path,
//  and switching focus snapshots the old path and applies the new one. Both chains render live.
//

import Foundation
import Observation

enum RigPathID: String, Codable, CaseIterable, Identifiable, Sendable {
    case a, b
    var id: Self { self }
    var label: String { rawValue.uppercased() }
    var other: RigPathID { self == .a ? .b : .a }
}

/// Every per-path parameter. Field names match the legacy flat `Preset` keys on purpose: an old
/// preset file decodes straight into path A via the tolerant decoder below.
struct PathState: Codable, Equatable {
    var model = ""
    var ampOn = true,    ampDrive = 0.0
    var gateOn = true,   gateThr = -34.0, gateRel = 80.0, gateRange = -80.0
    var compOn = false,  compThr = -18.0, compRatio = 4.0, compAtk = 10.0, compRel = 120.0, compMakeup = 0.0
    var driveOn = false, driveAmt = 4.0,  driveTone = 4000.0, driveLevel = 0.0, driveMode = 0
    var eqOn = true,     bass = 0.0, mid = 0.0, treble = 0.0
    var delayOn = false, delayTime = 350.0, delayFb = 35.0, delayMix = 30.0, delayTone = 60.0
    var delaySync = false, delayDiv: TempoClock.NoteDivision = .eighth
    var reverbOn = false, reverbDecay = 70.0, reverbDamp = 30.0, reverbMix = 25.0, reverbType = 3
    var boostOn = false, boostDb = 6.0
    var stompOn = false, stompModel = 0, stompDrive = 0.5, stompTone = 0.5, stompLevel = 0.8
    var chorusOn = false, chorusRate = 0.8, chorusDepth = 6.0, chorusMix = 40.0
    var flangerOn = false, flangerRate = 0.4, flangerDepth = 2.0, flangerFb = 50.0, flangerMix = 50.0
    var tremoloOn = false, tremoloRate = 5.0, tremoloDepth = 50.0
    var order: [String] = ["Noise Gate", "Compressor", "Boost", "Drive", "Pedal", "Amp", "Cab", "EQ", "Chorus", "Flanger", "Tremolo", "Delay", "Reverb", "IR Reverb"]
    var pedalOn = false, pedalModel = "", pedalDrive = 0.0, pedalLevel = 0.0
    var cabOn = true, cabIR = ""
    var irReverbOn = false, irReverbMix = 35.0, irReverbPredelay = 0.0, irReverbIR = ""
    var wahOn = false, wahPos = 0.5, wahAuto = false, wahSense = 50.0, wahMix = 92.0

    var kinds: [BlockKind] { order.compactMap { BlockKind(rawValue: $0) } }

    func isOn(_ k: BlockKind) -> Bool {
        switch k {
        case .gate: return gateOn; case .comp: return compOn; case .boost: return boostOn; case .drive: return driveOn
        case .stomp: return stompOn; case .wah: return wahOn; case .pedal: return pedalOn; case .amp: return ampOn; case .cab: return cabOn
        case .eq: return eqOn; case .chorus: return chorusOn; case .flanger: return flangerOn; case .tremolo: return tremoloOn
        case .delay: return delayOn; case .reverb: return reverbOn; case .irReverb: return irReverbOn
        }
    }

    /// Copy one block's settings from another path (drag a block across paths → it keeps its sound).
    mutating func copy(_ k: BlockKind, from o: PathState) {
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

// Tolerant decoder: every field falls back to its default when a key is absent, so schema changes
// never invalidate saved presets. Also what lets a LEGACY flat preset decode as path A.
extension PathState {
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
        order = g(.order, order)
        pedalOn = g(.pedalOn, pedalOn); pedalModel = g(.pedalModel, pedalModel); pedalDrive = g(.pedalDrive, pedalDrive); pedalLevel = g(.pedalLevel, pedalLevel)
        cabOn = g(.cabOn, cabOn); cabIR = g(.cabIR, cabIR)
        irReverbOn = g(.irReverbOn, irReverbOn); irReverbMix = g(.irReverbMix, irReverbMix); irReverbPredelay = g(.irReverbPredelay, irReverbPredelay); irReverbIR = g(.irReverbIR, irReverbIR)
        wahOn = g(.wahOn, wahOn); wahPos = g(.wahPos, wahPos); wahAuto = g(.wahAuto, wahAuto); wahSense = g(.wahSense, wahSense); wahMix = g(.wahMix, wahMix)
    }
}

/// A path's block instances + its chain + the last snapshot of its params (authoritative whenever
/// the path is NOT the focused one). Status strings live here too so the UI can show either path.
@MainActor @Observable final class RigPath {
    let id: RigPathID
    let chain: SignalChain
    let gate = GateBlock(), comp = CompressorBlock(), boost = BoostBlock(), drive = DriveBlock()
    let circuitDrive = CircuitDriveBlock(kind: .stomp), wah = WahBlock(), pedal = AmpBlock(kind: .pedal)
    let amp = AmpBlock(), cab = CabBlock(kind: .cab), eq = EQBlock(), chorus = ChorusBlock(), flanger = FlangerBlock()
    let tremolo = TremoloBlock(), delay = DelayBlock(), reverb = ReverbBlock(), irReverb = ReverbIRBlock()
    private(set) var indexByKind: [BlockKind: Int] = [:]

    var state = PathState()
    var modelStatus = "— empty —"
    var pedalStatus = "— empty —"
    var cabIRName = "None"
    var cabIRFile = ""
    var irReverbName = "None"
    var irReverbFile = ""
    /// What is actually loaded into the blocks (so a focus switch never reloads a model it already has).
    var loadedModelID = ""
    var loadedPedalID = ""

    init(id: RigPathID, chain: SignalChain) {
        self.id = id; self.chain = chain
        let blocks: [AudioBlock] = [gate, comp, boost, drive, circuitDrive, wah, pedal, amp, cab, eq, chorus, flanger, tremolo, delay, reverb, irReverb]
        chain.install(blocks)
        for (i, b) in blocks.enumerated() { indexByKind[b.kind] = i }
    }
}
