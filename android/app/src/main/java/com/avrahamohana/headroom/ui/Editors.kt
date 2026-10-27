package com.avrahamohana.headroom.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.avrahamohana.headroom.engine.RigEngine
import com.avrahamohana.headroom.model.BlockInstance
import com.avrahamohana.headroom.model.BlockKind
import com.avrahamohana.headroom.model.MidiOutMessage
import com.avrahamohana.headroom.model.NoteDivision
import com.avrahamohana.headroom.model.ParamSpec
import com.avrahamohana.headroom.model.Params
import com.avrahamohana.headroom.model.PathId
import kotlinx.coroutines.delay

/** Callbacks into the screen for pickers / browsers. */
class EditorActions(
    val importModel: (slot: BlockKind, instId: String) -> Unit,
    val browse: (target: String, instId: String) -> Unit,   // "amp" | "pedal" | "cab"
    val pickIR: (instId: String, cab: Boolean) -> Unit,
    val manageModels: () -> Unit,
    val sendMidi: (MidiOutMessage) -> Unit,
    val outChannel: () -> Int,
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun KnobGrid(content: @Composable () -> Unit) {
    FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalArrangement = Arrangement.spacedBy(10.dp)) { content() }
}

@Composable
private fun SpecKnob(rig: RigEngine, inst: BlockInstance, s: ParamSpec, size: androidx.compose.ui.unit.Dp = 60.dp) =
    Knob(s.label, s.get(inst.p), { rig.setParam(inst.id, s, it) }, s.min, s.max, s.unit, s.decimals, inst.k.color, s.default, s.bipolar, size)

@Composable
fun Segmented(options: List<String>, selected: Int, onSelect: (Int) -> Unit, color: Color = MaterialTheme.colorScheme.primary) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { i, o ->
            SegmentedButton(selected == i, { onSelect(i) }, SegmentedButtonDefaults.itemShape(i, options.size),
                colors = SegmentedButtonDefaults.colors(activeContainerColor = color.copy(alpha = 0.3f)), icon = {}) { Text(o, fontSize = 13.sp, maxLines = 1) }
        }
    }
}

@Composable
private fun Caption(t: String) = Text(t, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))

@Composable
fun BlockEditor(rig: RigEngine, instId: String, actions: EditorActions, onClose: () -> Unit) {
    val found = rig.instance(instId) ?: run { onClose(); return }
    val (inst, pid) = found
    val k = inst.k
    val dark = LocalDark.current
    Column(Modifier.fillMaxWidth().chassis(k.color, dark).padding(16.dp).padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (rig.dualOn) Text(pid.label, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color.White,
                modifier = Modifier.clip(CircleShape).background(Stage.cyan).padding(horizontal = 6.dp, vertical = 2.dp))
            Icon(k.icon, null, tint = if (inst.isOn) k.color else Color.Gray)
            Nameplate(rig.label(inst.id)?.let { "${k.full} $it" } ?: k.full)
            Spacer(Modifier.weight(1f))
            if (rig.dualOn && rig.countOf(pid.other, k) < RigEngine.MAX_PER_KIND) {
                OutlinedButton({ rig.moveInstance(inst.id, pid.other, null); rig.focus(inst.id) }, contentPadding = PaddingValues(horizontal = 8.dp)) {
                    Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(14.dp)); Text(" ${pid.other.label}", fontSize = 12.sp)
                }
            }
            IconButton({ rig.removeInstance(inst.id); onClose() }) { Icon(Icons.Filled.Delete, "Remove block", tint = Color.Gray) }
            Footswitch(inst.isOn, { rig.setEnabled(inst.id, it) })
        }
        Controls(rig, inst, actions)
    }
}

@Composable
private fun Controls(rig: RigEngine, inst: BlockInstance, actions: EditorActions) {
    val k = inst.k; val p = inst.p; val c = k.color
    val specs = Params.of(k).filter { it.knob }
    when (k) {
        BlockKind.GATE -> { KnobGrid { specs.forEach { SpecKnob(rig, inst, it) } }
            Caption("Range sets how far the gate closes: −90 dB = hard mute, −20 dB = gentle expander (hiss down, sustain intact).") }
        BlockKind.COMP -> { KnobGrid { specs.forEach { SpecKnob(rig, inst, it) } }; GrMeter(rig, inst.id) }
        BlockKind.DRIVE -> {
            Segmented(Params.driveModes, p.driveMode, { m -> rig.setParam(inst.id, Params.find(k, "driveMode")!!, m.toDouble()) }, c)
            KnobGrid { specs.forEach { SpecKnob(rig, inst, it) } }
        }
        BlockKind.STOMP -> {
            PickerRow(Params.stompNames[p.stompModel.coerceIn(0, 4)], Icons.Filled.Whatshot, Params.stompNames.mapIndexed { i, n -> n to (i == p.stompModel) }) { i ->
                rig.setParam(inst.id, Params.find(k, "stompModel")!!, i.toDouble())
            }
            KnobGrid { specs.forEach { SpecKnob(rig, inst, it) } }
            Caption(Params.stompDisclaimer)
        }
        BlockKind.WAH -> {
            Segmented(listOf("Pedal", "Auto"), if (p.wahAuto) 1 else 0, { rig.setParam(inst.id, Params.find(k, "wahAuto")!!, it.toDouble()) }, c)
            KnobGrid {
                if (p.wahAuto) SpecKnob(rig, inst, Params.find(k, "wahSense")!!) else SpecKnob(rig, inst, Params.find(k, "wahPos")!!)
                SpecKnob(rig, inst, Params.find(k, "wahMix")!!)
            }
            if (!p.wahAuto) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("heel", fontSize = 11.sp)
                    Slider(p.wahPos.toFloat(), { rig.setParam(inst.id, Params.find(k, "wahPos")!!, it.toDouble()) }, Modifier.weight(1f).padding(horizontal = 8.dp),
                        colors = SliderDefaults.colors(thumbColor = c, activeTrackColor = c))
                    Text("toe", fontSize = 11.sp)
                }
                Caption("Expression pedal: MIDI → Add mapping → Parameter → \"Wah (expression)\", then Learn.")
            }
        }
        BlockKind.AMP -> {
            Artwork(rig.artworkFor(inst), 150)
            val current = rig.models.firstOrNull { it.id == p.model } ?: rig.ampModels.firstOrNull()
            ModelMenu(current?.name ?: "No models", Icons.Filled.Speaker,
                rig.ampModels.map { it.name to (it.id == current?.id) },
                onPick = { i -> rig.updateParams(inst.id) { it.copy(model = rig.ampModels[i].id) } },
                extras = listOf("Import .nam…" to { actions.importModel(BlockKind.AMP, inst.id) },
                    "Browse TONE3000…" to { actions.browse("amp", inst.id) },
                    "Manage models…" to actions.manageModels))
            Caption(rig.status[inst.id] ?: "")
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                SpecKnob(rig, inst, specs[0], 68.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    MeterRow("In", rig.inPeakDb); MeterRow("Out", rig.outPeakDb)
                }
            }
        }
        BlockKind.PEDAL -> {
            Artwork(rig.artworkFor(inst), 140)
            val list = rig.pedalModels
            ModelMenu(if (p.pedalModel.isEmpty()) "None" else rig.modelName(p.pedalModel), Icons.Filled.SettingsInputComponent,
                listOf("None (empty)" to p.pedalModel.isEmpty()) + list.map { it.name to (it.id == p.pedalModel) },
                onPick = { i -> rig.updateParams(inst.id) { it.copy(pedalModel = if (i == 0) "" else list[i - 1].id) } },
                extras = listOf("Import .nam…" to { actions.importModel(BlockKind.PEDAL, inst.id) },
                    "Browse TONE3000 (Pedals)…" to { actions.browse("pedal", inst.id) }))
            Caption(rig.status[inst.id] ?: "— empty —")
            KnobGrid { specs.forEach { SpecKnob(rig, inst, it) } }
        }
        BlockKind.CAB -> {
            IrRow(if (p.cabIR.isEmpty()) "None" else p.cabIR.substringBeforeLast('.'), Icons.Filled.SpeakerGroup,
                onClear = if (p.cabIR.isNotEmpty()) ({ rig.updateParams(inst.id) { it.copy(cabIR = "") } }) else null,
                buttons = listOf("Browse" to { actions.browse("cab", inst.id) }, "File" to { actions.pickIR(inst.id, true) }))
            rig.status[inst.id]?.takeIf { it.startsWith("❌") }?.let { Caption(it) }
            Caption("Speaker cabinet IR. Browse TONE3000 cabs or load your own .wav.")
        }
        BlockKind.DELAY -> {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Tempo Sync", Modifier.weight(1f), fontSize = 15.sp)
                Switch(p.delaySync, { rig.setDelaySync(inst.id, it) }, colors = SwitchDefaults.colors(checkedTrackColor = c))
            }
            if (p.delaySync) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Button({ rig.tapTempo() }, colors = ButtonDefaults.buttonColors(containerColor = c)) { Icon(Icons.Filled.TouchApp, null); Text(" TAP") }
                    Spacer(Modifier.weight(1f))
                    Text("${rig.bpm.toInt()} BPM", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                }
                Segmented(NoteDivision.entries.map { it.label }, p.delayDiv.ordinal, { rig.setDelayDivision(inst.id, NoteDivision.entries[it]) }, c)
            }
            KnobGrid { specs.filter { !(p.delaySync && it.key == "delayTime") }.forEach { SpecKnob(rig, inst, it) } }
        }
        BlockKind.REVERB -> {
            Segmented(Params.reverbTypes, p.reverbType, { rig.selectReverbType(inst.id, it) }, c)
            KnobGrid { specs.forEach { SpecKnob(rig, inst, it) } }
        }
        BlockKind.IR_REVERB -> {
            IrRow(if (p.irReverbIR.isEmpty()) "None" else p.irReverbIR.substringBeforeLast('.'), Icons.Filled.Layers,
                onClear = if (p.irReverbIR.isNotEmpty()) ({ rig.updateParams(inst.id) { it.copy(irReverbIR = "") } }) else null,
                buttons = listOf("Load IR" to { actions.pickIR(inst.id, false) }))
            KnobGrid { specs.forEach { SpecKnob(rig, inst, it) } }
        }
        else -> KnobGrid { specs.forEach { SpecKnob(rig, inst, it) } }
    }
}

@Composable
private fun GrMeter(rig: RigEngine, id: String) {
    var gr by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(id) { while (true) { gr = rig.meter(id); delay(80) } }
    val norm = (-gr / 24f).coerceIn(0f, 1f)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("GR", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color.Gray)
        Box(Modifier.weight(1f).height(6.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.25f))) {
            Box(Modifier.fillMaxWidth(norm).height(6.dp).align(Alignment.CenterEnd).background(Color(0xFFFF9500)))
        }
        Text("%.1f dB".format(gr), fontSize = 11.sp, color = Color.Gray, modifier = Modifier.width(52.dp))
    }
}

@Composable
private fun Artwork(path: String?, h: Int) {
    val bmp = remember(path) { path?.let { runCatching { BitmapFactory.decodeFile(it)?.asImageBitmap() }.getOrNull() } } ?: return
    Box(Modifier.fillMaxWidth().height(h.dp).clip(RoundedCornerShape(10.dp)).background(Color.Black.copy(alpha = 0.25f)), contentAlignment = Alignment.Center) {
        Image(bmp, null, Modifier.padding(8.dp), contentScale = ContentScale.Fit)
    }
}

@Composable
private fun PickerRow(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, items: List<Pair<String, Boolean>>, onPick: (Int) -> Unit) =
    ModelMenu(title, icon, items, onPick, emptyList())

@Composable
private fun ModelMenu(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, items: List<Pair<String, Boolean>>,
                      onPick: (Int) -> Unit, extras: List<Pair<String, () -> Unit>>) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
            .clickable { open = true }.padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
            Text(title, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), maxLines = 1)
            Icon(Icons.Filled.UnfoldMore, null, Modifier.size(16.dp))
        }
        DropdownMenu(open, { open = false }) {
            items.forEachIndexed { i, (n, sel) ->
                DropdownMenuItem(text = { Text(n) }, leadingIcon = { if (sel) Icon(Icons.Filled.Check, null) }, onClick = { open = false; onPick(i) })
            }
            if (extras.isNotEmpty()) HorizontalDivider()
            extras.forEach { (n, a) -> DropdownMenuItem(text = { Text(n) }, onClick = { open = false; a() }) }
        }
    }
}

@Composable
private fun IrRow(name: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClear: (() -> Unit)?, buttons: List<Pair<String, () -> Unit>>) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)).padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(18.dp), tint = Color.Gray); Spacer(Modifier.width(8.dp))
        Text(name, Modifier.weight(1f), maxLines = 1, fontSize = 14.sp)
        if (onClear != null) IconButton(onClear) { Icon(Icons.Filled.Cancel, "Clear IR", tint = Color.Gray) }
        buttons.forEach { (t, a) -> TextButton(a) { Text(t) } }
    }
}

// ------------------------------------------------------------------ OUT block
@Composable
fun OutputEditor(rig: RigEngine, actions: EditorActions) {
    val dark = LocalDark.current
    val c = Stage.cyan
    Column(Modifier.fillMaxWidth().chassis(Color(0xFF2680BF), dark).padding(16.dp).padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Filled.Tune, null, tint = c); Spacer(Modifier.width(8.dp)); Nameplate("Output / Mixer") }
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Knob("Master", rig.outputDb, rig::setOutput, -40.0, 12.0, "dB", color = c, default = -6.0, size = 68.dp)
            Column(Modifier.weight(1f)) { MeterRow("Out", rig.outPeakDb) }
        }
        HorizontalDivider()
        ToggleRow("Stereo Width", Icons.Filled.SurroundSound, rig.stereoOn, rig::setStereo)
        if (rig.stereoOn) {
            KnobGrid {
                Knob("Width", rig.stereoWidth, rig::setWidth, 0.0, 100.0, "%", color = c, default = 100.0)
                Knob("Ping-Pong", rig.stereoPingMix, rig::setPingMix, 0.0, 100.0, "%", color = c, default = 25.0)
                Knob("Echo", rig.stereoPingTime, rig::setPingTime, 50.0, 700.0, "ms", color = c, default = 350.0)
                Knob("Feedback", rig.stereoPingFb, rig::setPingFb, 0.0, 85.0, "%", color = c, default = 30.0)
                Knob("Ambience", rig.stereoSpace, rig::setSpace, 0.0, 100.0, "%", color = c, default = 18.0)
            }
            Caption("Mono chain → wide stereo out. Needs headphones or stereo monitors to hear.")
        }
        HorizontalDivider()
        ToggleRow("Dual path  A ∥ B", Icons.Filled.VerticalSplit, rig.dualOn, rig::setDual)
        if (rig.dualOn) {
            KnobGrid {
                Knob("Level A", rig.levelA, rig::setLevelA, -24.0, 12.0, "dB", color = c, default = 0.0)
                Knob("Pan A", rig.panA, rig::setPanA, -1.0, 1.0, "", 2, c, -0.7, true)
                Knob("Level B", rig.levelB, rig::setLevelB, -24.0, 12.0, "dB", color = c, default = 0.0)
                Knob("Pan B", rig.panB, rig::setPanB, -1.0, 1.0, "", 2, c, 0.7, true)
            }
            Caption("Both paths get the guitar; each is a complete chain. Drag tiles between the A and B rows. ~2× CPU.")
        }
        HorizontalDivider()
        MidiOutSection(rig, actions)
    }
}

@Composable
private fun ToggleRow(t: String, icon: androidx.compose.ui.graphics.vector.ImageVector, v: Boolean, set: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
        Text(t, Modifier.weight(1f), fontWeight = FontWeight.Bold, fontSize = 15.sp)
        Switch(v, set, colors = SwitchDefaults.colors(checkedTrackColor = Stage.cyan))
    }
}

@Composable
private fun MidiOutSection(rig: RigEngine, actions: EditorActions) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Output, null, tint = Color(0xFFFF9500)); Spacer(Modifier.width(8.dp))
            Text("MIDI Out (this preset)", Modifier.weight(1f), fontWeight = FontWeight.Bold)
            TextButton({ rig.currentMidiOut = rig.currentMidiOut + MidiOutMessage(kind = "programChange", channel = actions.outChannel()) }) { Text("+ PC") }
            TextButton({ rig.currentMidiOut = rig.currentMidiOut + MidiOutMessage(kind = "controlChange", channel = actions.outChannel(), number = 1, value = 127) }) { Text("+ CC") }
        }
        if (rig.currentMidiOut.isEmpty()) Caption("Messages sent to external pedals/amps when this preset loads.")
        rig.currentMidiOut.forEachIndexed { i, m ->
            fun upd(f: (MidiOutMessage) -> MidiOutMessage) { rig.currentMidiOut = rig.currentMidiOut.toMutableList().also { it[i] = f(it[i]) } }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(if (m.kind == "programChange") "PC" else "CC", fontWeight = FontWeight.Bold, modifier = Modifier.width(26.dp)
                    .clickable { upd { it.copy(kind = if (it.kind == "programChange") "controlChange" else "programChange") } })
                Stepper("ch", m.channel, 1..16) { v -> upd { it.copy(channel = v) } }
                Stepper("#", m.number, 0..127) { v -> upd { it.copy(number = v) } }
                if (m.kind == "controlChange") Stepper("=", m.value, 0..127) { v -> upd { it.copy(value = v) } }
                Spacer(Modifier.weight(1f))
                IconButton({ actions.sendMidi(m) }, Modifier.size(32.dp)) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = Color(0xFFFF9500)) }
                IconButton({ rig.currentMidiOut = rig.currentMidiOut.toMutableList().also { it.removeAt(i) } }, Modifier.size(32.dp)) { Icon(Icons.Filled.RemoveCircleOutline, "Remove") }
            }
        }
    }
}

@Composable
fun Stepper(label: String, v: Int, range: IntRange, set: (Int) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("$label", fontSize = 11.sp, color = Color.Gray)
        Text("−", Modifier.clickable { set((v - 1).coerceIn(range)) }.padding(horizontal = 5.dp), fontSize = 16.sp, fontWeight = FontWeight.Bold)
        Text("$v", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        Text("+", Modifier.clickable { set((v + 1).coerceIn(range)) }.padding(horizontal = 5.dp), fontSize = 16.sp, fontWeight = FontWeight.Bold)
    }
}

// ------------------------------------------------------------------ LOOP
@Composable
fun LooperEditor(rig: RigEngine) {
    val dark = LocalDark.current
    val g = Color(0xFF34C759)
    Column(Modifier.fillMaxWidth().chassis(g, dark).padding(16.dp).padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Repeat, null, tint = g); Spacer(Modifier.width(8.dp)); Nameplate("Looper"); Spacer(Modifier.weight(1f))
            Text(rig.looperStateLabel, fontWeight = FontWeight.Bold, color = Color.Gray)
        }
        val (txt, icon) = when (rig.looperStateLabel) {
            "REC" -> "Stop & Play" to Icons.Filled.StopCircle
            "Play" -> "Overdub" to Icons.Filled.AddCircle
            "Overdub" -> "Stop Dub" to Icons.Filled.AddCircle
            "Stopped" -> "Play" to Icons.Filled.PlayArrow
            else -> (if (rig.looperHasLoop) "Play" else "Record") to (if (rig.looperHasLoop) Icons.Filled.PlayArrow else Icons.Filled.FiberManualRecord)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(rig::looperToggle, Modifier.weight(1f), colors = ButtonDefaults.buttonColors(containerColor = g)) { Icon(icon, null); Text(" $txt") }
            OutlinedButton(rig::looperStop) { Icon(Icons.Filled.Stop, "Stop") }
            OutlinedButton(rig::looperClear) { Icon(Icons.Filled.Delete, "Clear", tint = Color(0xFFFF3B30)) }
        }
        KnobGrid { Knob("Loop Level", rig.loopLevel, rig::setLoopLevel, 0.0, 100.0, "%", color = g, default = 100.0) }
        Caption("Records the full rig (after both paths). One button: Record → Play → Overdub. Map a footswitch in MIDI.")
    }
}

@Suppress("unused") private val unusedPathRef = PathId.A
