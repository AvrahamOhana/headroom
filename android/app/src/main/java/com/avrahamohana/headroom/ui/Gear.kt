package com.avrahamohana.headroom.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.avrahamohana.headroom.model.BlockKind
import kotlin.math.abs
import kotlin.math.roundToInt

// ------------------------------------------------------------------ palette (Theme.swift)
object Stage {
    val bgTop = Color(0xFF1C1D21); val bgBottom = Color(0xFF0D0D0F)
    val panel = Color(0xFF292A2F); val panelLight = Color(0xFFF7F7FA); val panelLightBottom = Color(0xFFDBDBE0)
    val floorLight = Color(0xFFCCCCD1)
    val display = Color(0xFF0A0D0D); val displayInk = Color(0xFF8CFFBF)
    val cyan = Color(0xFF32ADE6)
}

val LocalDark = staticCompositionLocalOf { true }

@Composable
fun HeadroomTheme(appearance: Int, content: @Composable () -> Unit) {
    val dark = when (appearance) { 1 -> false; 2 -> true; else -> isSystemInDarkTheme() }
    val scheme = if (dark) darkColorScheme(primary = Color(0xFF0A84FF), secondary = Stage.cyan, background = Stage.bgBottom, surface = Color(0xFF1C1C1E))
                 else lightColorScheme(primary = Color(0xFF007AFF), secondary = Stage.cyan)
    // The rig reads left → right like a pedalboard (IN → OUT) in every locale, RTL included.
    CompositionLocalProvider(LocalDark provides dark, androidx.compose.ui.platform.LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Ltr) {
        MaterialTheme(colorScheme = scheme) {
            CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides scheme.onBackground, content = content)
        }
    }
}

fun stageBrush(dark: Boolean) = if (dark) Brush.verticalGradient(listOf(Stage.bgTop, Stage.bgBottom))
    else Brush.verticalGradient(listOf(Stage.floorLight, Color(0xFFB8B8BF)))

val BlockKind.color: Color get() = when (this) {
    BlockKind.GATE -> Color(0xFF30B0C7); BlockKind.COMP -> Color(0xFF0A84FF); BlockKind.BOOST -> Color(0xFFE6B800)
    BlockKind.DRIVE -> Color(0xFFFF9500); BlockKind.STOMP -> Color(0xFFD94D1A); BlockKind.WAH -> Color(0xFF8C59E6)
    BlockKind.PEDAL -> Color(0xFFA2845E); BlockKind.AMP -> Color(0xFFFF3B30); BlockKind.CAB -> Color(0xFF9E6B3D)
    BlockKind.EQ -> Color(0xFF34C759); BlockKind.CHORUS -> Color(0xFF00C7BE); BlockKind.FLANGER -> Color(0xFF5856D6)
    BlockKind.TREMOLO -> Color(0xFFFF2D55); BlockKind.DELAY -> Color(0xFFAF52DE); BlockKind.REVERB -> Color(0xFF32ADE6)
    BlockKind.IR_REVERB -> Color(0xFF32ADE6)
}
val BlockKind.icon: ImageVector get() = when (this) {
    BlockKind.GATE -> Icons.Filled.MonitorHeart; BlockKind.COMP -> Icons.Filled.Compress; BlockKind.BOOST -> Icons.Filled.Bolt
    BlockKind.DRIVE -> Icons.Filled.LocalFireDepartment; BlockKind.STOMP -> Icons.Filled.Whatshot; BlockKind.WAH -> Icons.Filled.Tune
    BlockKind.PEDAL -> Icons.Filled.SettingsInputComponent; BlockKind.AMP -> Icons.Filled.Speaker; BlockKind.CAB -> Icons.Filled.SpeakerGroup
    BlockKind.EQ -> Icons.Filled.Equalizer; BlockKind.CHORUS -> Icons.Filled.Waves; BlockKind.FLANGER -> Icons.Filled.Air
    BlockKind.TREMOLO -> Icons.Filled.Vibration; BlockKind.DELAY -> Icons.Filled.Timer; BlockKind.REVERB -> Icons.Filled.WaterDrop
    BlockKind.IR_REVERB -> Icons.Filled.Layers
}
fun sceneColor(scene: Int) = listOf(Color(0xFF0A84FF), Color(0xFF34C759), Color(0xFFFF9500), Color(0xFFFF2D55))[((scene % 4) + 4) % 4]

// ------------------------------------------------------------------ chassis / LED / meters
fun Modifier.chassis(accent: Color, dark: Boolean, rail: Dp = 4.dp): Modifier {
    val shape = RoundedCornerShape(14.dp)
    return this
        .shadow(8.dp, shape)
        .clip(shape)
        .background(if (dark) Brush.verticalGradient(listOf(Color(0xFF34353B), Stage.panel)) else Brush.verticalGradient(listOf(Stage.panelLight, Stage.panelLightBottom)))
        .border(1.dp, if (dark) Color.White.copy(alpha = 0.1f) else Color.Black.copy(alpha = 0.18f), shape)
        .drawWithContent { drawContent(); drawRect(accent, size = Size(size.width, rail.toPx())) }
}

@Composable
fun Led(on: Boolean, color: Color = Color(0xFF34C759), size: Dp = 8.dp) {
    Canvas(Modifier.size(size)) {
        if (on) drawCircle(color.copy(alpha = 0.35f), radius = this.size.minDimension * 0.9f)
        drawCircle(if (on) color else Color.Black.copy(alpha = 0.55f))
        drawCircle(Color.White.copy(alpha = if (on) 0.55f else 0.12f), radius = this.size.minDimension * 0.18f,
            center = Offset(center.x, center.y - this.size.minDimension * 0.18f))
    }
}

@Composable
fun LedMeter(db: Float, modifier: Modifier = Modifier, segments: Int = 14, height: Dp = 8.dp) {
    val dark = LocalDark.current
    val lit = (((db + 60) / 60).coerceIn(0f, 1f) * segments).roundToInt()
    Row(modifier.clip(RoundedCornerShape(3.dp)).background(Color.Black.copy(alpha = if (dark) 0.35f else 0.55f)).padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(1.5.dp)) {
        for (i in 0 until segments) {
            val frac = i.toFloat() / segments
            val c = if (frac > 0.9f) Color(0xFFFF3B30) else if (frac > 0.72f) Color(0xFFFFCC00) else Color(0xFF34C759)
            Box(Modifier.weight(1f).height(height).clip(RoundedCornerShape(1.5.dp)).background(if (i < lit) c else c.copy(alpha = if (dark) 0.14f else 0.3f)))
        }
    }
}

@Composable
fun DisplayPanel(modifier: Modifier = Modifier, padding: Dp = 10.dp, content: @Composable () -> Unit) {
    Box(modifier.clip(RoundedCornerShape(10.dp)).background(Stage.display).border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(10.dp)).padding(padding)) { content() }
}

@Composable
fun Nameplate(text: String) {
    Text(text.uppercase(), fontSize = 11.sp, fontWeight = FontWeight.Black, letterSpacing = 1.2.sp,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f),
        modifier = Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.12f)).padding(horizontal = 8.dp, vertical = 3.dp))
}

// ------------------------------------------------------------------ Knob (Knob.swift)
@Composable
fun Knob(
    label: String, value: Double, onChange: (Double) -> Unit, min: Double, max: Double,
    unit: String = "", decimals: Int = 0, color: Color = MaterialTheme.colorScheme.primary,
    default: Double? = null, bipolar: Boolean = false, size: Dp = 60.dp,
) {
    val haptic = LocalHapticFeedback.current
    val cur by rememberUpdatedState(value)
    val change by rememberUpdatedState(onChange)
    val span = max - min
    val norm = ((value - min) / span).coerceIn(0.0, 1.0).toFloat()
    val centerNorm = if (bipolar) ((0 - min) / span).toFloat() else 0f
    val onSurface = MaterialTheme.colorScheme.onSurface
    var detent by remember { mutableStateOf(false) }
    var dragStart by remember { mutableStateOf(0.0) }
    var acc by remember { mutableStateOf(Offset.Zero) }
    val readout = (if (decimals == 0) value.roundToInt().toString() else "%.${decimals}f".format(value)).let {
        if (unit.isEmpty()) it else if (unit.startsWith("%") || unit == "x" || unit.startsWith(":")) "$it$unit" else "$it $unit"
    }
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(maxOf(size, 72.dp))) {
        Canvas(Modifier.size(size + 6.dp)
            .semantics { contentDescription = "$label $readout" }
            .pointerInput(min, max) {
                detectDragGestures(
                    onDragStart = { dragStart = cur; acc = Offset.Zero },
                    onDragEnd = { detent = false },
                ) { ch, d ->
                    ch.consume()
                    acc += d
                    val delta = (-acc.y + acc.x * 0.5f) / (180 * density) * span
                    var v = (dragStart + delta).coerceIn(min, max)
                    if (default != null && abs(v - default) < span * 0.015) {
                        if (!detent) { haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove); detent = true }
                        v = default
                    } else detent = false
                    change(v)
                }
            }
            .pointerInput(default) { detectTapGestures(onDoubleTap = { default?.let { change(it); haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove) } }) }
        ) {
            val s = this.size.minDimension
            val stroke = s * 0.085f
            val inset = stroke / 2 + s * 0.04f
            val arcSize = Size(s - 2 * inset, s - 2 * inset)
            val tl = Offset(inset, inset)
            for (i in 0..10) rotate(-135f + i * 27f) {
                val len = if (i % 5 == 0) s * 0.07f else s * 0.04f
                drawLine(onSurface.copy(alpha = if (i % 5 == 0) 0.35f else 0.18f), Offset(center.x, 0f), Offset(center.x, len), 1.5f)
            }
            drawArc(onSurface.copy(alpha = 0.12f), 135f, 270f, false, tl, arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
            val a0 = minOf(norm, centerNorm); val a1 = maxOf(norm, centerNorm)
            if (a1 - a0 > 0.001f) drawArc(color, 135f + a0 * 270f, (a1 - a0) * 270f, false, tl, arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
            val capR = s * 0.33f
            drawCircle(Brush.verticalGradient(listOf(Color(0xFF575757), Color(0xFF1F1F1F)), startY = center.y - capR, endY = center.y + capR), capR)
            drawCircle(Color.White.copy(alpha = 0.3f), capR, style = Stroke(1.dp.toPx()))
            rotate(-135f + norm * 270f) {
                drawLine(color, Offset(center.x, center.y - capR * 0.9f), Offset(center.x, center.y - capR * 0.35f), s * 0.07f, cap = StrokeCap.Round)
            }
        }
        Text(readout, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        Text(label.uppercase(), fontSize = 9.sp, fontWeight = FontWeight.Black, color = onSurface.copy(alpha = 0.6f), maxLines = 1)
    }
}

/** Stomp-style footswitch toggle. */
@Composable
fun Footswitch(on: Boolean, onToggle: (Boolean) -> Unit, color: Color = Color(0xFF34C759)) {
    val haptic = LocalHapticFeedback.current
    Box(Modifier.size(36.dp).clip(CircleShape).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
        .pointerInput(on) { detectTapGestures { haptic.performHapticFeedback(HapticFeedbackType.LongPress); onToggle(!on) } }
        .semantics { contentDescription = if (on) "On" else "Off" },
        contentAlignment = Alignment.Center) {
        Box(Modifier.size(12.dp).clip(CircleShape).background(if (on) color else Color.Gray.copy(alpha = 0.45f)))
    }
}

@Composable
fun StageBackground(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(modifier.background(stageBrush(LocalDark.current))) { content() }
}

@Composable
fun MeterRow(label: String, db: Float, modifier: Modifier = Modifier) {
    Column(modifier) {
        Row(Modifier.fillMaxWidth()) {
            Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f), modifier = Modifier.weight(1f))
            Text(if (db <= -120) "—" else "%.0f dB".format(db), fontSize = 12.sp)
        }
        LedMeter(db, Modifier.fillMaxWidth(), segments = 18)
    }
}
