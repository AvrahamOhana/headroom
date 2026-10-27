package com.avrahamohana.headroom.model

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import java.util.UUID

/** Same order as Swift `BlockKind` and the C++ `hr::Kind` — the ordinal crosses JNI. */
enum class BlockKind(val raw: String, val short: String, val full: String) {
    GATE("Noise Gate", "GATE", "Noise Gate"),
    COMP("Compressor", "COMP", "Compressor"),
    BOOST("Boost", "BST", "Clean Boost"),
    DRIVE("Drive", "DRV", "Drive"),
    STOMP("Stomp", "STMP", "Stompbox"),
    WAH("Wah", "WAH", "Wah"),
    PEDAL("Pedal", "PED", "Pedal"),
    AMP("Amp", "AMP", "Amp"),
    CAB("Cab", "CAB", "Cab"),
    EQ("EQ", "EQ", "EQ"),
    CHORUS("Chorus", "CHO", "Chorus"),
    FLANGER("Flanger", "FLG", "Flanger"),
    TREMOLO("Tremolo", "TRM", "Tremolo"),
    DELAY("Delay", "DLY", "Delay"),
    REVERB("Reverb", "RVB", "Reverb"),
    IR_REVERB("IR Reverb", "IRV", "IR Reverb");

    val preAmp: Boolean get() = this in setOf(GATE, COMP, BOOST, DRIVE, STOMP, WAH, PEDAL)

    companion object {
        fun fromRaw(s: String) = entries.firstOrNull { it.raw == s }
    }
}

/** Swift synthesizes `{"eighth":{}}` for this enum — read/write that shape so presets move between platforms. */
@Serializable(with = NoteDivisionSerializer::class)
enum class NoteDivision(val key: String, val label: String, val beats: Double) {
    QUARTER("quarter", "1/4", 1.0),
    DOTTED_EIGHTH("dottedEighth", "1/8.", 0.75),
    EIGHTH("eighth", "1/8", 0.5),
    EIGHTH_TRIPLET("eighthTriplet", "1/8T", 1.0 / 3.0),
    SIXTEENTH("sixteenth", "1/16", 0.25),
}

object NoteDivisionSerializer : KSerializer<NoteDivision> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("NoteDivision")
    override fun serialize(encoder: Encoder, value: NoteDivision) {
        (encoder as JsonEncoder).encodeJsonElement(buildJsonObject { put(value.key, JsonObject(emptyMap())) })
    }
    override fun deserialize(decoder: Decoder): NoteDivision {
        val el = (decoder as JsonDecoder).decodeJsonElement()
        val key = when (el) {
            is JsonObject -> el.keys.firstOrNull()
            is JsonPrimitive -> el.contentOrNull
            else -> null
        }
        return NoteDivision.entries.firstOrNull { it.key == key } ?: NoteDivision.EIGHTH
    }
}

/** Every block param, all kinds in one struct (only the instance's kind's fields matter). Keys = iOS keys. */
@Serializable
data class BlockParams(
    val model: String = "",
    val ampOn: Boolean = true, val ampDrive: Double = 0.0,
    val gateOn: Boolean = true, val gateThr: Double = -60.0, val gateRel: Double = 80.0, val gateRange: Double = -80.0,
    val compOn: Boolean = true, val compThr: Double = -18.0, val compRatio: Double = 4.0, val compAtk: Double = 10.0, val compRel: Double = 120.0, val compMakeup: Double = 0.0,
    val driveOn: Boolean = true, val driveAmt: Double = 4.0, val driveTone: Double = 4000.0, val driveLevel: Double = 0.0, val driveMode: Int = 0,
    val eqOn: Boolean = true, val bass: Double = 0.0, val mid: Double = 0.0, val treble: Double = 0.0,
    val delayOn: Boolean = true, val delayTime: Double = 350.0, val delayFb: Double = 35.0, val delayMix: Double = 30.0, val delayTone: Double = 60.0,
    val delaySync: Boolean = false, val delayDiv: NoteDivision = NoteDivision.EIGHTH,
    val reverbOn: Boolean = true, val reverbDecay: Double = 70.0, val reverbDamp: Double = 30.0, val reverbMix: Double = 25.0, val reverbType: Int = 3,
    val boostOn: Boolean = true, val boostDb: Double = 6.0,
    val stompOn: Boolean = true, val stompModel: Int = 0, val stompDrive: Double = 0.5, val stompTone: Double = 0.5, val stompLevel: Double = 0.8,
    val chorusOn: Boolean = true, val chorusRate: Double = 0.8, val chorusDepth: Double = 6.0, val chorusMix: Double = 40.0,
    val flangerOn: Boolean = true, val flangerRate: Double = 0.4, val flangerDepth: Double = 2.0, val flangerFb: Double = 50.0, val flangerMix: Double = 50.0,
    val tremoloOn: Boolean = true, val tremoloRate: Double = 5.0, val tremoloDepth: Double = 50.0,
    val pedalOn: Boolean = true, val pedalModel: String = "", val pedalDrive: Double = 0.0, val pedalLevel: Double = 0.0,
    val cabOn: Boolean = true, val cabIR: String = "",
    val irReverbOn: Boolean = true, val irReverbMix: Double = 35.0, val irReverbPredelay: Double = 0.0, val irReverbIR: String = "",
    val wahOn: Boolean = true, val wahPos: Double = 0.5, val wahAuto: Boolean = false, val wahSense: Double = 50.0, val wahMix: Double = 92.0,
) {
    fun isOn(k: BlockKind): Boolean = when (k) {
        BlockKind.GATE -> gateOn; BlockKind.COMP -> compOn; BlockKind.BOOST -> boostOn; BlockKind.DRIVE -> driveOn
        BlockKind.STOMP -> stompOn; BlockKind.WAH -> wahOn; BlockKind.PEDAL -> pedalOn; BlockKind.AMP -> ampOn
        BlockKind.CAB -> cabOn; BlockKind.EQ -> eqOn; BlockKind.CHORUS -> chorusOn; BlockKind.FLANGER -> flangerOn
        BlockKind.TREMOLO -> tremoloOn; BlockKind.DELAY -> delayOn; BlockKind.REVERB -> reverbOn; BlockKind.IR_REVERB -> irReverbOn
    }
    fun withOn(k: BlockKind, v: Boolean): BlockParams = when (k) {
        BlockKind.GATE -> copy(gateOn = v); BlockKind.COMP -> copy(compOn = v); BlockKind.BOOST -> copy(boostOn = v)
        BlockKind.DRIVE -> copy(driveOn = v); BlockKind.STOMP -> copy(stompOn = v); BlockKind.WAH -> copy(wahOn = v)
        BlockKind.PEDAL -> copy(pedalOn = v); BlockKind.AMP -> copy(ampOn = v); BlockKind.CAB -> copy(cabOn = v)
        BlockKind.EQ -> copy(eqOn = v); BlockKind.CHORUS -> copy(chorusOn = v); BlockKind.FLANGER -> copy(flangerOn = v)
        BlockKind.TREMOLO -> copy(tremoloOn = v); BlockKind.DELAY -> copy(delayOn = v); BlockKind.REVERB -> copy(reverbOn = v)
        BlockKind.IR_REVERB -> copy(irReverbOn = v)
    }
}

/** Kind is stored as the iOS raw string ("Noise Gate", "Amp", …). */
@Serializable
data class BlockInstance(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val kind: String,
    val p: BlockParams = BlockParams(),
) {
    val k: BlockKind get() = BlockKind.fromRaw(kind) ?: BlockKind.AMP
    val isOn: Boolean get() = p.isOn(k)
    companion object { fun of(k: BlockKind, p: BlockParams = BlockParams()) = BlockInstance(kind = k.raw, p = p) }
}

@Serializable
data class PathState(val blocks: List<BlockInstance> = defaultBlocks()) {
    companion object {
        fun defaultBlocks() = listOf(BlockInstance.of(BlockKind.GATE), BlockInstance.of(BlockKind.AMP))
        fun make(vararg kinds: BlockKind, tweak: (BlockParams) -> BlockParams = { it }) =
            PathState(kinds.map { BlockInstance.of(it, tweak(BlockParams())) })
    }
}

@Serializable
data class MidiOutMessage(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val kind: String = "programChange",       // programChange | controlChange
    val channel: Int = 1, val number: Int = 0, val value: Int = 0,
)

@Serializable
data class Preset(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String = "Preset",
    val a: PathState = PathState(),
    val b: PathState = PathState(),
    val dualOn: Boolean = false,
    val levelA: Double = 0.0, val levelB: Double = 0.0, val panA: Double = -0.7, val panB: Double = 0.7,
    val output: Double = -6.0,
    val stereoOn: Boolean = false, val stereoPingMix: Double = 25.0, val stereoPingTime: Double = 350.0,
    val stereoPingFb: Double = 30.0, val stereoSpace: Double = 18.0, val stereoWidth: Double = 100.0,
    val bpm: Double = 0.0,
    val midiOut: List<MidiOutMessage> = emptyList(),
) {
    companion object {
        fun defaults() = listOf(
            Preset(name = "Clean"),
            Preset(name = "Crunch", a = PathState.make(BlockKind.GATE, BlockKind.DRIVE, BlockKind.AMP) { it.copy(driveAmt = 12.0, driveLevel = -2.0) }),
            Preset(name = "Lead", a = PathState.make(BlockKind.GATE, BlockKind.DRIVE, BlockKind.AMP, BlockKind.DELAY) { it.copy(driveAmt = 22.0, delayMix = 22.0) }),
            Preset(name = "Ambient", a = PathState.make(BlockKind.GATE, BlockKind.AMP, BlockKind.DELAY, BlockKind.REVERB) {
                it.copy(delayTime = 420.0, delayMix = 25.0, reverbDecay = 85.0, reverbMix = 45.0)
            }),
        )
    }
}

enum class PathId(val label: String) { A("A"), B("B"); val other get() = if (this == A) B else A }
