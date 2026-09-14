//
//  preset_test.swift — preset schema round-trip + LEGACY (flat, single-path) preset migration.
//  Run:  swiftc -parse-as-library -default-isolation MainActor tools/preset_test.swift \
//          NamRig/NamRig/Preset.swift NamRig/NamRig/RigPath.swift NamRig/NamRig/Blocks.swift \
//          NamRig/NamRig/Wah.swift NamRig/NamRig/ReverbAlgorithms.swift NamRig/NamRig/CircuitDrive.swift \
//          NamRig/NamRig/Tempo.swift NamRig/NamRig/MIDIManager.swift -o /tmp/preset_test && /tmp/preset_test
//
import Foundation

nonisolated final class NAMModel: @unchecked Sendable {
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int32) {}
}
/// Stub — MIDIManager references the engine only through these.
@MainActor @Observable final class AudioEngine {
    var presetDidLoad: ((Int, Preset) -> Void)?
    var paramDidChange: ((MIDIParam, Double) -> Void)?
    var bpm = 120.0; var muted = false; var tunerRequested = false
    func handleProgramChange(_ pc: Int) {}
    func setParam(_ p: MIDIParam, normalized: Double) {}
    func midiSetBlockEnabled(_ kind: BlockKind, _ on: Bool) {}
    func midiIsBlockEnabled(_ kind: BlockKind) -> Bool { false }
    func nextPreset() {}; func prevPreset() {}; func toggleLooper() {}; func stopLooper() {}; func tapTempo() {}; func toggleMute() {}
}
nonisolated(unsafe) var fails = 0
nonisolated func check(_ ok: Bool, _ msg: String) { print((ok ? "  ✓ " : "  ✗ ") + msg); if !ok { fails += 1 } }

@main struct Main {
    static func main() throws {
        print("Legacy flat preset → path A instances")
        let legacy = """
        [{"id":"7E6C7B8A-1111-2222-3333-444444444444","name":"Old Lead","model":"Bugera V5","ampOn":true,"ampDrive":6,
          "gateOn":true,"gateThr":-40,"driveOn":true,"driveAmt":22,"delayOn":true,"delayMix":22,"delayTime":420,
          "order":["Noise Gate","Drive","Amp","Delay"],"output":-9,"stereoOn":true,"stereoWidth":80,
          "ampALevel":-3,"ampBPan":0.5,"reverbType":1,"wahOn":true,"wahPos":0.3}]
        """.data(using: .utf8)!
        let ps = try JSONDecoder().decode([Preset].self, from: legacy)
        let p = ps[0]
        check(p.name == "Old Lead", "name")
        check(p.a.kinds == [.gate, .drive, .amp, .cab, .delay], "order → instances, Cab inserted after Amp: \(p.a.kinds)")
        check(p.a.first(of: .amp)?.p.model == "Bugera V5" && p.a.first(of: .amp)?.p.ampDrive == 6, "amp instance params")
        check(p.a.first(of: .drive)?.p.driveAmt == 22 && p.a.first(of: .delay)?.p.delayMix == 22, "drive / delay instance params")
        check(p.output == -9 && p.stereoOn && p.stereoWidth == 80, "globals kept")
        check(p.levelA == -3 && p.panB == 0.5, "legacy mixer keys mapped")
        check(p.b.kinds == [.gate, .amp] && p.dualOn == false, "path B default (Gate → Amp), dual off")

        print("Round trip (new schema, duplicates)")
        var q = Preset(name: "Dual")
        q.dualOn = true
        q.a = PathState.make([.gate, .delay, .amp, .delay])
        q.a.blocks[1].p.delayMix = 10; q.a.blocks[3].p.delayMix = 90
        q.b = PathState.make([.amp, .cab, .reverb]) { $0.model = "Other" }
        q.levelB = -6; q.panA = -1
        q.midiOut = [MIDIOutMessage(kind: .controlChange, channel: 3, number: 20, value: 127)]
        let data = try JSONEncoder().encode([q])
        let back = try JSONDecoder().decode([Preset].self, from: data)[0]
        check(back.a.kinds == [.gate, .delay, .amp, .delay], "two delays survive")
        check(back.a.blocks[1].p.delayMix == 10 && back.a.blocks[3].p.delayMix == 90, "each delay keeps its own params")
        check(back.a.blocks[1].id == q.a.blocks[1].id, "instance ids stable")
        check(back.b.first(of: .amp)?.p.model == "Other" && back.b.kinds == [.amp, .cab, .reverb], "path B round-trips")
        check(back.levelB == -6 && back.panA == -1 && back.midiOut.first?.number == 20, "mixer + midiOut round-trip")

        print("Defaults")
        check(PathState().kinds == [.gate, .amp], "default chain is Gate → Amp")
        check(PresetStore.defaults.count == 4 && PresetStore.defaults[1].a.kinds == [.gate, .drive, .amp], "factory presets built from instances")

        print("BlockParams.copy / setOn")
        var dst = BlockParams(); var src = BlockParams(); src.delayMix = 77; src.delayTime = 999; src.delayOn = false
        dst.copy(.delay, from: src)
        check(dst.delayMix == 77 && dst.delayTime == 999 && !dst.delayOn, "delay settings copied")
        check(dst.driveAmt == BlockParams().driveAmt, "other blocks untouched")
        dst.setOn(.delay, true); check(dst.isOn(.delay), "setOn/isOn")

        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
