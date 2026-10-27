package com.avrahamohana.headroom.ui

import android.Manifest
import android.annotation.SuppressLint
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Piano
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.avrahamohana.headroom.engine.RigEngine
import com.avrahamohana.headroom.midi.MidiController
import com.avrahamohana.headroom.model.BlockKind
import com.avrahamohana.headroom.model.MidiParam
import com.avrahamohana.headroom.model.PathId

@SuppressLint("MissingPermission")
@Composable
fun MidiSheet(rig: RigEngine, midi: MidiController, onDone: () -> Unit) {
    val blePerms = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r -> if (r.values.all { it }) midi.startBleScan() }
    Sheet("MIDI", onDone) {
        Box {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Title("Devices")
                if (midi.devices.isEmpty()) Text("No MIDI devices connected (USB or Bluetooth).", color = Color.Gray)
                midi.devices.forEach { Row(verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Filled.Piano, null, Modifier.size(18.dp)); Text("  $it") } }
                OutlinedButton({
                    val perms = if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
                                else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
                    blePerms.launch(perms)
                }) { Icon(Icons.Filled.Bluetooth, null); Text(if (midi.bleScanning) " Scanning…" else " Find Bluetooth MIDI pedals") }
                midi.bleFound.forEach { d ->
                    Row(Modifier.fillMaxWidth().clickable { midi.connectBle(d) }.padding(vertical = 6.dp)) {
                        Text(runCatching { d.name }.getOrNull() ?: d.address, Modifier.weight(1f)); Text("Connect", color = MaterialTheme.colorScheme.primary)
                    }
                }
                Row { Text("Last received", Modifier.weight(1f), color = Color.Gray, fontSize = 13.sp); Text(midi.lastMessage, fontSize = 13.sp, color = if (midi.activity > 0) Color(0xFF34C759) else Color.Gray) }
                midi.externalBpm?.let { Row { Text("External clock", Modifier.weight(1f), color = Color.Gray, fontSize = 13.sp); Text("${it.toInt()} BPM", fontSize = 13.sp) } }

                Title("Input")
                Pick("Listen on channel", midi.channelFilter?.toString() ?: "Omni", listOf("Omni") + (1..16).map { "$it" }) { midi.setChannelFilter(if (it == 0) null else it) }
                Toggle("Bank Select (CC0/32) + PC", midi.bankSelect, midi::setBankSelect)
                Toggle("Follow MIDI clock (tempo)", midi.clockInSync, midi::setClockIn)
                Pick("Knob / switch mappings act on", when (rig.midiPath) { PathId.A -> "Path A"; PathId.B -> "Path B"; null -> "Selected path" },
                    listOf("Path A", "Path B", "Selected path")) { rig.midiPath = listOf(PathId.A, PathId.B, null)[it] }
                Text("Program Change selects preset 1–${maxOf(rig.presets.size, 1)}.", fontSize = 12.sp, color = Color.Gray)

                Title("Output")
                Pick("Send on channel", "${midi.outChannel}", (1..16).map { "$it" }) { midi.setOutChannel(it + 1) }
                Toggle("Program Change on preset load", midi.sendPCOnPresetLoad, midi::setSendPC)
                Toggle("CC feedback (knob → controller)", midi.sendCCFeedback, midi::setSendFeedback)
                Toggle("Send MIDI clock (tap tempo)", midi.sendClock, midi::setSendClock)
                Row { Text("Last sent", Modifier.weight(1f), color = Color.Gray, fontSize = 13.sp); Text(midi.lastSent, fontSize = 13.sp) }

                Title("Mappings")
                if (midi.mappings.isEmpty()) Text("No mappings yet. Add one, then press a footswitch / move a pedal to learn it.", fontSize = 12.sp, color = Color.Gray)
                midi.mappings.forEach { m ->
                    Column(Modifier.padding(vertical = 4.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(m.label, Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                            Text(if (m.source == "note") "Note ${m.cc}" else "CC ${m.cc}", color = Color.Gray, fontSize = 13.sp)
                            IconButton({ midi.removeMapping(m.id) }) { Icon(Icons.Filled.Delete, "Delete mapping") }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Stepper("#", m.cc, 0..127) { midi.updateMapping(m.copy(cc = it)) }
                            if (m.isSwitch) Segmented(listOf("Press", "Latch"), if (m.momentary) 0 else 1, { midi.updateMapping(m.copy(momentary = it == 0)) }).let { }
                            Spacer(Modifier.weight(1f))
                            OutlinedButton({ midi.learnId = m.id }, contentPadding = PaddingValues(horizontal = 10.dp)) { Text("Learn") }
                        }
                    }
                    HorizontalDivider()
                }
                AddMappingMenu(midi)
            }
            if (midi.learnId != null) AlertDialog({ midi.learnId = null }, title = { Text("MIDI Learn") },
                text = { Text("Press a footswitch or move a pedal to learn it.") },
                confirmButton = { TextButton({ midi.learnId = null }) { Text("Cancel") } })
        }
    }
}

@Composable
private fun AddMappingMenu(midi: MidiController) {
    var open by remember { mutableStateOf(0) }   // 0 closed · 1 main · 2 params · 3 blocks
    Box {
        Button({ open = 1 }) { Text("+ Add mapping") }
        DropdownMenu(open != 0, { open = 0 }) {
            when (open) {
                1 -> {
                    listOf("Next preset" to "presetNext", "Previous preset" to "presetPrev", "Looper REC / Play / Dub" to "looper",
                        "Looper stop" to "looperStop", "Tap tempo" to "tapTempo", "Mute" to "mute", "Tuner" to "tuner").forEach { (l, t) ->
                        DropdownMenuItem({ Text(l) }, { open = 0; midi.addMapping(t) })
                    }
                    HorizontalDivider()
                    DropdownMenuItem({ Text("Parameter / expression ›") }, { open = 2 })
                    DropdownMenuItem({ Text("Block on/off ›") }, { open = 3 })
                }
                2 -> MidiParam.entries.forEach { p -> DropdownMenuItem({ Text(p.label) }, { open = 0; midi.addMapping("param:${p.name}") }) }
                3 -> BlockKind.entries.forEach { k -> DropdownMenuItem({ Text(k.raw) }, { open = 0; midi.addMapping("block:${k.raw}") }) }
            }
        }
    }
}

@Composable private fun Title(t: String) = Text(t.uppercase(), fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color.Gray, modifier = Modifier.padding(top = 12.dp))
@Composable private fun Toggle(t: String, v: Boolean, set: (Boolean) -> Unit) =
    Row(verticalAlignment = Alignment.CenterVertically) { Text(t, Modifier.weight(1f)); Switch(v, set) }
@Composable
private fun Pick(label: String, current: String, options: List<String>, onPick: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 8.dp)) { Text(label, Modifier.weight(1f)); Text(current, fontWeight = FontWeight.SemiBold) }
        DropdownMenu(open, { open = false }) { options.forEachIndexed { i, o -> DropdownMenuItem({ Text(o) }, { open = false; onPick(i) }) } }
    }
}
