//
//  MIDIManager.swift
//  NamRig — MIDI input via CoreMIDI. Program Change → preset; Control Change → mapped param /
//  block bypass / preset nav; MIDI-learn; channel filter. Mappings are GLOBAL (Documents/midi.json),
//  not per-preset. The CoreMIDI receive block runs off-main and only hops to @MainActor.
//

import Foundation
import CoreMIDI
import Observation

// MARK: - Mapping model

enum MIDIParam: String, Codable, CaseIterable, Identifiable {
    case ampDrive, output, gateThr, bass, mid, treble
    case driveAmt, driveLevel, delayMix, delayFb, reverbMix, reverbDecay
    case compMakeup, boostDb, pedalDrive, pedalLevel, chorusMix, flangerMix, tremoloDepth
    var id: String { rawValue }
    var range: ClosedRange<Double> {
        switch self {
        case .ampDrive: return 0...24;        case .output: return -40...12;   case .gateThr: return -70...(-10)
        case .bass, .mid, .treble: return -12...12
        case .driveAmt: return 1...50;        case .driveLevel: return -24...6
        case .delayMix, .reverbMix, .reverbDecay, .chorusMix, .flangerMix, .tremoloDepth: return 0...100
        case .delayFb: return 0...90
        case .compMakeup: return 0...24;      case .boostDb: return 0...18
        case .pedalDrive: return 0...24;      case .pedalLevel: return -24...12
        }
    }
    var label: String {
        switch self {
        case .ampDrive: return "Amp Drive"; case .output: return "Output"; case .gateThr: return "Gate Thresh"
        case .bass: return "Bass"; case .mid: return "Mid"; case .treble: return "Treble"
        case .driveAmt: return "Drive"; case .driveLevel: return "Drive Level"
        case .delayMix: return "Delay Mix"; case .delayFb: return "Delay Fbk"
        case .reverbMix: return "Reverb Mix"; case .reverbDecay: return "Reverb Decay"
        case .compMakeup: return "Comp Makeup"; case .boostDb: return "Boost"
        case .pedalDrive: return "Pedal Drive"; case .pedalLevel: return "Pedal Level"
        case .chorusMix: return "Chorus Mix"; case .flangerMix: return "Flanger Mix"; case .tremoloDepth: return "Tremolo Depth"
        }
    }
}

enum MIDITarget: Codable, Hashable {
    case presetNext, presetPrev
    case param(MIDIParam)
    case blockToggle(String)   // BlockKind.rawValue
    var label: String {
        switch self {
        case .presetNext: return "Next preset"
        case .presetPrev: return "Previous preset"
        case .param(let p): return p.label
        case .blockToggle(let k): return "\(k) on/off"
        }
    }
}

struct MIDIMapping: Codable, Identifiable, Hashable {
    var id = UUID()
    var cc: Int
    var channel: Int?   // nil = omni
    var target: MIDITarget
}

enum MIDIStore {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("midi.json")
    struct Saved: Codable { var mappings: [MIDIMapping] = []; var channelFilter: Int? = nil }
    static func load() -> Saved { (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))) ?? Saved() }
    static func save(_ s: Saved) { if let d = try? JSONEncoder().encode(s) { try? d.write(to: url) } }
}

// MARK: - Manager

@MainActor @Observable final class MIDIManager {
    private(set) var sources: [String] = []
    var mappings: [MIDIMapping] = [] { didSet { persist() } }
    var channelFilter: Int? = nil { didSet { persist() } }    // nil = omni, else 1...16
    var learnMappingID: UUID? = nil
    private(set) var lastActivity = 0

    private weak var engine: AudioEngine?
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()

    init() {
        let s = MIDIStore.load()
        mappings = s.mappings
        channelFilter = s.channelFilter
    }

    func start(engine: AudioEngine) {
        self.engine = engine
        guard client == 0 else { return }
        let notify: MIDINotifyBlock = { [weak self] msg in
            if msg.pointee.messageID == .msgSetupChanged { Task { @MainActor in self?.connectAllSources() } }
        }
        MIDIClientCreateWithBlock("NamRig" as CFString, &client, notify)
        let recv: MIDIReceiveBlock = { [weak self] listPtr, _ in
            guard let self else { return }
            var packet = listPtr.pointee.packet
            for _ in 0..<listPtr.pointee.numPackets {
                let count = Int(packet.wordCount)
                var words = packet.words
                withUnsafeBytes(of: &words) { raw in
                    let wp = raw.bindMemory(to: UInt32.self)
                    for i in 0..<count {
                        let w = wp[i]
                        guard (w >> 28) & 0xF == 0x2 else { continue }   // MIDI-1.0 channel-voice UMP
                        let status = UInt8((w >> 16) & 0xFF)
                        let hi = Int(status & 0xF0), ch = Int(status & 0x0F)
                        let d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
                        if hi == 0xB0 || hi == 0xC0 {
                            Task { @MainActor in self.handleIncoming(hi: hi, channel: ch, d1: d1, d2: d2) }
                        }
                    }
                }
                packet = MIDIEventPacketNext(&packet).pointee
            }
        }
        MIDIInputPortCreateWithProtocol(client, "NamRig In" as CFString, ._1_0, &port, recv)
        connectAllSources()
    }

    func connectAllSources() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(port, src, nil)
            names.append(displayName(of: src))
        }
        sources = names
    }

    private func displayName(of obj: MIDIObjectRef) -> String {
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &cf)
        return (cf?.takeRetainedValue() as String?) ?? "MIDI Source"
    }

    private func handleIncoming(hi: Int, channel: Int, d1: Int, d2: Int) {
        lastActivity &+= 1
        if let lid = learnMappingID {                  // MIDI-learn: bind the next CC to this mapping
            if hi == 0xB0, let i = mappings.firstIndex(where: { $0.id == lid }) {
                mappings[i].cc = d1
                mappings[i].channel = channelFilter
                learnMappingID = nil
            }
            return
        }
        guard let engine else { return }
        if let f = channelFilter, f - 1 != channel { return }
        if hi == 0xC0 { engine.handleProgramChange(d1); return }   // Program Change → preset
        for m in mappings where m.cc == d1 {                       // Control Change → mapped target
            if let mc = m.channel, mc - 1 != channel { continue }
            switch m.target {
            case .presetNext: if d2 >= 64 { engine.nextPreset() }
            case .presetPrev: if d2 >= 64 { engine.prevPreset() }
            case .param(let p): engine.setParam(p, normalized: Double(d2) / 127)
            case .blockToggle(let k): if let kind = BlockKind(rawValue: k) { engine.setBlockEnabled(kind, d2 >= 64) }
            }
        }
    }

    func addMapping(_ target: MIDITarget) {
        let used = Set(mappings.map { $0.cc })
        let cc = (1...127).first { !used.contains($0) } ?? 1
        mappings.append(MIDIMapping(cc: cc, channel: channelFilter, target: target))
    }
    func beginLearn(_ id: UUID) { learnMappingID = id }
    func cancelLearn() { learnMappingID = nil }
    func removeMapping(_ id: UUID) { mappings.removeAll { $0.id == id } }
    private func persist() { MIDIStore.save(.init(mappings: mappings, channelFilter: channelFilter)) }
}
