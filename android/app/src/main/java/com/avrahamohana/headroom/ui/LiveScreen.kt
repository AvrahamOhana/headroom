package com.avrahamohana.headroom.ui

import android.app.Activity
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import com.avrahamohana.headroom.engine.RigEngine
import com.avrahamohana.headroom.model.PathId

/** Full-screen stage view: huge preset name, neighbours, tuner, mini chain, big prev/next. Screen stays awake. */
@Composable
fun LiveScreen(rig: RigEngine, onExit: () -> Unit, onTuner: () -> Unit) {
    val activity = LocalContext.current as? Activity
    DisposableEffect(Unit) {
        activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }
    val haptic = LocalHapticFeedback.current
    run {
        BackHandler(onBack = onExit)
        StageBackground(Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { } }) {
            Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    SignalStrip(rig)
                    Spacer(Modifier.weight(1f))
                    IconButton(rig::toggleMute) { Icon(if (rig.muted) Icons.Filled.VolumeOff else Icons.Filled.VolumeUp, if (rig.muted) "Unmute" else "Mute", tint = if (rig.muted) Color(0xFFFF3B30) else Color.Gray) }
                    Led(rig.running, size = 11.dp)
                    IconButton(onExit) { Icon(Icons.Filled.Cancel, "Exit live view", tint = Color.Gray) }
                }
                Spacer(Modifier.weight(1f))
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(rig.presetTag, fontSize = 40.sp, fontWeight = FontWeight.Black, color = Color.White,
                        modifier = Modifier.clip(RoundedCornerShape(12.dp)).background(sceneColor(rig.sceneInBank)).padding(horizontal = 14.dp, vertical = 5.dp))
                    Text(rig.currentPresetName, fontSize = 72.sp, fontWeight = FontWeight.Black, maxLines = 1, overflow = TextOverflow.Ellipsis, lineHeight = 76.sp)
                }
                Text("PRESET ${rig.currentPresetIndex + 1} / ${maxOf(rig.presets.size, 1)}", fontFamily = FontFamily.Monospace, fontSize = 18.sp,
                    color = Color.Gray, modifier = Modifier.padding(top = 10.dp).align(Alignment.CenterHorizontally))
                if (rig.presets.size > 1) Row(Modifier.fillMaxWidth().padding(top = 10.dp)) {
                    Neighbor(rig, rig.currentPresetIndex - 1, false); Spacer(Modifier.weight(1f)); Neighbor(rig, rig.currentPresetIndex + 1, true)
                }
                Spacer(Modifier.weight(1f))
                Row(Modifier.align(Alignment.CenterHorizontally).clip(CircleShape).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f))
                    .clickable(onClick = onTuner).padding(horizontal = 22.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.MusicNote, null); Text(" Tuner", fontWeight = FontWeight.SemiBold)
                }
                Spacer(Modifier.height(12.dp))
                for (pid in if (rig.dualOn) PathId.entries else listOf(PathId.A)) {
                    Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (rig.dualOn) Text(pid.label, fontSize = 11.sp, fontWeight = FontWeight.Black, color = Color.Gray, modifier = Modifier.width(14.dp))
                        for (inst in rig.path(pid).blocks) {
                            val on = inst.isOn
                            Column(Modifier.size(40.dp, 42.dp).clip(RoundedCornerShape(8.dp))
                                .background(if (on) Brush.verticalGradient(listOf(inst.k.color, inst.k.color.copy(alpha = 0.75f))) else Brush.verticalGradient(listOf(Color.Gray.copy(alpha = 0.2f), Color.Gray.copy(alpha = 0.2f))))
                                .clickable { rig.setEnabled(inst.id, !on); haptic.performHapticFeedback(HapticFeedbackType.LongPress) },
                                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                                Icon(inst.k.icon, inst.k.full, Modifier.size(15.dp), tint = if (on) Color.White else Color.Gray)
                                Text(inst.k.short, fontSize = 7.sp, fontWeight = FontWeight.Black, color = if (on) Color.White else Color.Gray)
                            }
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    NavButton(Icons.Filled.ChevronLeft, "Previous preset", Modifier.weight(1f)) { haptic.performHapticFeedback(HapticFeedbackType.LongPress); rig.prevPreset() }
                    NavButton(Icons.Filled.ChevronRight, "Next preset", Modifier.weight(1f)) { haptic.performHapticFeedback(HapticFeedbackType.LongPress); rig.nextPreset() }
                }
            }
        }
    }
}

@Composable
private fun Neighbor(rig: RigEngine, idx: Int, trailing: Boolean) {
    val n = rig.presets.size
    val wi = ((idx % n) + n) % n
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        if (!trailing) Icon(Icons.Filled.ChevronLeft, null, tint = Color.Gray)
        Text(rig.tag(wi), fontSize = 14.sp, fontWeight = FontWeight.Black, color = Color.White,
            modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(sceneColor(wi % 4).copy(alpha = 0.85f)).padding(horizontal = 6.dp, vertical = 1.dp))
        Text(rig.presets[wi].name, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.Gray, maxLines = 1)
        if (trailing) Icon(Icons.Filled.ChevronRight, null, tint = Color.Gray)
    }
}

@Composable
private fun NavButton(icon: androidx.compose.ui.graphics.vector.ImageVector, desc: String, modifier: Modifier, onClick: () -> Unit) {
    Box(modifier.height(64.dp).clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.1f)).clickable(onClick = onClick),
        contentAlignment = Alignment.Center) { Icon(icon, desc, Modifier.size(34.dp)) }
}
