package com.avrahamohana.headroom.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VerticalSplit
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.avrahamohana.headroom.engine.RigEngine
import com.avrahamohana.headroom.model.BlockInstance
import com.avrahamohana.headroom.model.BlockKind
import com.avrahamohana.headroom.model.PathId
import kotlin.math.abs
import kotlin.math.roundToInt

enum class Panel { NONE, OUTPUT, LOOPER }

private val addGroups = listOf(
    "Dynamics" to listOf(BlockKind.GATE, BlockKind.COMP),
    "Gain" to listOf(BlockKind.BOOST, BlockKind.DRIVE, BlockKind.STOMP, BlockKind.WAH, BlockKind.PEDAL),
    "Amp & Cab" to listOf(BlockKind.AMP, BlockKind.CAB),
    "Tone & Modulation" to listOf(BlockKind.EQ, BlockKind.CHORUS, BlockKind.FLANGER, BlockKind.TREMOLO),
    "Time & Space" to listOf(BlockKind.DELAY, BlockKind.REVERB, BlockKind.IR_REVERB),
)

private class DragState(val inst: BlockInstance, val from: PathId) {
    var pos by mutableStateOf(Offset.Zero)      // finger, root coordinates
    var target by mutableStateOf<Pair<PathId, Int>?>(null)
}

@Composable
fun ChainStrip(
    rig: RigEngine, selectedId: String?, panel: Panel,
    onSelect: (String?) -> Unit, onPanel: (Panel) -> Unit, onShowList: () -> Unit,
) {
    val dark = LocalDark.current
    val haptic = LocalHapticFeedback.current
    val tileBounds = remember { mutableStateMapOf<String, Rect>() }
    val rowBounds = remember { mutableStateMapOf<PathId, Rect>() }
    var stripOrigin by remember { mutableStateOf(Offset.Zero) }
    var drag by remember { mutableStateOf<DragState?>(null) }
    val rows = if (rig.dualOn) listOf(PathId.A, PathId.B) else listOf(PathId.A)

    fun retarget(d: DragState) {
        val p = d.pos
        val row = rows.minByOrNull { r -> rowBounds[r]?.let { abs(it.center.y - p.y) } ?: Float.MAX_VALUE } ?: d.from
        if (row != d.from && rig.countOf(row, d.inst.k) >= RigEngine.MAX_PER_KIND) { d.target = null; return }
        val others = rig.path(row).blocks.filter { it.id != d.inst.id }
        val idx = others.count { o -> tileBounds[o.id]?.let { it.center.x < p.x } ?: false }
        val t = row to idx
        if (d.target != t) { if (d.target != null) haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove); d.target = t }
    }
    fun commit(d: DragState) {
        val t = d.target ?: return
        val others = rig.path(t.first).blocks.filter { it.id != d.inst.id }
        val before = others.getOrNull(t.second)?.id
        rig.moveInstance(d.inst.id, t.first, before)
        if (selectedId == d.inst.id) rig.focus(d.inst.id)
    }

    Box(Modifier.fillMaxWidth().onGloballyPositioned { stripOrigin = it.boundsInRoot().topLeft }) {
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("SIGNAL CHAIN", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
            Text(if (rig.dualOn) "hold a tile to drag · rows A and B" else "hold a tile to drag", fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f), modifier = Modifier.weight(1f), maxLines = 1)
            Row(Modifier.clickable { rig.setDual(!rig.dualOn); haptic.performHapticFeedback(HapticFeedbackType.LongPress) }, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.VerticalSplit, null, Modifier.size(16.dp), tint = if (rig.dualOn) Stage.cyan else Color.Gray)
                Text(if (rig.dualOn) " A ∥ B" else " Dual", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = if (rig.dualOn) Stage.cyan else Color.Gray)
            }
            Row(Modifier.clickable { onShowList() }, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.AutoMirrored.Filled.List, null, Modifier.size(16.dp), tint = Color.Gray)
                Text(" List", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color.Gray)
            }
        }
        Spacer(Modifier.height(6.dp))
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp))
            .background(if (dark) Color.Black.copy(alpha = 0.28f) else Color.Black.copy(alpha = 0.10f))
            .border(1.dp, if (dark) Color.White.copy(alpha = 0.06f) else Color.Black.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
            .padding(vertical = 8.dp, horizontal = 6.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                for (pid in rows) {
                    val d = drag
                    Box(Modifier.fillMaxWidth().onGloballyPositioned { rowBounds[pid] = it.boundsInRoot() }
                        .then(if (d?.target?.first == pid) Modifier.border(1.5.dp, Stage.cyan.copy(alpha = 0.5f), RoundedCornerShape(10.dp)) else Modifier)) {
                        if (rig.dualOn && rig.focusPath == pid) Box(Modifier.width(3.dp).height(60.dp).align(Alignment.CenterStart).background(Stage.cyan))
                        Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            EndJack(if (rig.dualOn) pid.label else "IN")
                            val blocks = rig.path(pid).blocks
                            val others = blocks.filter { it.id != d?.inst?.id }
                            var shown = 0
                            for (inst in blocks) {
                                val isDragged = d?.inst?.id == inst.id
                                if (!isDragged && d?.target?.first == pid && d.target?.second == others.indexOf(inst)) InsertMarker()
                                Tile(rig, inst, selected = selectedId == inst.id, dimmed = isDragged,
                                    modifier = Modifier
                                        .onGloballyPositioned { tileBounds[inst.id] = it.boundsInRoot() }
                                        .clickable { rig.focus(inst.id); onSelect(if (selectedId == inst.id) null else inst.id); onPanel(Panel.NONE) }
                                        .pointerInput(inst.id, pid) {
                                            detectDragGesturesAfterLongPress(
                                                onDragStart = { off ->
                                                    val b = tileBounds[inst.id] ?: Rect.Zero
                                                    drag = DragState(inst, pid).also { it.pos = b.topLeft + off; retarget(it) }
                                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                },
                                                onDragEnd = { drag?.let { commit(it) }; drag = null },
                                                onDragCancel = { drag = null },
                                            ) { ch, delta -> ch.consume(); drag?.let { it.pos += delta; retarget(it) } }
                                        })
                                if (!isDragged) shown++
                            }
                            if (d?.target?.first == pid && d.target?.second == others.size) InsertMarker()
                            AddTile(rig, pid) { id -> onSelect(id); onPanel(Panel.NONE) }
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    EndJack(if (rig.dualOn) "A+B" else "")
                    UnitTile("LOOP", Icons.Filled.Repeat, if (rig.looperState != 0) Color(0xFF34C759) else Color(0xFF26733F), panel == Panel.LOOPER,
                        led = rig.looperState != 0, ledColor = Color(0xFFFF3B30)) { onPanel(if (panel == Panel.LOOPER) Panel.NONE else Panel.LOOPER); onSelect(null) }
                    UnitTile("OUT", Icons.Filled.Tune, Color(0xFF2680BF), panel == Panel.OUTPUT, led = rig.running && !rig.muted) {
                        onPanel(if (panel == Panel.OUTPUT) Panel.NONE else Panel.OUTPUT); onSelect(null)
                    }
                }
            }
        }
    }
    // Floating lifted tile follows the finger.
    drag?.let { d ->
        val density = LocalDensity.current
        val half = with(density) { Offset(30.dp.toPx(), 40.dp.toPx()) }
        val p = d.pos - stripOrigin - half
        Box(Modifier.offset { IntOffset(p.x.roundToInt(), p.y.roundToInt()) }.scale(1.08f).alpha(if (d.target == null) 0.5f else 1f)) {
            Tile(rig, d.inst, selected = false, dimmed = false, modifier = Modifier)
        }
    }
    }
}

@Composable private fun InsertMarker() = Box(Modifier.width(4.dp).height(76.dp).clip(RoundedCornerShape(2.dp)).background(Stage.cyan))

@Composable
private fun EndJack(t: String) {
    Column(Modifier.width(26.dp).height(80.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Box(Modifier.size(12.dp).clip(CircleShape).background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.5f), Color.Black.copy(alpha = 0.4f)))),
            contentAlignment = Alignment.Center) { Box(Modifier.size(5.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.7f))) }
        Text(t, fontSize = 9.sp, lineHeight = 11.sp, fontWeight = FontWeight.Black, color = Color.Gray)
    }
}

@Composable
fun Tile(rig: RigEngine, inst: BlockInstance, selected: Boolean, dimmed: Boolean, modifier: Modifier) {
    val k = inst.k
    val on = inst.isOn
    val body = if (on) k.color else Color(0xFF474747)
    val shape = RoundedCornerShape(12.dp)
    val art = remember(rig.artworkFor(inst)) { rig.artworkFor(inst)?.let { runCatching { BitmapFactory.decodeFile(it)?.asImageBitmap() }.getOrNull() } }
    Column(modifier.width(60.dp).height(80.dp).alpha(if (dimmed) 0.25f else 1f).clip(shape)
        .background(Brush.verticalGradient(listOf(body.copy(alpha = 0.95f), body.copy(alpha = 0.7f))))
        .border(if (selected) 2.dp else 1.dp, if (selected) Color.White else Color.White.copy(alpha = 0.3f), shape)
        .semantics { contentDescription = "${k.full}${rig.label(inst.id)?.let { " $it" } ?: ""}, ${if (on) "on" else "off"}" },
        horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.fillMaxWidth().padding(start = 6.dp, end = 6.dp, top = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            Led(on, if (on) Color(0xFF34C759) else Color(0xFFFF3B30), 7.dp)
            Spacer(Modifier.weight(1f))
            Text(rig.label(inst.id) ?: "", fontSize = 8.sp, fontWeight = FontWeight.Black, color = Color.White.copy(alpha = 0.7f))
        }
        Box(Modifier.height(22.dp), contentAlignment = Alignment.Center) {
            if (art != null) Image(art, null, Modifier.width(30.dp).height(22.dp).clip(RoundedCornerShape(4.dp)).alpha(if (on) 1f else 0.4f), contentScale = ContentScale.Crop)
            else Icon(k.icon, null, Modifier.size(20.dp), tint = if (on) Color.White else Color.White.copy(alpha = 0.45f))
        }
        Text(k.short, fontSize = 9.5.sp, lineHeight = 11.sp, fontWeight = FontWeight.Black, color = if (on) Color.White else Color.White.copy(alpha = 0.45f))
        Text(rig.readout(inst), fontSize = 8.sp, lineHeight = 10.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            color = if (on) Stage.displayInk else Color.White.copy(alpha = 0.45f), modifier = Modifier.padding(horizontal = 3.dp))
    }
}

@Composable
private fun AddTile(rig: RigEngine, pid: PathId, onAdded: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val avail = rig.availableToAdd(pid).toSet()
    Box {
        Column(Modifier.width(60.dp).height(80.dp).clip(RoundedCornerShape(12.dp)).background(Color.Gray.copy(alpha = 0.12f))
            .border(1.5.dp, Color.Gray.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
            .clickable(enabled = avail.isNotEmpty()) { open = true }
            .semantics { contentDescription = "Add block to path ${pid.label}" },
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Icon(Icons.Filled.Add, null, tint = Color.Gray)
            Text("ADD", fontSize = 10.sp, fontWeight = FontWeight.Black, color = Color.Gray)
        }
        DropdownMenu(open, { open = false }) {
            addGroups.forEachIndexed { gi, (name, kinds) ->
                val ks = kinds.filter { it in avail }
                if (ks.isNotEmpty()) {
                    if (gi > 0) HorizontalDivider()
                    Text(name.uppercase(), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color.Gray, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
                    ks.forEach { k ->
                        DropdownMenuItem(text = { Text(k.full) }, leadingIcon = { Icon(k.icon, null, tint = k.color) },
                            onClick = { open = false; rig.addBlock(k, pid)?.let(onAdded) })
                    }
                }
            }
        }
    }
}

@Composable
private fun UnitTile(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, c: Color, selected: Boolean,
                     led: Boolean, ledColor: Color = Color(0xFF34C759), onClick: () -> Unit) {
    Box(Modifier.width(60.dp).height(80.dp).clip(RoundedCornerShape(12.dp))
        .background(Brush.verticalGradient(listOf(c.copy(alpha = 0.95f), c.copy(alpha = 0.7f))))
        .border(if (selected) 2.dp else 1.dp, if (selected) Color.White else Color.White.copy(alpha = 0.3f), RoundedCornerShape(12.dp))
        .clickable(onClick = onClick).semantics { contentDescription = label }) {
        Box(Modifier.padding(6.dp)) { Led(led, ledColor, 7.dp) }
        Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, null, tint = Color.White)
            Text(label, fontSize = 10.sp, fontWeight = FontWeight.Black, color = Color.White)
        }
    }
}
