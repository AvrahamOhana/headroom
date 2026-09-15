//
//  MIDIManager.swift
//  NamRig — CoreMIDI in + out.
//
//  IN:  Program Change (+ Bank Select CC0/32) → preset; CC / Note → mapped param, block toggle,
//       preset nav, looper, tuner, tap; MIDI-learn; channel filter; MIDI clock → tempo.
//  OUT: "NamRig Out" virtual source + every hardware destination. Program Change on preset load,
//       the preset's own send list (PC/CC to external gear), CC feedback when a mapped param moves
//       from the UI, optional MIDI clock from the tap tempo.
//  Mappings are GLOBAL (Documents/midi.json). The CoreMIDI receive block runs off-main and hops to
//  @MainActor per message; clock ticks are counted off-main and only the derived BPM hops over.
//

import Foundation
import CoreMIDI
import Observation

// MARK: - Mapping model

enum MIDIParam: String, Codable, CaseIterable, Identifiable {
    case ampDrive, output, gateThr, bass, mid, treble
    case driveAmt, driveLevel, delayMix, delayFb, reverbMix, reverbDecay
    case compMakeup, boostDb, pedalDrive, pedalLevel, chorusMix, flangerMix, tremoloDepth
    case wah, delayTone, compThr, stompDrive, loopLevel
    case ampALevel, ampBLevel
    var id: String { rawValue }
    var range: ClosedRange<Double> {
        switch self {
        case .ampDrive: return 0...24;        case .output: return -40...12;   case .gateThr: return -70...(-10)
        case .bass, .mid, .treble: return -12...12
        case .driveAmt: return 1...50;        case .driveLevel: return -24...6
        case .delayMix, .reverbMix, .reverbDecay, .chorusMix, .flangerMix, .tremoloDepth, .delayTone, .loopLevel: return 0...100
        case .delayFb: return 0...90
        case .compMakeup: return 0...24;      case .boostDb: return 0...18
        case .pedalDrive: return 0...24;      case .pedalLevel: return -24...12
        case .wah, .stompDrive: return 0...1; case .compThr: return -48...0
        case .ampALevel, .ampBLevel: return -24...12
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
        case .wah: return "Wah (expression)"; case .delayTone: return "Delay Tone"; case .compThr: return "Comp Thresh"
        case .stompDrive: return "Stomp Drive"; case .loopLevel: return "Loop Level"
        case .ampALevel: return "Path A Level"; case .ampBLevel: return "Path B Level"
        }
    }
}

enum MIDITarget: Codable, Hashable {
    case presetNext, presetPrev
    case param(MIDIParam)
    case blockToggle(String)   // BlockKind.rawValue
    case looper, looperStop, tapTempo, mute, tuner
    var label: String {
        switch self {
        case .presetNext: return "Next preset"
        case .presetPrev: return "Previous preset"
        case .param(let p): return p.label
        case .blockToggle(let k): return "\(k) on/off"
        case .looper: return "Looper REC/Play/Dub"
        case .looperStop: return "Looper stop"
        case .tapTempo: return "Tap tempo"
        case .mute: return "Mute"
        case .tuner: return "Tuner"
        }
    }
    /// Switch-type targets act on a press edge (momentary footswitches send 127 then 0).
    var isSwitch: Bool { if case .param = self { return false }; return true }
}

/// What kind of controller message drives a mapping.
enum MIDISource: String, Codable, CaseIterable { case cc, note }

struct MIDIMapping: Codable, Identifiable, Hashable {
    var id = UUID()
    var cc: Int                    // CC number, or note number when `source == .note`
    var channel: Int?              // nil = omni
    var target: MIDITarget
    var source: MIDISource = .cc
    /// Switch mappings: true = each press (value ≥ 64 edge) TOGGLES / fires (momentary footswitch);
    /// false = follow the value (latching switch: ≥64 on, <64 off). Ignored for params.
    var momentary = true

    private enum CodingKeys: String, CodingKey { case id, cc, channel, target, source, momentary }
    init(cc: Int, channel: Int?, target: MIDITarget, source: MIDISource = .cc, momentary: Bool = true) {
        self.cc = cc; self.channel = channel; self.target = target; self.source = source; self.momentary = momentary
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        cc = try c.decode(Int.self, forKey: .cc)
        channel = try? c.decode(Int.self, forKey: .channel)
        target = try c.decode(MIDITarget.self, forKey: .target)
        source = (try? c.decode(MIDISource.self, forKey: .source)) ?? .cc
        momentary = (try? c.decode(Bool.self, forKey: .momentary)) ?? true
    }
}

/// One outgoing message in a preset's send list (or a manual send).
struct MIDIOutMessage: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable { case programChange, controlChange }
    var id = UUID()
    var kind: Kind = .programChange
    var channel = 1          // 1…16
    var number = 0           // program (0…127) or CC number
    var value = 0            // CC value (ignored for PC)
    var label: String {
        switch kind {
        case .programChange: return "PC \(number) · ch \(channel)"
        case .controlChange: return "CC \(number) = \(value) · ch \(channel)"
        }
    }
}

enum MIDIStore {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("midi.json")
    struct Saved: Codable {
        var mappings: [MIDIMapping] = []
        var channelFilter: Int? = nil
        var outChannel = 1
        var sendPCOnPresetLoad = true
        var sendCCFeedback = true
        var sendClock = false
        var clockInSync = true
        var bankSelect = false
        init() {}
        private enum CodingKeys: String, CodingKey { case mappings, channelFilter, outChannel, sendPCOnPresetLoad, sendCCFeedback, sendClock, clockInSync, bankSelect }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            mappings = (try? c.decode([MIDIMapping].self, forKey: .mappings)) ?? []
            channelFilter = try? c.decode(Int.self, forKey: .channelFilter)
            outChannel = (try? c.decode(Int.self, forKey: .outChannel)) ?? 1
            sendPCOnPresetLoad = (try? c.decode(Bool.self, forKey: .sendPCOnPresetLoad)) ?? true
            sendCCFeedback = (try? c.decode(Bool.self, forKey: .sendCCFeedback)) ?? true
            sendClock = (try? c.decode(Bool.self, forKey: .sendClock)) ?? false
            clockInSync = (try? c.decode(Bool.self, forKey: .clockInSync)) ?? true
            bankSelect = (try? c.decode(Bool.self, forKey: .bankSelect)) ?? false
        }
    }
    static func load() -> Saved { (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))) ?? Saved() }
    static func save(_ s: Saved) { if let d = try? JSONEncoder().encode(s) { try? d.write(to: url) } }
}

// MARK: - Off-main clock counter (24 ppq → BPM)

/// Counts MIDI clock ticks on the CoreMIDI thread; publishes a smoothed BPM every quarter note.
nonisolated final class ClockCounter: @unchecked Sendable {
    private var lastBeat: UInt64 = 0
    private var ticks = 0
    private var bpmAvg: Double = 0
    /// Returns a BPM when a full quarter note (24 ticks) has elapsed, else nil.
    func tick(_ hostTime: UInt64) -> Double? {
        ticks += 1
        guard ticks >= 24 else { return nil }
        ticks = 0
        defer { lastBeat = hostTime }
        guard lastBeat != 0 else { return nil }
        let ns = Double(hostTime - lastBeat)
        guard ns > 0 else { return nil }
        let bpm = 60e9 / ns
        guard bpm > 20, bpm < 300 else { return nil }
        bpmAvg = bpmAvg == 0 ? bpm : bpmAvg * 0.7 + bpm * 0.3
        return bpmAvg
    }
    func reset() { lastBeat = 0; ticks = 0; bpmAvg = 0 }
}

// MARK: - Manager

@MainActor @Observable final class MIDIManager {
    private(set) var sources: [String] = []
    private(set) var destinations: [String] = []
    var mappings: [MIDIMapping] = [] { didSet { persist() } }
    var channelFilter: Int? = nil { didSet { persist() } }    // nil = omni, else 1...16
    var outChannel = 1 { didSet { persist() } }
    var sendPCOnPresetLoad = true { didSet { persist() } }
    var sendCCFeedback = true { didSet { persist() } }
    var sendClock = false { didSet { persist(); updateClockTimer() } }
    var clockInSync = true { didSet { persist() } }
    var bankSelect = false { didSet { persist() } }
    var learnMappingID: UUID? = nil
    private(set) var lastActivity = 0
    private(set) var lastMessage = "—"
    private(set) var lastSent = "—"
    private(set) var externalClockBpm: Double? = nil

    private weak var engine: AudioEngine?
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var virtualOut = MIDIEndpointRef()
    private let clock = ClockCounter()
    private var pendingBank = 0
    private var clockTimer: Timer?
    private var clockPhase = 0
    private var suppressFeedback = false

    init() {
        let s = MIDIStore.load()
        mappings = s.mappings; channelFilter = s.channelFilter; outChannel = s.outChannel
        sendPCOnPresetLoad = s.sendPCOnPresetLoad; sendCCFeedback = s.sendCCFeedback
        sendClock = s.sendClock; clockInSync = s.clockInSync; bankSelect = s.bankSelect
    }

    func start(engine: AudioEngine) {
        self.engine = engine
        engine.presetDidLoad = { [weak self] i, p in self?.presetLoaded(i, p) }
        engine.paramDidChange = { [weak self] p, norm in self?.paramMoved(p, norm) }
        guard client == 0 else { return }
        let notify: MIDINotifyBlock = { [weak self] msg in
            if msg.pointee.messageID == .msgSetupChanged { Task { @MainActor in self?.connectAllSources() } }
        }
        MIDIClientCreateWithBlock("NamRig" as CFString, &client, notify)
        let clock = self.clock
        let recv: MIDIReceiveBlock = { [weak self] listPtr, _ in
            guard let self else { return }
            var packet = listPtr.pointee.packet
            for _ in 0..<listPtr.pointee.numPackets {
                let count = Int(packet.wordCount)
                let ts = packet.timeStamp
                var words = packet.words
                withUnsafeBytes(of: &words) { raw in
                    let wp = raw.bindMemory(to: UInt32.self)
                    for i in 0..<count {
                        let w = wp[i]
                        let mt = (w >> 28) & 0xF
                        if mt == 0x2 {                                          // MIDI-1.0 channel voice
                            let status = UInt8((w >> 16) & 0xFF)
                            let hi = Int(status & 0xF0), ch = Int(status & 0x0F)
                            let d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
                            if hi == 0xB0 || hi == 0xC0 || hi == 0x90 || hi == 0x80 {
                                Task { @MainActor in self.handleIncoming(hi: hi, channel: ch, d1: d1, d2: d2) }
                            }
                        } else if mt == 0x1 {                                   // system real-time
                            let status = UInt8((w >> 16) & 0xFF)
                            let host = ts == 0 ? mach_absolute_time() : ts
                            if status == 0xF8, let bpm = clock.tick(host) {
                                Task { @MainActor in self.clockBpm(bpm) }
                            } else if status == 0xFA || status == 0xFC { clock.reset() }
                        }
                    }
                }
                packet = MIDIEventPacketNext(&packet).pointee
            }
        }
        MIDIInputPortCreateWithProtocol(client, "NamRig In" as CFString, ._1_0, &inPort, recv)
        MIDIOutputPortCreate(client, "NamRig Out Port" as CFString, &outPort)
        MIDISourceCreateWithProtocol(client, "NamRig Out" as CFString, ._1_0, &virtualOut)
        connectAllSources()
        updateClockTimer()
    }

    func connectAllSources() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            if src == virtualOut { continue }              // never listen to our own output (feedback loop)
            MIDIPortConnectSource(inPort, src, nil)
            names.append(displayName(of: src))
        }
        sources = names
        var dests: [String] = []
        for i in 0..<MIDIGetNumberOfDestinations() { dests.append(displayName(of: MIDIGetDestination(i))) }
        destinations = dests
    }

    private func displayName(of obj: MIDIObjectRef) -> String {
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &cf)
        return (cf?.takeRetainedValue() as String?) ?? "MIDI Device"
    }

    // MARK: In

    private func clockBpm(_ bpm: Double) {
        externalClockBpm = bpm
        guard clockInSync, let engine else { return }
        if abs(engine.bpm - bpm) > 0.5 { engine.bpm = bpm }
    }

    private func handleIncoming(hi: Int, channel: Int, d1: Int, d2: Int) {
        lastActivity &+= 1
        let kind = hi == 0xC0 ? "PC" : hi == 0xB0 ? "CC" : "Note"
        lastMessage = hi == 0xC0 ? "PC \(d1) · ch \(channel + 1)" : "\(kind) \(d1) = \(d2) · ch \(channel + 1)"
        if let lid = learnMappingID {                  // MIDI-learn: bind the next CC / note to this mapping
            if (hi == 0xB0 || hi == 0x90), let i = mappings.firstIndex(where: { $0.id == lid }) {
                if hi == 0x90 && d2 == 0 { return }    // ignore note-off while learning
                mappings[i].cc = d1
                mappings[i].source = hi == 0x90 ? .note : .cc
                mappings[i].channel = channelFilter
                learnMappingID = nil
            }
            return
        }
        guard let engine else { return }
        if let f = channelFilter, f - 1 != channel { return }
        if hi == 0xB0 && bankSelect && (d1 == 0 || d1 == 32) {   // Bank Select MSB/LSB
            if d1 == 32 { pendingBank = d2 } else { pendingBank = d2 * 128 }
            return
        }
        if hi == 0xC0 {
            let idx = bankSelect ? pendingBank + d1 : d1
            suppressFeedback = true; engine.handleProgramChange(idx); suppressFeedback = false
            return
        }
        let isNote = hi == 0x90 || hi == 0x80
        let value = hi == 0x80 ? 0 : d2                          // note-off = value 0
        for m in mappings where m.cc == d1 && (m.source == .note) == isNote {
            if let mc = m.channel, mc - 1 != channel { continue }
            fire(m, value: value)
        }
    }

    private func fire(_ m: MIDIMapping, value: Int) {
        guard let engine else { return }
        if case .param(let p) = m.target {
            suppressFeedback = true; engine.setParam(p, normalized: Double(value) / 127); suppressFeedback = false
            return
        }
        let pressed = value >= 64
        if m.momentary && !pressed { return }               // momentary: act on the press edge only
        switch m.target {
        case .presetNext: engine.nextPreset()
        case .presetPrev: engine.prevPreset()
        case .blockToggle(let k):
            guard let kind = BlockKind(rawValue: k) else { return }
            engine.midiSetBlockEnabled(kind, m.momentary ? !engine.midiIsBlockEnabled(kind) : pressed)
        case .looper: engine.toggleLooper()
        case .looperStop: engine.stopLooper()
        case .tapTempo: engine.tapTempo()
        case .mute: if m.momentary { engine.toggleMute() } else { engine.muted = pressed }
        case .tuner: engine.tunerRequested = m.momentary ? !engine.tunerRequested : pressed
        case .param: break
        }
    }

    // MARK: Out

    private func presetLoaded(_ i: Int, _ p: Preset) {
        if sendPCOnPresetLoad {
            if bankSelect { sendCC(0, i / 128, channel: outChannel) }
            sendPC(i % 128, channel: outChannel)
        }
        for m in p.midiOut { send(m) }
    }

    private func paramMoved(_ p: MIDIParam, _ norm: Double) {
        guard sendCCFeedback, !suppressFeedback else { return }
        for m in mappings where m.source == .cc { if case .param(let mp) = m.target, mp == p {
            sendCC(m.cc, Int((norm * 127).rounded()), channel: m.channel ?? outChannel)
        } }
    }

    func send(_ m: MIDIOutMessage) {
        switch m.kind {
        case .programChange: sendPC(m.number, channel: m.channel)
        case .controlChange: sendCC(m.number, m.value, channel: m.channel)
        }
    }
    func sendPC(_ program: Int, channel: Int) {
        emit([0xC0 | UInt8((channel - 1) & 0xF), UInt8(program & 0x7F)])
        lastSent = "PC \(program) · ch \(channel)"
    }
    func sendCC(_ cc: Int, _ value: Int, channel: Int) {
        emit([0xB0 | UInt8((channel - 1) & 0xF), UInt8(cc & 0x7F), UInt8(max(0, min(127, value)) & 0x7F)])
        lastSent = "CC \(cc) = \(value) · ch \(channel)"
    }

    /// Send raw MIDI-1.0 bytes to the virtual source AND every hardware destination.
    private func emit(_ bytes: [UInt8]) {
        guard client != 0 else { return }
        var list = MIDIEventList()
        let words = bytes.count == 2
            ? UInt32(0x20 << 24) | UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8
            : bytes.count == 3
            ? UInt32(0x20 << 24) | UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
            : UInt32(0x10 << 24) | UInt32(bytes[0]) << 16
        var w = words
        let pkt = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, &w)
        MIDIReceivedEventList(virtualOut, &list)
        for i in 0..<MIDIGetNumberOfDestinations() {
            let d = MIDIGetDestination(i)
            if d != virtualOut { MIDISendEventList(outPort, d, &list) }
        }
    }

    // MIDI clock out — 24 ppq from the engine tempo. Timer-driven (good enough for pedal delays;
    // not sample-accurate).
    private func updateClockTimer() {
        clockTimer?.invalidate(); clockTimer = nil
        guard sendClock else { return }
        scheduleClockTick()
    }
    private func scheduleClockTick() {
        let bpm = engine?.bpm ?? 120
        let interval = 60.0 / max(20, bpm) / 24
        clockTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sendClock else { return }
                self.emit([0xF8])
                self.scheduleClockTick()
            }
        }
    }

    // MARK: Mapping edits

    func addMapping(_ target: MIDITarget) {
        let used = Set(mappings.filter { $0.source == .cc }.map { $0.cc })
        let cc = (1...127).first { !used.contains($0) } ?? 1
        mappings.append(MIDIMapping(cc: cc, channel: channelFilter, target: target))
    }
    func beginLearn(_ id: UUID) { learnMappingID = id }
    func cancelLearn() { learnMappingID = nil }
    func removeMapping(_ id: UUID) { mappings.removeAll { $0.id == id } }
    private func persist() {
        var s = MIDIStore.Saved()
        s.mappings = mappings; s.channelFilter = channelFilter; s.outChannel = outChannel
        s.sendPCOnPresetLoad = sendPCOnPresetLoad; s.sendCCFeedback = sendCCFeedback
        s.sendClock = sendClock; s.clockInSync = clockInSync; s.bankSelect = bankSelect
        MIDIStore.save(s)
    }
}
