package com.avrahamohana.headroom.model

/**
 * One knob/param of a block kind: UI range (same as the iOS knobs), the native param id
 * (see cpp/dsp/Block.h `namespace P`), and typed get/set on BlockParams.
 */
class ParamSpec(
    val key: String,
    val label: String,
    val min: Double,
    val max: Double,
    val default: Double,
    val unit: String = "",
    val decimals: Int = 0,
    val nativeId: Int,
    val bipolar: Boolean = false,
    val knob: Boolean = true,          // false → a picker/toggle drawn by the editor
    val get: (BlockParams) -> Double,
    val set: (BlockParams, Double) -> BlockParams,
) {
    fun norm(v: Double) = ((v - min) / (max - min)).coerceIn(0.0, 1.0)
    fun denorm(n: Double) = min + (max - min) * n.coerceIn(0.0, 1.0)
}

object Params {
    private fun d(key: String, label: String, min: Double, max: Double, def: Double, unit: String, id: Int,
                  get: (BlockParams) -> Double, set: (BlockParams, Double) -> BlockParams,
                  decimals: Int = 0, bipolar: Boolean = false, knob: Boolean = true) =
        ParamSpec(key, label, min, max, def, unit, decimals, id, bipolar, knob, get, set)

    val specs: Map<BlockKind, List<ParamSpec>> = mapOf(
        BlockKind.GATE to listOf(
            d("gateThr", "Threshold", -80.0, -10.0, -60.0, "dB", 0, { it.gateThr }, { p, v -> p.copy(gateThr = v) }),
            d("gateRel", "Release", 10.0, 500.0, 80.0, "ms", 1, { it.gateRel }, { p, v -> p.copy(gateRel = v) }),
            d("gateRange", "Range", -90.0, -10.0, -80.0, "dB", 2, { it.gateRange }, { p, v -> p.copy(gateRange = v) }),
        ),
        BlockKind.COMP to listOf(
            d("compThr", "Thresh", -48.0, 0.0, -18.0, "dB", 0, { it.compThr }, { p, v -> p.copy(compThr = v) }),
            d("compRatio", "Ratio", 1.0, 20.0, 4.0, ":1", 1, { it.compRatio }, { p, v -> p.copy(compRatio = v) }, decimals = 1),
            d("compAtk", "Attack", 1.0, 100.0, 10.0, "ms", 2, { it.compAtk }, { p, v -> p.copy(compAtk = v) }),
            d("compRel", "Release", 20.0, 500.0, 120.0, "ms", 3, { it.compRel }, { p, v -> p.copy(compRel = v) }),
            d("compMakeup", "Makeup", 0.0, 24.0, 0.0, "dB", 4, { it.compMakeup }, { p, v -> p.copy(compMakeup = v) }),
        ),
        BlockKind.BOOST to listOf(
            d("boostDb", "Boost", 0.0, 18.0, 6.0, "dB", 0, { it.boostDb }, { p, v -> p.copy(boostDb = v) }),
        ),
        BlockKind.DRIVE to listOf(
            d("driveMode", "Mode", 0.0, 2.0, 0.0, "", 3, { it.driveMode.toDouble() }, { p, v -> p.copy(driveMode = v.toInt()) }, knob = false),
            d("driveAmt", "Drive", 1.0, 50.0, 4.0, "x", 0, { it.driveAmt }, { p, v -> p.copy(driveAmt = v) }),
            d("driveTone", "Tone", 1000.0, 8000.0, 4000.0, "Hz", 1, { it.driveTone }, { p, v -> p.copy(driveTone = v) }),
            d("driveLevel", "Level", -24.0, 6.0, 0.0, "dB", 2, { it.driveLevel }, { p, v -> p.copy(driveLevel = v) }),
        ),
        BlockKind.STOMP to listOf(
            d("stompModel", "Pedal", 0.0, 4.0, 0.0, "", 0, { it.stompModel.toDouble() }, { p, v -> p.copy(stompModel = v.toInt()) }, knob = false),
            d("stompDrive", "Drive", 0.0, 1.0, 0.5, "", 1, { it.stompDrive }, { p, v -> p.copy(stompDrive = v) }, decimals = 2),
            d("stompTone", "Tone", 0.0, 1.0, 0.5, "", 2, { it.stompTone }, { p, v -> p.copy(stompTone = v) }, decimals = 2),
            d("stompLevel", "Level", 0.0, 1.0, 0.8, "", 3, { it.stompLevel }, { p, v -> p.copy(stompLevel = v) }, decimals = 2),
        ),
        BlockKind.WAH to listOf(
            d("wahAuto", "Auto", 0.0, 1.0, 0.0, "", 1, { if (it.wahAuto) 1.0 else 0.0 }, { p, v -> p.copy(wahAuto = v > 0.5) }, knob = false),
            d("wahPos", "Pedal", 0.0, 1.0, 0.5, "", 0, { it.wahPos }, { p, v -> p.copy(wahPos = v) }, decimals = 2),
            d("wahSense", "Sense", 0.0, 100.0, 50.0, "%", 2, { it.wahSense }, { p, v -> p.copy(wahSense = v) }),
            d("wahMix", "Mix", 0.0, 100.0, 92.0, "%", 3, { it.wahMix }, { p, v -> p.copy(wahMix = v) }),
        ),
        BlockKind.PEDAL to listOf(
            d("pedalDrive", "Drive", 0.0, 24.0, 0.0, "dB", 0, { it.pedalDrive }, { p, v -> p.copy(pedalDrive = v) }),
            d("pedalLevel", "Level", -24.0, 12.0, 0.0, "dB", 1, { it.pedalLevel }, { p, v -> p.copy(pedalLevel = v) }),
        ),
        BlockKind.AMP to listOf(
            d("ampDrive", "Drive", 0.0, 24.0, 0.0, "dB", 0, { it.ampDrive }, { p, v -> p.copy(ampDrive = v) }),
        ),
        BlockKind.CAB to emptyList(),
        BlockKind.EQ to listOf(
            d("bass", "Bass", -12.0, 12.0, 0.0, "dB", 0, { it.bass }, { p, v -> p.copy(bass = v) }, bipolar = true),
            d("mid", "Mid", -12.0, 12.0, 0.0, "dB", 1, { it.mid }, { p, v -> p.copy(mid = v) }, bipolar = true),
            d("treble", "Treble", -12.0, 12.0, 0.0, "dB", 2, { it.treble }, { p, v -> p.copy(treble = v) }, bipolar = true),
        ),
        BlockKind.CHORUS to listOf(
            d("chorusRate", "Rate", 0.1, 8.0, 0.8, "Hz", 0, { it.chorusRate }, { p, v -> p.copy(chorusRate = v) }, decimals = 2),
            d("chorusDepth", "Depth", 1.0, 15.0, 6.0, "ms", 1, { it.chorusDepth }, { p, v -> p.copy(chorusDepth = v) }, decimals = 1),
            d("chorusMix", "Mix", 0.0, 100.0, 40.0, "%", 2, { it.chorusMix }, { p, v -> p.copy(chorusMix = v) }),
        ),
        BlockKind.FLANGER to listOf(
            d("flangerRate", "Rate", 0.05, 5.0, 0.4, "Hz", 0, { it.flangerRate }, { p, v -> p.copy(flangerRate = v) }, decimals = 2),
            d("flangerDepth", "Depth", 0.5, 8.0, 2.0, "ms", 1, { it.flangerDepth }, { p, v -> p.copy(flangerDepth = v) }, decimals = 1),
            d("flangerFb", "Feedback", 0.0, 95.0, 50.0, "%", 2, { it.flangerFb }, { p, v -> p.copy(flangerFb = v) }),
            d("flangerMix", "Mix", 0.0, 100.0, 50.0, "%", 3, { it.flangerMix }, { p, v -> p.copy(flangerMix = v) }),
        ),
        BlockKind.TREMOLO to listOf(
            d("tremoloRate", "Rate", 0.5, 14.0, 5.0, "Hz", 0, { it.tremoloRate }, { p, v -> p.copy(tremoloRate = v) }, decimals = 1),
            d("tremoloDepth", "Depth", 0.0, 100.0, 50.0, "%", 1, { it.tremoloDepth }, { p, v -> p.copy(tremoloDepth = v) }),
        ),
        BlockKind.DELAY to listOf(
            d("delayTime", "Time", 50.0, 1000.0, 350.0, "ms", 0, { it.delayTime }, { p, v -> p.copy(delayTime = v) }),
            d("delayFb", "Feedback", 0.0, 90.0, 35.0, "%", 1, { it.delayFb }, { p, v -> p.copy(delayFb = v) }),
            d("delayTone", "Tone", 0.0, 100.0, 60.0, "%", 3, { it.delayTone }, { p, v -> p.copy(delayTone = v) }),
            d("delayMix", "Mix", 0.0, 100.0, 30.0, "%", 2, { it.delayMix }, { p, v -> p.copy(delayMix = v) }),
        ),
        BlockKind.REVERB to listOf(
            d("reverbType", "Type", 0.0, 3.0, 3.0, "", 0, { it.reverbType.toDouble() }, { p, v -> p.copy(reverbType = v.toInt()) }, knob = false),
            d("reverbDecay", "Decay", 0.0, 100.0, 70.0, "%", 1, { it.reverbDecay }, { p, v -> p.copy(reverbDecay = v) }),
            d("reverbDamp", "Damping", 0.0, 100.0, 30.0, "%", 2, { it.reverbDamp }, { p, v -> p.copy(reverbDamp = v) }),
            d("reverbMix", "Mix", 0.0, 100.0, 25.0, "%", 3, { it.reverbMix }, { p, v -> p.copy(reverbMix = v) }),
        ),
        BlockKind.IR_REVERB to listOf(
            d("irReverbPredelay", "Predelay", 0.0, 200.0, 0.0, "ms", 1, { it.irReverbPredelay }, { p, v -> p.copy(irReverbPredelay = v) }),
            d("irReverbMix", "Mix", 0.0, 100.0, 35.0, "%", 0, { it.irReverbMix }, { p, v -> p.copy(irReverbMix = v) }),
        ),
    )

    fun of(k: BlockKind): List<ParamSpec> = specs[k].orEmpty()
    fun find(k: BlockKind, key: String): ParamSpec? = of(k).firstOrNull { it.key == key }

    val stompNames = listOf("Green Screamer", "Rodent", "Modern Distortion", "Centaur Gold", "Muffin Fuzz")
    const val stompDisclaimer = "All model names are original. Third-party product names are referenced only to identify " +
        "the inspiring circuits. Headroom is not affiliated with or endorsed by any manufacturer."
    val reverbTypes = listOf("Room", "Plate", "Spring", "Hall")
    val driveModes = listOf("Soft", "Hard", "Fuzz")

    /** Reverb-type presets for decay/damp, as on iOS. */
    fun reverbTypeDefaults(t: Int): Pair<Double, Double> = when (t) {
        0 -> 35.0 to 60.0; 1 -> 88.0 to 12.0; 2 -> 55.0 to 35.0; else -> 80.0 to 18.0
    }
}

/** MIDI-mappable params (same set + ranges as iOS `MIDIParam`). kind+key → a ParamSpec, or a global. */
enum class MidiParam(val label: String, val kind: BlockKind?, val key: String) {
    AMP_DRIVE("Amp Drive", BlockKind.AMP, "ampDrive"),
    OUTPUT("Output", null, "output"),
    GATE_THR("Gate Thresh", BlockKind.GATE, "gateThr"),
    BASS("Bass", BlockKind.EQ, "bass"), MID("Mid", BlockKind.EQ, "mid"), TREBLE("Treble", BlockKind.EQ, "treble"),
    DRIVE_AMT("Drive", BlockKind.DRIVE, "driveAmt"), DRIVE_LEVEL("Drive Level", BlockKind.DRIVE, "driveLevel"),
    DELAY_MIX("Delay Mix", BlockKind.DELAY, "delayMix"), DELAY_FB("Delay Fbk", BlockKind.DELAY, "delayFb"),
    REVERB_MIX("Reverb Mix", BlockKind.REVERB, "reverbMix"), REVERB_DECAY("Reverb Decay", BlockKind.REVERB, "reverbDecay"),
    COMP_MAKEUP("Comp Makeup", BlockKind.COMP, "compMakeup"), BOOST_DB("Boost", BlockKind.BOOST, "boostDb"),
    PEDAL_DRIVE("Pedal Drive", BlockKind.PEDAL, "pedalDrive"), PEDAL_LEVEL("Pedal Level", BlockKind.PEDAL, "pedalLevel"),
    CHORUS_MIX("Chorus Mix", BlockKind.CHORUS, "chorusMix"), FLANGER_MIX("Flanger Mix", BlockKind.FLANGER, "flangerMix"),
    TREMOLO_DEPTH("Tremolo Depth", BlockKind.TREMOLO, "tremoloDepth"),
    WAH("Wah (expression)", BlockKind.WAH, "wahPos"), DELAY_TONE("Delay Tone", BlockKind.DELAY, "delayTone"),
    COMP_THR("Comp Thresh", BlockKind.COMP, "compThr"), STOMP_DRIVE("Stomp Drive", BlockKind.STOMP, "stompDrive"),
    LOOP_LEVEL("Loop Level", null, "loopLevel"),
    AMP_A_LEVEL("Path A Level", null, "levelA"), AMP_B_LEVEL("Path B Level", null, "levelB");

    /** Swift raw value (camelCase) for mapping files. */
    val raw: String get() = name.lowercase().split('_').mapIndexed { i, s -> if (i == 0) s else s.replaceFirstChar { it.uppercase() } }.joinToString("")
}
