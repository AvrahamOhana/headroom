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
    var order: [String] = ["Noise Gate", "Compressor", "Boost", "Drive", "Pedal", "Amp", "EQ", "Chorus", "Flanger", "Tremolo", "Delay", "Reverb", "IR Reverb"]

    // 2nd neural slot (pedal capture in front of the amp)
    var pedalOn = false, pedalModel = "", pedalDrive = 0.0, pedalLevel = 0.0
    var cabIR = ""   // cab impulse-response filename (in Documents/IRs), "" = none
    var irReverbOn = false, irReverbMix = 35.0, irReverbPredelay = 0.0, irReverbIR = ""
}

// Tolerant decoder: every field falls back to its default when a key is absent, so ADDING new
// fields never invalidates saved presets again (the old "schema change wipes presets" gotcha).
// Lives in an extension so the synthesized memberwise init (used by PresetStore.defaults) stays.
extension Preset {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func g<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decode(T.self, forKey: k)) ?? def }
        id = g(.id, id); name = g(.name, name); model = g(.model, model)
        ampOn = g(.ampOn, ampOn); ampDrive = g(.ampDrive, ampDrive)
        gateOn = g(.gateOn, gateOn); gateThr = g(.gateThr, gateThr)
        compOn = g(.compOn, compOn); compThr = g(.compThr, compThr); compRatio = g(.compRatio, compRatio); compAtk = g(.compAtk, compAtk); compRel = g(.compRel, compRel); compMakeup = g(.compMakeup, compMakeup)
        driveOn = g(.driveOn, driveOn); driveAmt = g(.driveAmt, driveAmt); driveTone = g(.driveTone, driveTone); driveLevel = g(.driveLevel, driveLevel)
        eqOn = g(.eqOn, eqOn); bass = g(.bass, bass); mid = g(.mid, mid); treble = g(.treble, treble)
        delayOn = g(.delayOn, delayOn); delayTime = g(.delayTime, delayTime); delayFb = g(.delayFb, delayFb); delayMix = g(.delayMix, delayMix)
        reverbOn = g(.reverbOn, reverbOn); reverbDecay = g(.reverbDecay, reverbDecay); reverbDamp = g(.reverbDamp, reverbDamp); reverbMix = g(.reverbMix, reverbMix)
        output = g(.output, output)
        boostOn = g(.boostOn, boostOn); boostDb = g(.boostDb, boostDb)
        driveMode = g(.driveMode, driveMode)
        chorusOn = g(.chorusOn, chorusOn); chorusRate = g(.chorusRate, chorusRate); chorusDepth = g(.chorusDepth, chorusDepth); chorusMix = g(.chorusMix, chorusMix)
        flangerOn = g(.flangerOn, flangerOn); flangerRate = g(.flangerRate, flangerRate); flangerDepth = g(.flangerDepth, flangerDepth); flangerFb = g(.flangerFb, flangerFb); flangerMix = g(.flangerMix, flangerMix)
        tremoloOn = g(.tremoloOn, tremoloOn); tremoloRate = g(.tremoloRate, tremoloRate); tremoloDepth = g(.tremoloDepth, tremoloDepth)
        reverbType = g(.reverbType, reverbType)
        order = g(.order, order)
        pedalOn = g(.pedalOn, pedalOn); pedalModel = g(.pedalModel, pedalModel); pedalDrive = g(.pedalDrive, pedalDrive); pedalLevel = g(.pedalLevel, pedalLevel)
        cabIR = g(.cabIR, cabIR)
        irReverbOn = g(.irReverbOn, irReverbOn); irReverbMix = g(.irReverbMix, irReverbMix); irReverbPredelay = g(.irReverbPredelay, irReverbPredelay); irReverbIR = g(.irReverbIR, irReverbIR)
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

    static var defaults: [Preset] {
        [
            Preset(name: "Clean"),
            Preset(name: "Crunch", driveOn: true, driveAmt: 12, driveLevel: -2),
            Preset(name: "Lead", driveOn: true, driveAmt: 22, delayOn: true, delayMix: 22),
            Preset(name: "Ambient", delayOn: true, delayTime: 420, delayMix: 25, reverbOn: true, reverbDecay: 85, reverbMix: 45)
        ]
    }
}
