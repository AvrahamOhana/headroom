//
//  Preset.swift
//  NamRig — a full rig snapshot: two paths (A ∥ B, each an ordered list of block instances), the
//  A/B mixer, the output stage, tempo and the per-preset MIDI-out list. JSON-persisted in Documents.
//

import Foundation

struct Preset: Codable, Identifiable {
    var id = UUID()
    var name = "Preset"
    var a = PathState()
    var b = PathState()
    var dualOn = false
    var levelA = 0.0, levelB = 0.0, panA = -0.7, panB = 0.7   // A/B mixer (dB, −1…1)
    var output = -6.0
    var stereoOn = false, stereoPingMix = 25.0, stereoPingTime = 350.0, stereoPingFb = 30.0, stereoSpace = 18.0, stereoWidth = 100.0
    var bpm = 0.0
    var midiOut: [MIDIOutMessage] = []
}

// Tolerant decoder. A LEGACY preset (flat block keys at the top level, no `a`) decodes into path A —
// `PathState` handles that shape itself.
extension Preset {
    private enum LegacyKeys: String, CodingKey { case dualOn, ampALevel, ampBLevel, ampAPan, ampBPan }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func g<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decode(T.self, forKey: k)) ?? def }
        id = g(.id, id); name = g(.name, name)
        if let pa = try? c.decode(PathState.self, forKey: .a) {
            a = pa; b = g(.b, b)
        } else {
            a = (try? PathState(from: decoder)) ?? PathState()
        }
        dualOn = g(.dualOn, dualOn)
        levelA = g(.levelA, levelA); levelB = g(.levelB, levelB); panA = g(.panA, panA); panB = g(.panB, panB)
        if let l = try? decoder.container(keyedBy: LegacyKeys.self) {
            levelA = (try? l.decode(Double.self, forKey: .ampALevel)) ?? levelA
            levelB = (try? l.decode(Double.self, forKey: .ampBLevel)) ?? levelB
            panA = (try? l.decode(Double.self, forKey: .ampAPan)) ?? panA
            panB = (try? l.decode(Double.self, forKey: .ampBPan)) ?? panB
        }
        output = g(.output, output)
        stereoOn = g(.stereoOn, stereoOn); stereoPingMix = g(.stereoPingMix, stereoPingMix); stereoPingTime = g(.stereoPingTime, stereoPingTime)
        stereoPingFb = g(.stereoPingFb, stereoPingFb); stereoSpace = g(.stereoSpace, stereoSpace); stereoWidth = g(.stereoWidth, stereoWidth)
        bpm = g(.bpm, bpm)
        midiOut = g(.midiOut, midiOut)
    }
}

enum PresetStore {
    static let url: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("presets.json")

    static func load() -> [Preset] {
        guard let data = try? Data(contentsOf: url),
              let presets = try? JSONDecoder().decode([Preset].self, from: data),
              !presets.isEmpty else { return defaults }
        return presets
    }

    static func save(_ presets: [Preset]) {
        if let data = try? JSONEncoder().encode(presets) { try? data.write(to: url) }
    }

    /// Factory presets. Default chain is just Gate → Amp; add what you want.
    static var defaults: [Preset] {
        [
            Preset(name: "Clean"),
            Preset(name: "Crunch", a: PathState.make([.gate, .drive, .amp]) { $0.driveAmt = 12; $0.driveLevel = -2 }),
            Preset(name: "Lead", a: PathState.make([.gate, .drive, .amp, .delay]) { $0.driveAmt = 22; $0.delayMix = 22 }),
            Preset(name: "Ambient", a: PathState.make([.gate, .amp, .delay, .reverb]) { $0.delayTime = 420; $0.delayMix = 25; $0.reverbDecay = 85; $0.reverbMix = 45 })
        ]
    }
}
