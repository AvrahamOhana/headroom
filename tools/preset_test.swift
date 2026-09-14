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
        print("Legacy flat preset → path A")
        let legacy = """
        [{"id":"7E6C7B8A-1111-2222-3333-444444444444","name":"Old Lead","model":"Bugera V5","ampOn":true,"ampDrive":6,
          "gateOn":true,"gateThr":-40,"driveOn":true,"driveAmt":22,"delayOn":true,"delayMix":22,"delayTime":420,
          "order":["Noise Gate","Drive","Amp","Delay"],"output":-9,"stereoOn":true,"stereoWidth":80,
          "ampALevel":-3,"ampBPan":0.5,"reverbType":1,"wahOn":true,"wahPos":0.3}]
        """.data(using: .utf8)!
        let ps = try JSONDecoder().decode([Preset].self, from: legacy)
        let p = ps[0]
        check(p.name == "Old Lead", "name")
        check(p.a.model == "Bugera V5" && p.a.ampDrive == 6 && p.a.driveAmt == 22 && p.a.delayMix == 22, "block params landed in path A")
        check(p.a.kinds == [.gate, .drive, .amp, .cab, .delay], "order migrated with Cab inserted after Amp: \(p.a.kinds)")
        check(p.output == -9 && p.stereoOn && p.stereoWidth == 80, "globals kept")
        check(p.levelA == -3 && p.panB == 0.5, "legacy mixer keys mapped (levelA \(p.levelA), panB \(p.panB))")
        check(p.a.wahOn && p.a.wahPos == 0.3 && p.a.reverbType == 1, "newer per-path fields")
        check(p.b == PathState() && p.dualOn == false, "path B default, dual off")

        print("Round trip (new schema)")
        var q = Preset(name: "Dual")
        q.dualOn = true; q.a.driveOn = true; q.b.model = "Other"; q.b.order = ["Amp", "Cab", "Reverb"]; q.levelB = -6; q.panA = -1
        q.midiOut = [MIDIOutMessage(kind: .controlChange, channel: 3, number: 20, value: 127)]
        let data = try JSONEncoder().encode([q])
        let back = try JSONDecoder().decode([Preset].self, from: data)[0]
        check(back.dualOn && back.a.driveOn && back.b.model == "Other" && back.b.kinds == [.amp, .cab, .reverb], "paths round-trip")
        check(back.levelB == -6 && back.panA == -1 && back.midiOut.first?.number == 20, "mixer + midiOut round-trip")
        let json = String(data: data, encoding: .utf8)!
        check(json.contains("\"a\":{") && json.contains("\"b\":{"), "encoded as nested a/b")

        print("PathState.copy")
        var dst = PathState(); var src = PathState(); src.delayMix = 77; src.delayTime = 999; src.delayOn = true
        dst.copy(.delay, from: src)
        check(dst.delayMix == 77 && dst.delayTime == 999 && dst.delayOn, "delay settings copied")
        check(dst.driveAmt == PathState().driveAmt, "other blocks untouched")

        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILED"); exit(fails == 0 ? 0 : 1)
    }
}
