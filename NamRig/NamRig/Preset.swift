//
//  Preset.swift
//  NamRig — a full rig snapshot (all blocks + params) that can be saved, recalled,
//  and (later) switched by MIDI program change. JSON-persisted in Documents.
//

import Foundation

struct Preset: Codable, Identifiable {
    var id = UUID()
    var name = "Preset"
    var model = "T3K-sweep-v3-FX"

    var ampOn = true,    ampDrive = 0.0
    var gateOn = true,   gateThr = -34.0
    var compOn = false,  compThr = -18.0, compRatio = 4.0, compAtk = 10.0, compRel = 120.0, compMakeup = 0.0
    var driveOn = false, driveAmt = 4.0,  driveTone = 4000.0, driveLevel = 0.0
    var eqOn = true,     bass = 0.0, mid = 0.0, treble = 0.0
    var delayOn = false, delayTime = 350.0, delayFb = 35.0, delayMix = 30.0
    var reverbOn = false, reverbDecay = 70.0, reverbDamp = 30.0, reverbMix = 25.0
    var output = -6.0

    // FX expansion + free-order chain
    var boostOn = false, boostDb = 6.0
    var driveMode = 0
    var chorusOn = false, chorusRate = 0.8, chorusDepth = 6.0, chorusMix = 40.0
    var flangerOn = false, flangerRate = 0.4, flangerDepth = 2.0, flangerFb = 50.0, flangerMix = 50.0
    var tremoloOn = false, tremoloRate = 5.0, tremoloDepth = 50.0
    var reverbType = 3
    var order: [String] = ["Noise Gate", "Compressor", "Boost", "Drive", "Pedal", "Amp", "EQ", "Chorus", "Flanger", "Tremolo", "Delay", "Reverb"]

    // 2nd neural slot (pedal capture in front of the amp)
    var pedalOn = false, pedalModel = "", pedalDrive = 0.0, pedalLevel = 0.0
    var cabIR = ""   // cab impulse-response filename (in Documents/IRs), "" = none
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

    static var defaults: [Preset] {
        [
            Preset(name: "Clean"),
            Preset(name: "Crunch", driveOn: true, driveAmt: 12, driveLevel: -2),
            Preset(name: "Lead", driveOn: true, driveAmt: 22, delayOn: true, delayMix: 22),
            Preset(name: "Ambient", delayOn: true, delayTime: 420, delayMix: 25, reverbOn: true, reverbDecay: 85, reverbMix: 45)
        ]
    }
}
