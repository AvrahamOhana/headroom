package com.avrahamohana.headroom.ui

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.avrahamohana.headroom.R
import com.avrahamohana.headroom.engine.RigEngine
import com.avrahamohana.headroom.midi.MidiController
import com.avrahamohana.headroom.model.BlockKind
import com.avrahamohana.headroom.t3k.T3KBrowser
import com.avrahamohana.headroom.t3k.T3KClient
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(rig: RigEngine, midi: MidiController, t3k: T3KClient) {
    var selectedId by remember { mutableStateOf<String?>(null) }
    var panel by remember { mutableStateOf(Panel.NONE) }
    var sheet by remember { mutableStateOf<String?>(null) }          // tuner|settings|presets|models|midi|reorder
    var showLive by remember { mutableStateOf(false) }
    var showSave by remember { mutableStateOf(false) }
    var t3kTarget by remember { mutableStateOf<Pair<String, String>?>(null) }   // target, instId
    var splash by remember { mutableStateOf(true) }
    val ctx = LocalContext.current

    LaunchedEffect(Unit) { delay(1800); splash = false }
    LaunchedEffect(rig.running) { if (rig.running) { delay(300); splash = false } }
    LaunchedEffect(rig.tunerRequested) { if (rig.tunerRequested) sheet = "tuner" else if (sheet == "tuner") sheet = null }

    // ---- pickers
    var pendingModel by remember { mutableStateOf<Pair<BlockKind, String>?>(null) }
    val namPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        val (kind, id) = pendingModel ?: return@rememberLauncherForActivityResult
        if (uri != null) rig.importModel(uri)?.let { mid ->
            if (kind == BlockKind.PEDAL) rig.updateParams(id) { it.copy(pedalModel = mid) } else rig.updateParams(id) { it.copy(model = mid) }
        }
    }
    var pendingIR by remember { mutableStateOf<Pair<String, Boolean>?>(null) }
    val irPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        val (id, cab) = pendingIR ?: return@rememberLauncherForActivityResult
        if (uri != null) rig.importIR(uri)?.let { f -> rig.updateParams(id, reloadAssets = true) { if (cab) it.copy(cabIR = f) else it.copy(irReverbIR = f) } }
    }
    val actions = remember {
        EditorActions(
            importModel = { k, id -> pendingModel = k to id; namPicker.launch(arrayOf("*/*")) },
            browse = { t, id -> t3kTarget = t to id },
            pickIR = { id, cab -> pendingIR = id to cab; irPicker.launch(arrayOf("audio/*", "audio/wav", "audio/x-wav")) },
            manageModels = { sheet = "models" },
            sendMidi = { midi.send(it) },
            outChannel = { midi.outChannel },
        )
    }

    StageBackground(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Header(rig, midi, onLive = { showLive = true }, onTuner = { sheet = "tuner" }, onMidi = { sheet = "midi" }, onSettings = { sheet = "settings" })
            SignalStrip(rig)
            PresetBar(rig, onManage = { sheet = "presets" }, onSave = { showSave = true })
            ChainStrip(rig, selectedId, panel, { selectedId = it }, { panel = it }, { sheet = "reorder" })
            val sid = selectedId
            when {
                sid != null && rig.instance(sid) != null -> BlockEditor(rig, sid, actions) { selectedId = null }
                panel == Panel.OUTPUT -> OutputEditor(rig, actions)
                panel == Panel.LOOPER -> LooperEditor(rig)
            }
            rig.lastError?.let { Text(it, color = Color(0xFFFF3B30), fontSize = 13.sp, modifier = Modifier.fillMaxWidth()) }
            if (rig.running && !rig.hasUsbInput()) Text("No USB audio interface — using the phone's mic. Use headphones (the speaker will feed back).",
                fontSize = 12.sp, color = Color(0xFFFF9500))
            if (!rig.running) Text("Audio is off. Tap the power button to start. Connect a USB audio interface for your guitar.",
                fontSize = 12.sp, color = Color.Gray)
        }
        if (showLive) LiveScreen(rig, onExit = { showLive = false }, onTuner = { showLive = false; sheet = "tuner" })
        AnimatedVisibility(splash, exit = fadeOut()) { Splash() }
    }

    if (showSave) {
        var name by remember { mutableStateOf("") }
        AlertDialog({ showSave = false }, title = { Text("Save preset") },
            text = { OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true) },
            confirmButton = { TextButton({ rig.saveCurrentAs(name); showSave = false }) { Text("Save") } },
            dismissButton = { TextButton({ showSave = false }) { Text("Cancel") } })
    }
    when (sheet) {
        "tuner" -> TunerSheet(rig) { sheet = null; rig.tunerRequested = false }
        "settings" -> SettingsSheet(rig, t3k) { sheet = null }
        "presets" -> SetlistSheet(rig) { sheet = null }
        "models" -> ModelsSheet(rig) { sheet = null }
        "reorder" -> ReorderSheet(rig) { sheet = null }
        "midi" -> MidiSheet(rig, midi) { sheet = null }
    }
    t3kTarget?.let { (target, id) ->
        T3KBrowser(rig, t3k, target, onDownloaded = { file, name, gear, art ->
            when (target) {
                "cab" -> { val f = rig.importIR(file, name); rig.updateParams(id, reloadAssets = true) { it.copy(cabIR = f) } }
                "pedal" -> rig.importModel(file, name, gear, art)?.let { mid -> rig.updateParams(id) { it.copy(pedalModel = mid) } }
                else -> rig.importModel(file, name, gear, art)?.let { mid -> rig.updateParams(id) { it.copy(model = mid) } }
            }
        }) { t3kTarget = null }
    }
    @Suppress("UNUSED_VARIABLE") val unused = ctx
}

@Composable
private fun Splash() {
    Box(Modifier.fillMaxSize().background(Color(0xFF0E0E10)), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Image(painterResource(R.drawable.launch_logo), "Headroom", Modifier.size(200.dp).shadow(24.dp, RoundedCornerShape(44.dp)).clip(RoundedCornerShape(44.dp)))
            Text("Headroom", fontSize = 30.sp, fontWeight = FontWeight.Black, color = Color.White)
            Text("AMP & FX", fontSize = 12.sp, fontWeight = FontWeight.Black, letterSpacing = 4.sp, color = Color.White.copy(alpha = 0.55f))
            CircularProgressIndicator(Modifier.size(22.dp), color = Color.White.copy(alpha = 0.6f), strokeWidth = 2.dp)
        }
    }
}

@Composable
private fun Header(rig: RigEngine, midi: MidiController, onLive: () -> Unit, onTuner: () -> Unit, onMidi: () -> Unit, onSettings: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Led(rig.running, size = 9.dp)
        Text(" Headroom", fontSize = 20.sp, fontWeight = FontWeight.Black, maxLines = 1, softWrap = false)
        Spacer(Modifier.weight(1f))
        Row(Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)).clickable(onClick = onLive).semantics { contentDescription = "Live view" }.padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Tv, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
            Text(" Live", fontWeight = FontWeight.Bold, fontSize = 14.sp, color = MaterialTheme.colorScheme.primary)
        }
        IconButton(onTuner) { Icon(Icons.Filled.MusicNote, "Tuner") }
        IconButton(onMidi) {
            BadgedBox(badge = { if (midi.activity > 0) Badge(containerColor = Color(0xFF34C759), modifier = Modifier.size(6.dp)) }) { Icon(Icons.Filled.Piano, "MIDI") }
        }
        IconButton(onSettings) { Icon(Icons.Filled.Settings, "Settings") }
        IconButton(rig::toggle) {
            Icon(Icons.Filled.PowerSettingsNew, if (rig.running) "Stop audio" else "Start audio", Modifier.size(28.dp),
                tint = if (rig.running) Color(0xFF34C759) else Color.Gray)
        }
    }
}

@Composable
fun SignalStrip(rig: RigEngine) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        for ((l, db) in listOf("IN" to rig.inPeakDb, "OUT" to rig.outPeakDb)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(l, fontSize = 10.sp, fontWeight = FontWeight.Black, color = Color.Gray)
                LedMeter(db, Modifier.width(64.dp), segments = 12, height = 6.dp)
            }
        }
        val cpu = rig.cpuPercent
        Led(true, if (cpu > 80) Color(0xFFFF3B30) else if (cpu > 50) Color(0xFFFF9500) else Color(0xFF34C759), 7.dp)
        Text("$cpu%", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = if (cpu > 80) Color(0xFFFF3B30) else Color.Gray)
    }
}

@Composable
private fun PresetBar(rig: RigEngine, onManage: () -> Unit, onSave: () -> Unit) {
    val dark = LocalDark.current
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().chassis(Color.Gray.copy(alpha = 0.5f), dark, 3.dp).padding(horizontal = 10.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        IconButton(rig::prevPreset) { Icon(Icons.Filled.ChevronLeft, "Previous preset", Modifier.size(32.dp)) }
        DisplayPanel(Modifier.weight(1f), 8.dp) {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(rig.presetTag, fontSize = 16.sp, fontWeight = FontWeight.Black, color = Color.White,
                        modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(sceneColor(rig.sceneInBank)).padding(horizontal = 7.dp, vertical = 1.dp))
                    Text(rig.currentPresetName, fontSize = 24.sp, fontWeight = FontWeight.ExtraBold, color = Stage.displayInk, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text("PRESET ${rig.currentPresetIndex + 1}/${rig.presets.size}", fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp,
                    color = Stage.displayInk.copy(alpha = 0.6f))
            }
        }
        IconButton(rig::nextPreset) { Icon(Icons.Filled.ChevronRight, "Next preset", Modifier.size(32.dp)) }
        Box {
            IconButton({ menu = true }) { Icon(Icons.AutoMirrored.Filled.List, "Preset menu") }
            DropdownMenu(menu, { menu = false }) {
                DropdownMenuItem({ Text("Setlist / Manage…") }, { menu = false; onManage() }, leadingIcon = { Icon(Icons.Filled.QueueMusic, null) })
                HorizontalDivider()
                DropdownMenuItem({ Text("Save as new…") }, { menu = false; onSave() }, leadingIcon = { Icon(Icons.Filled.Add, null) })
                DropdownMenuItem({ Text("Overwrite current") }, { menu = false; rig.overwriteCurrent() }, leadingIcon = { Icon(Icons.Filled.Save, null) })
                HorizontalDivider()
                rig.presets.forEachIndexed { i, p -> DropdownMenuItem({ Text(p.name) }, { menu = false; rig.loadPreset(i) }) }
            }
        }
    }
}

// ------------------------------------------------------------------ sheets
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Sheet(title: String, onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    ModalBottomSheet(onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                TextButton(onDismiss) { Text("Done") }
            }
            content()
        }
    }
}

@Composable
private fun TunerSheet(rig: RigEngine, onDone: () -> Unit) {
    DisposableEffect(Unit) { val was = rig.muted; rig.setMuted(true); onDispose { rig.setMuted(was) } }
    val active = rig.tunerActive; val cents = rig.tunerCents; val inTune = active && kotlin.math.abs(cents) <= 5
    Sheet("Tuner", onDone) {
        Column(Modifier.fillMaxWidth().padding(vertical = 24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Text(if (active) rig.tunerNote else "—", fontSize = 72.sp, fontWeight = FontWeight.Bold, color = if (inTune) Color(0xFF34C759) else MaterialTheme.colorScheme.onSurface)
            BoxWithConstraints(Modifier.fillMaxWidth().height(36.dp).padding(horizontal = 30.dp)) {
                val w = maxWidth
                Box(Modifier.fillMaxWidth().height(6.dp).align(Alignment.Center).clip(CircleShape).background(Color.Black.copy(alpha = 0.2f)))
                Box(Modifier.width(2.dp).height(26.dp).align(Alignment.Center).background(Color.Gray))
                if (active) {
                    val x = (w - 22.dp) * ((cents.coerceIn(-50, 50) + 50) / 100f)
                    Box(Modifier.offset(x = x).size(22.dp).align(Alignment.CenterStart).clip(CircleShape).background(if (inTune) Color(0xFF34C759) else Color(0xFFFF9500)))
                }
            }
            Text(if (active) "${if (cents > 0) "+" else ""}$cents¢" else if (rig.running) "play a single note" else "engine off",
                fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = if (inTune) Color(0xFF34C759) else Color.Gray)
        }
    }
}

@Composable
private fun SettingsSheet(rig: RigEngine, t3k: T3KClient, onDone: () -> Unit) {
    var showAck by remember { mutableStateOf(false) }
    Sheet("Settings", onDone) {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SectionTitle("Audio")
            DevicePicker("Input device", rig.inputDeviceName, rig.devices(true).map { rig.deviceLabel(it) }, rig::setInputDevice)
            DevicePicker("Output device", rig.outputDeviceName, rig.devices(false).map { rig.deviceLabel(it) }, rig::setOutputDevice)
            Text("Default picks your USB interface when one is connected. Use the same interface for in and out.", fontSize = 12.sp, color = Color.Gray)
            val a = rig.audioInfo
            InfoRow("Sample rate", if (a.sampleRate > 0) "${a.sampleRate} Hz" else "—")
            InfoRow("Buffer", if (a.bufferFrames > 0) "${a.bufferFrames} frames · %.1f ms (burst ${a.burst})".format(a.bufferMs) else "—")
            InfoRow("Reported I/O latency", if (a.latencyMs > 0) "%.1f ms".format(a.latencyMs) else "—")
            InfoRow("Path", if (a.sampleRate > 0) listOfNotNull(if (a.lowLatency) "low-latency" else "normal", if (a.exclusive) "exclusive" else "shared", if (a.mmap) "MMAP" else null).joinToString(" · ") else "—")
            InfoRow("Glitches", "${a.underruns}")
            Text("Latency / stability", fontWeight = FontWeight.SemiBold)
            Segmented(listOf("Lowest", "Balanced", "Safe"), when (rig.burstsPerBuffer) { 1 -> 0; 2 -> 1; else -> 2 }, { rig.setBursts(listOf(1, 2, 4)[it]) })
            SectionTitle("Appearance")
            Segmented(listOf("System", "Light", "Dark"), rig.appearance, rig::setAppearance)
            SectionTitle("Performance")
            InfoRow("CPU (DSP load)", "${rig.cpuPercent}%")
            LinearProgressIndicator({ (rig.cpuPercent / 100f).coerceIn(0f, 1f) }, Modifier.fillMaxWidth(),
                color = if (rig.cpuPercent > 80) Color(0xFFFF3B30) else if (rig.cpuPercent > 50) Color(0xFFFF9500) else Color(0xFF34C759))
            SectionTitle("TONE3000")
            if (t3k.isLoggedIn) Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.CheckCircle, null, tint = Color(0xFF34C759)); Text(" Connected", Modifier.weight(1f))
                TextButton(t3k::logout) { Text("Log out") }
            } else Text("Not connected. Use Amp → Browse TONE3000 to log in.", fontSize = 12.sp, color = Color.Gray)
            SectionTitle("Legal")
            TextButton({ showAck = !showAck }) { Text(if (showAck) "Hide acknowledgements" else "Acknowledgements") }
            if (showAck) Text(ACKNOWLEDGEMENTS, fontSize = 11.sp)
        }
    }
}

@Composable private fun SectionTitle(t: String) = Text(t.uppercase(), fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color.Gray, modifier = Modifier.padding(top = 10.dp))
@Composable private fun InfoRow(l: String, v: String) = Row { Text(l, Modifier.weight(1f), color = Color.Gray); Text(v, fontWeight = FontWeight.SemiBold) }

@Composable
private fun DevicePicker(label: String, current: String?, options: List<String>, set: (String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 6.dp)) {
            Text(label, Modifier.weight(1f)); Text(current ?: "Automatic", fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 220.dp))
        }
        DropdownMenu(open, { open = false }) {
            DropdownMenuItem({ Text("Automatic") }, { open = false; set(null) })
            options.distinct().forEach { o -> DropdownMenuItem({ Text(o) }, { open = false; set(o) }) }
        }
    }
}

@Composable
private fun SetlistSheet(rig: RigEngine, onDone: () -> Unit) {
    var renameIdx by remember { mutableStateOf<Int?>(null) }
    Sheet("Setlist", onDone) {
        LazyColumn(Modifier.heightIn(max = 560.dp)) {
            itemsIndexed(rig.presets, key = { _, p -> p.id }) { i, p ->
                var menu by remember { mutableStateOf(false) }
                Row(Modifier.fillMaxWidth().clickable { rig.loadPreset(i); onDone() }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(rig.tag(i), fontSize = 13.sp, fontWeight = FontWeight.Black, color = Color.White,
                        modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(sceneColor(i % 4)).padding(horizontal = 7.dp, vertical = 2.dp))
                    Text(p.name, Modifier.weight(1f), fontWeight = if (i == rig.currentPresetIndex) FontWeight.Bold else FontWeight.Normal)
                    if (i == rig.currentPresetIndex) Icon(Icons.Filled.VolumeUp, null, Modifier.size(16.dp), tint = Color(0xFF34C759))
                    IconButton({ rig.movePreset(i, i - 1) }, enabled = i > 0) { Icon(Icons.Filled.KeyboardArrowUp, "Move up") }
                    IconButton({ rig.movePreset(i, i + 1) }, enabled = i < rig.presets.size - 1) { Icon(Icons.Filled.KeyboardArrowDown, "Move down") }
                    Box {
                        IconButton({ menu = true }) { Icon(Icons.Filled.MoreVert, "More") }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem({ Text("Rename") }, { menu = false; renameIdx = i })
                            DropdownMenuItem({ Text("Duplicate") }, { menu = false; rig.duplicatePreset(i) })
                            DropdownMenuItem({ Text("Delete", color = Color(0xFFFF3B30)) }, { menu = false; rig.deletePreset(i) }, enabled = rig.presets.size > 1)
                        }
                    }
                }
                HorizontalDivider()
            }
        }
        Text("Tap to load. The tags (0A–0D, 1A…) and MIDI Program numbers follow this order.", fontSize = 12.sp, color = Color.Gray, modifier = Modifier.padding(top = 8.dp))
    }
    renameIdx?.let { i ->
        var t by remember { mutableStateOf(rig.presets.getOrNull(i)?.name ?: "") }
        AlertDialog({ renameIdx = null }, title = { Text("Rename preset") }, text = { OutlinedTextField(t, { t = it }, singleLine = true) },
            confirmButton = { TextButton({ rig.renamePreset(i, t); renameIdx = null }) { Text("Save") } },
            dismissButton = { TextButton({ renameIdx = null }) { Text("Cancel") } })
    }
}

@Composable
private fun ModelsSheet(rig: RigEngine, onDone: () -> Unit) {
    Sheet("Models", onDone) {
        SectionTitle("Downloaded / imported")
        val dl = rig.models.filter { !it.bundled }
        if (dl.isEmpty()) Text("None yet — import a .nam or download from TONE3000.", color = Color.Gray)
        dl.forEach { m ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(m.name, Modifier.weight(1f)); IconButton({ rig.deleteModel(m.id) }) { Icon(Icons.Filled.Delete, "Delete ${m.name}") }
            }
        }
        SectionTitle("Built-in")
        rig.models.filter { it.bundled }.forEach { Text(it.name, color = Color.Gray, modifier = Modifier.padding(vertical = 6.dp)) }
    }
}

@Composable
private fun ReorderSheet(rig: RigEngine, onDone: () -> Unit) {
    val pid = rig.focusPath
    Sheet(if (rig.dualOn) "Chain Order · Path ${pid.label}" else "Chain Order", onDone) {
        val list = rig.path(pid).blocks
        list.forEachIndexed { i, inst ->
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(inst.k.icon, null, tint = if (inst.isOn) inst.k.color else Color.Gray)
                Text(rig.label(inst.id)?.let { "${inst.k.full} $it" } ?: inst.k.full, Modifier.weight(1f))
                IconButton({ rig.reorder(pid, list.map { it.id }.toMutableList().also { java.util.Collections.swap(it, i, i - 1) }) }, enabled = i > 0) { Icon(Icons.Filled.KeyboardArrowUp, "Move up") }
                IconButton({ rig.reorder(pid, list.map { it.id }.toMutableList().also { java.util.Collections.swap(it, i, i + 1) }) }, enabled = i < list.size - 1) { Icon(Icons.Filled.KeyboardArrowDown, "Move down") }
                IconButton({ rig.removeInstance(inst.id) }) { Icon(Icons.Filled.Delete, "Remove") }
            }
        }
        Text("Signal flows top → bottom (IN → OUT). Any block can appear more than once.", fontSize = 12.sp, color = Color.Gray)
    }
}

const val ACKNOWLEDGEMENTS = """NeuralAmpModelerCore — https://github.com/sdatkinson/NeuralAmpModelerCore
AudioDSPTools — https://github.com/sdatkinson/AudioDSPTools
MIT License · Copyright (c) 2023 Steven Atkinson

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Eigen — https://eigen.tuxfamily.org — MPL-2.0, used unmodified. https://www.mozilla.org/MPL/2.0/

Oboe — https://github.com/google/oboe — Apache License 2.0.

Headroom is free software under the GNU GPL v3."""

@Suppress("unused") private fun unusedIntent() = Intent()
